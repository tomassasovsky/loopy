import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/view/fx_editor/fx_scope.dart';
import 'package:loopy/looper/view/signal_graph/plugin_browser.dart';
import 'package:loopy/looper/view/signal_graph/signal_fx_rack.dart';
import 'package:loopy/looper/view/signal_graph/signal_style.dart';
import 'package:loopy/theme/surface_theme.dart';

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
        children: [
          _FxDockHeader(
            title: _scope.label(l10n),
            consequence: _scope.consequence(l10n),
            onClose: widget.onClose,
          ),
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
        onAddEffect: _scope.addEffect,
        onAddPlugin: () => unawaited(_addPlugin()),
        onRemoveEffect: _scope.removeEffect,
        onSetType: _scope.setType,
        onSetParam: _scope.setParam,
        onSetPluginParam: _scope.setPluginParam,
        onOpenPluginEditor: _scope.openPluginEditor,
        onRelinkPlugin: (index) => unawaited(_relink(index)),
        onReorder: _scope.moveEffect,
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

/// The dock's header — the scope title, the plain consequence of editing this
/// chain, and a close affordance.
class _FxDockHeader extends StatelessWidget {
  const _FxDockHeader({
    required this.title,
    required this.consequence,
    required this.onClose,
  });

  final String title;
  final String consequence;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
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
                  title,
                  style: signalLabel(
                    color: surface.textPrimary,
                    size: 15,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    consequence,
                    overflow: TextOverflow.ellipsis,
                    style: signalLabel(color: surface.textTertiary, size: 12),
                  ),
                ),
              ],
            ),
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
