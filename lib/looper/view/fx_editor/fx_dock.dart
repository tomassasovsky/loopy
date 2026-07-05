import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/view/fx_editor/fx_chain_strip.dart';
import 'package:loopy/looper/view/fx_editor/fx_inspector.dart';
import 'package:loopy/looper/view/fx_editor/fx_scope.dart';
import 'package:loopy/looper/view/signal_graph/plugin_browser.dart';
import 'package:loopy/looper/view/signal_graph/signal_style.dart';
import 'package:loopy/theme/surface_theme.dart';

/// The bottom **FX dock** on the Signal surface: edits one [scope]'s chain in
/// place (a header naming the scope + its plain consequence, the chain strip,
/// and the inspector for the selected block) without leaving the surface.
///
/// Replaces the full-screen FX editor route — the same [FxChainStrip] /
/// [FxInspector] widgets, re-homed into a docked panel. The chain is resolved
/// live off the scope each build, so external edits reflect immediately and the
/// dock empty-states the moment its target is gone. Keyed by the scope so
/// switching the edited row resets the block selection.
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
  /// The selected block index (the dock's intent), clamped to the live chain
  /// each build. Starts on the first block per the open-selects-first rule.
  int? _selected = 0;

  FxScope get _scope => widget.scope;

  Future<void> _addPlugin() async {
    final descriptor = await showPluginBrowser(context);
    if (descriptor == null || !mounted) return;
    final newIndex = _scope.effects.length;
    _scope.insertPlugin(
      PluginRef(
        format: descriptor.format,
        id: descriptor.id,
        version: descriptor.version,
      ),
    );
    setState(() => _selected = newIndex);
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
    final l10n = context.l10n;
    final surface = context.surface;
    final effects = _scope.effects;
    final selected = effects.isEmpty
        ? null
        : (_selected ?? 0).clamp(0, effects.length - 1);
    final selectedEffect = selected == null ? null : effects[selected];
    final emptyHint = effects.isEmpty
        ? l10n.signalLaneCleanHint
        : l10n.fxEditorEmptySelection;

    return Column(
      children: [
        const SizedBox(height: 10),
        SizedBox(
          height: 64,
          child: FxChainStrip(
            effects: effects,
            selectedIndex: selected,
            canAdd: _scope.canAddEffect,
            onSelect: (i) => setState(() => _selected = i),
            onReorder: (from, to) {
              _scope.moveEffect(from, to);
              setState(() => _selected = to);
            },
            onAddEffect: () {
              _scope.addEffect();
              setState(() => _selected = effects.length);
            },
            onAddPlugin: () => unawaited(_addPlugin()),
          ),
        ),
        const SizedBox(height: 8),
        Divider(height: 1, color: surface.line),
        Expanded(
          child: FxInspector(
            key: ValueKey(selected),
            effect: selectedEffect,
            emptyHint: emptyHint,
            onSetType: (t) => _scope.setType(selected!, t),
            onSetParam: (p, v) => _scope.setParam(selected!, p, v),
            onSetPluginParam: (id, v) =>
                _scope.setPluginParam(selected!, id, v),
            onOpenEditor: () => _scope.openPluginEditor(selected!),
            onRelink: () => unawaited(_relink(selected!)),
            onRemove: () {
              _scope.removeEffect(selected!);
              final nextLen = effects.length - 1;
              setState(
                () => _selected = nextLen <= 0
                    ? null
                    : (selected - 1).clamp(0, nextLen - 1),
              );
            },
            onFormatPluginValue: (id, v) =>
                _scope.formatPluginValue(selected!, id, v),
          ),
        ),
      ],
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
