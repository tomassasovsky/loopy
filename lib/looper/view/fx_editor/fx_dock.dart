import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/fx_editor/fx_scope.dart';
import 'package:segno/looper/view/signal_graph/plugin_browser.dart';
import 'package:segno/looper/view/signal_graph/signal_fx_chrome.dart';
import 'package:segno/looper/view/signal_graph/signal_fx_rack.dart';
import 'package:segno/looper/view/signal_graph/signal_style.dart';
import 'package:segno/theme/surface_theme.dart';

/// The bottom **FX dock** on the Signal surface: edits one [scope]'s chain in
/// place — a header naming the scope + its plain consequence, over the
/// knob-rack editor ([SignalFxRack]) — without leaving the surface.
///
/// The chain is resolved live off the scope each build, so external edits
/// reflect immediately and the dock empty-states the moment its target is gone.
class FxDock extends StatefulWidget {
  /// Creates an [FxDock] editing [scope]; [onClose] dismisses the dock.
  const FxDock({required this.scope, required this.onClose, super.key});

  /// The chain this dock edits.
  final FxScope scope;

  /// Invoked when the dock's close affordance is tapped.
  final VoidCallback onClose;

  @override
  State<FxDock> createState() => _FxDockState();
}

class _FxDockState extends State<FxDock> {
  FxScope get _scope => widget.scope;

  Future<void> _addPlugin() async {
    final descriptor = await showPluginBrowser(context);
    if (descriptor == null || !mounted) return;
    _scope.insertPlugin(
      PluginRef(
        format: descriptor.format,
        id: descriptor.id,
        version: descriptor.version,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild on any chain edit from either backing store; the scope re-reads
    // the current state below.
    context
      ..watch<LooperBloc>()
      ..watch<MonitorCubit>();
    final l10n = context.l10n;
    final surface = context.surface;

    return Container(
      key: const Key('fx_dock'),
      height: 260,
      decoration: BoxDecoration(
        color: surface.background,
        border: Border(top: BorderSide(color: surface.line)),
      ),
      child: Column(
        // Left-align the dock body (the rack, narrower than the dock, would
        // otherwise centre under the default cross-axis alignment).
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FxDockHeader(scope: _scope, onClose: widget.onClose),
          // A7: an overdub never re-inherits, so a chain that has drifted from
          // its input since the take is worth saying out loud, while it counts.
          if (_scope.overdubMismatch)
            _OverdubMismatchHint(message: l10n.fxOverdubMismatchHint),
          Expanded(
            child: _scope.isPresent
                ? _editor(context)
                : _Gone(message: l10n.fxEditorScopeGone),
          ),
        ],
      ),
    );
  }

  Widget _editor(BuildContext context) {
    // The original knob-rack editor (mix lives on the row cards, not here).
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: SignalFxRack(
        keyPrefix: 'fxDock',
        effects: _scope.effects,
        chainEnabled: _scope.chainEnabled,
        onAddEffect: _scope.addEffectOfType,
        onAddPlugin: () => unawaited(_addPlugin()),
        onRemoveEffect: _scope.removeEffect,
        onSetType: _scope.setType,
        onSetParam: _scope.setParam,
        onSetPluginParam: _scope.setPluginParam,
        onOpenPluginEditor: _scope.openPluginEditor,
        onRelinkPlugin: (index) => unawaited(_relink(index)),
        onReorder: _scope.moveEffect,
        onSetEffectEnabled: _scope.setEffectEnabled,
        onFormatPluginValue: _scope.formatPluginValue,
      ),
    );
  }

  Future<void> _relink(int index) async {
    final descriptor = await showPluginBrowser(context);
    if (descriptor == null) return;
    _scope.relinkPlugin(
      index,
      PluginRef(
        format: descriptor.format,
        id: descriptor.id,
        version: descriptor.version,
      ),
    );
  }
}

/// The dock's header — the scope title, its inherited badge and re-sync action
/// (loop stage), the plain consequence line, the chain-level power control, and
/// a close affordance.
///
/// The consequence line is stage-aware in both directions: while the chain is
/// engaged it says what editing here does, and once the chain is switched off
/// it says what that silence costs ([FxScope.chainDisabledConsequence]) — the
/// state you are in is always spelled out, never left to a lit icon (R15/R23).
class _FxDockHeader extends StatelessWidget {
  const _FxDockHeader({required this.scope, required this.onClose});

  final FxScope scope;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final chainOn = scope.chainEnabled;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: surface.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Text(
                  scope.label(l10n),
                  style: signalLabel(
                    color: surface.textPrimary,
                    size: 15,
                    weight: FontWeight.w600,
                  ),
                ),
                if (scope.inheritedFrom.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  InheritedFxBadge(
                    badgeKey: const Key('fxDock_inherited'),
                    inputs: scope.inheritedFrom,
                  ),
                ],
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    chainOn
                        ? scope.consequence(l10n)
                        : scope.chainDisabledConsequence(l10n),
                    key: const Key('fxDock_consequence'),
                    overflow: TextOverflow.ellipsis,
                    style: signalLabel(
                      color: chainOn ? surface.textTertiary : surface.warning,
                      size: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Explicit, user-initiated re-inherit (A6): offered only while the
          // routed input actually has an audible chain to copy.
          if (scope.canResyncFromInput)
            Semantics(
              button: true,
              label: l10n.fxResyncFromInput,
              child: IconButton(
                key: const Key('fxDock_resync'),
                onPressed: scope.resyncFromInput,
                icon: const Icon(Icons.sync),
                iconSize: 17,
                color: surface.textSecondary,
                tooltip: l10n.fxResyncFromInputTooltip,
              ),
            ),
          // A chain whose target is gone has nothing to switch: writing through
          // a vanished input would mint a phantom monitor and persist a key
          // that comes back on the next boot.
          if (scope.isPresent)
            _ChainPowerToggle(
              enabled: chainOn,
              onChanged: (enabled) => scope.setChainEnabled(enabled: enabled),
            ),
          IconButton(
            key: const Key('fxDock_close'),
            onPressed: onClose,
            icon: const Icon(Icons.close),
            iconSize: 18,
            color: surface.textSecondary,
            tooltip: l10n.close,
          ),
        ],
      ),
    );
  }
}

/// The chain-level power control (R15): one atomic flip of the WHOLE chain,
/// leaving every per-slot flag intact. The same [FxPowerToggle] the device
/// cards carry, worded for a chain — the two power controls are one widget so
/// they cannot drift apart.
class _ChainPowerToggle extends StatelessWidget {
  const _ChainPowerToggle({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FxPowerToggle(
      toggleKey: const Key('fxDock_chainPower'),
      enabled: enabled,
      onChanged: ({required enabled}) => onChanged(enabled),
      iconSize: 18,
      semanticLabel: enabled ? l10n.a11yFxChainOn : l10n.a11yFxChainOff,
      tooltip: enabled
          ? l10n.fxChainPowerOffTooltip
          : l10n.fxChainPowerOnTooltip,
    );
  }
}

/// The overdub hint (A7): while a take is being overdubbed onto and its chain
/// no longer sounds like the routed input's, say plainly that the new layer is
/// captured dry and will not re-inherit. Warning-toned, never blocking.
class _OverdubMismatchHint extends StatelessWidget {
  const _OverdubMismatchHint({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      key: const Key('fxDock_overdubHint'),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      color: surface.warning.withValues(alpha: 0.12),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 14, color: surface.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: signalLabel(color: surface.warning),
            ),
          ),
        ],
      ),
    );
  }
}

/// The empty-state shown when the edited chain's target no longer exists (its
/// lane was removed while the dock was open).
class _Gone extends StatelessWidget {
  const _Gone({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Center(
      key: const Key('fxDock_gone'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: signalLabel(color: surface.textTertiary, size: 13),
        ),
      ),
    );
  }
}
