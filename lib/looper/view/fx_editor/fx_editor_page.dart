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

/// Opens the dedicated **FX editor** for [scope] as a full-screen page. The
/// scope drives one chain (an input's live monitor or a lane's snapshot); the
/// backing [LooperBloc] and [MonitorCubit] are re-provided into the pushed
/// route so the editor reflects live edits.
Future<void> showFxEditorPage(
  BuildContext context, {
  required FxScope scope,
}) {
  final bloc = context.read<LooperBloc>();
  final monitor = context.read<MonitorCubit>();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MultiBlocProvider(
        providers: [
          BlocProvider.value(value: bloc),
          BlocProvider.value(value: monitor),
        ],
        child: FxEditorView(scope: scope),
      ),
    ),
  );
}

/// The FX editor: a header naming the scope + its plain consequence, the chain
/// strip, and the inspector for the selected block. The chain is resolved live
/// off the scope each build, so external edits reflect immediately and the
/// editor empty-states the moment its target is gone.
class FxEditorView extends StatefulWidget {
  /// Creates an [FxEditorView] driving [scope].
  const FxEditorView({required this.scope, super.key});

  /// The chain this editor edits.
  final FxScope scope;

  @override
  State<FxEditorView> createState() => _FxEditorViewState();
}

class _FxEditorViewState extends State<FxEditorView> {
  /// The selected block index (the editor's intent), clamped to the live chain
  /// each build. Starts on the first block per the open-selects-first rule.
  int? _selected = 0;

  FxScope get _scope => widget.scope;

  Future<void> _addPlugin() async {
    final descriptor = await showPluginBrowser(context);
    // The browser is a pushed route; the editor may have been popped while it
    // was open, so bail before touching state.
    if (descriptor == null || !mounted) return;
    // The appended block lands at the current (pre-insert) end of the chain.
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

    return Scaffold(
      key: const Key('fx_editor_page'),
      backgroundColor: surface.background,
      body: SafeArea(
        child: Column(
          children: [
            _FxEditorHeader(
              title: _scope.label(l10n),
              consequence: _scope.consequence(l10n),
              onClose: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: _scope.isPresent
                  ? _editor(context)
                  : _Gone(message: l10n.fxEditorScopeGone),
            ),
          ],
        ),
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
        const SizedBox(height: 14),
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

/// The editor's top bar — a back affordance, the scope title, and the plain
/// consequence of editing this chain.
class _FxEditorHeader extends StatelessWidget {
  const _FxEditorHeader({
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
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: surface.line)),
      ),
      child: Row(
        children: [
          IconButton(
            key: const Key('fxEditor_back'),
            onPressed: onClose,
            icon: const Icon(Icons.chevron_left),
            color: surface.textSecondary,
            tooltip: l10n.close,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: signalLabel(
                    color: surface.textPrimary,
                    size: 16,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  consequence,
                  style: signalLabel(color: surface.textTertiary, size: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The empty-state shown when the edited chain's target no longer exists (its
/// lane was removed while the route was open).
class _Gone extends StatelessWidget {
  const _Gone({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Center(
      key: const Key('fxEditor_gone'),
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
