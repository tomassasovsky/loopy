import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/view/fx_editor/fx_block_chip.dart';
import 'package:loopy/looper/view/fx_editor/fx_param_control.dart';
import 'package:loopy/looper/view/signal_graph/signal_style.dart';
import 'package:loopy/theme/surface_theme.dart';

/// The inspector pane: the controls for the **selected block only**. A
/// built-in effect shows its labeled sliders; an available plugin shows its
/// param sliders plus *Open Editor*; an unresolved plugin shows a relink
/// placeholder (with the distinct "unsupported" message when it was rejected
/// rather than missing), and a version-drifted plugin still edits, with a note.
/// Nothing selected (an empty chain, or before a pick) shows a quiet hint.
class FxInspector extends StatelessWidget {
  /// Creates an [FxInspector].
  const FxInspector({
    required this.effect,
    required this.emptyHint,
    required this.onSetType,
    required this.onSetParam,
    required this.onSetPluginParam,
    required this.onOpenEditor,
    required this.onRelink,
    required this.onRemove,
    required this.onFormatPluginValue,
    super.key,
  });

  /// The selected chain entry, or null when nothing is selected.
  final TrackEffect? effect;

  /// The hint shown when [effect] is null.
  final String emptyHint;

  /// Retypes the selected built-in block to `type`.
  final void Function(TrackEffectType type) onSetType;

  /// Sets built-in parameter `param` to the normalized `value`.
  final void Function(int param, double value) onSetParam;

  /// Sets plugin parameter `paramId` to the plain `value`.
  final void Function(int paramId, double value) onSetPluginParam;

  /// Opens the selected plugin's native editor window.
  final VoidCallback onOpenEditor;

  /// Relinks the selected (unavailable) plugin.
  final VoidCallback onRelink;

  /// Removes the selected block from the chain.
  final VoidCallback onRemove;

  /// The plugin's own display string for `value` on `paramId`, or null.
  final String? Function(int paramId, double value) onFormatPluginValue;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final fx = effect;
    if (fx == null) {
      return Center(
        key: const Key('fxInspector_empty'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            emptyHint,
            textAlign: TextAlign.center,
            style: signalLabel(color: surface.textTertiary, size: 12.5),
          ),
        ),
      );
    }
    final drifted = fx is PluginEffect && fx.versionChanged;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InspectorHeader(
          effect: fx,
          drifted: drifted,
          onSetType: onSetType,
          onRemove: onRemove,
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: _body(context, fx),
          ),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, TrackEffect fx) {
    final l10n = context.l10n;
    switch (fx) {
      case BuiltInEffect():
        final params = fx.type.params;
        if (params.isEmpty) return _Note(text: l10n.emDash);
        return Column(
          children: [
            for (var p = 0; p < params.length; p++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: FxParamControl(
                  controlKey: Key('fxInspector_param_$p'),
                  fx: fx,
                  param: p,
                  onChanged: (v) => onSetParam(p, v),
                ),
              ),
          ],
        );
      case PluginEffect():
        if (fx.unavailable) {
          return _PluginPlaceholder(
            unsupported: fx.unsupported,
            onRelink: onRelink,
          );
        }
        final controls = fx.params
            .where((p) => p.isUserVisible && !p.isBypass)
            .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final spec in controls)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: FxPluginParamControl(
                  controlKey: Key('fxInspector_param_${spec.id}'),
                  spec: spec,
                  value: fx.paramValues[spec.id] ?? spec.def,
                  onChanged: (v) => onSetPluginParam(spec.id, v),
                  onFormatValue: onFormatPluginValue,
                ),
              ),
            if (controls.isEmpty) _Note(text: l10n.emDash),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              key: const Key('fxInspector_openEditor'),
              onPressed: onOpenEditor,
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(l10n.signalPluginOpenEditorTooltip),
            ),
          ],
        );
    }
  }
}

/// The inspector's header — the block's identity, an optional version-drift
/// note, and the remove action. A built-in block's name is a type picker (tap
/// to retype in place); a plugin's name is plain text.
class _InspectorHeader extends StatelessWidget {
  const _InspectorHeader({
    required this.effect,
    required this.drifted,
    required this.onSetType,
    required this.onRemove,
  });

  final TrackEffect effect;
  final bool drifted;
  final void Function(TrackEffectType type) onSetType;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final fx = effect;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(
        children: [
          Flexible(
            child: fx is BuiltInEffect
                ? _TypeMenu(current: fx.type, onSelected: onSetType)
                : Text(
                    fxBlockName(l10n, fx),
                    overflow: TextOverflow.ellipsis,
                    style: signalLabel(
                      color: surface.textPrimary,
                      size: 14,
                      weight: FontWeight.w600,
                    ),
                  ),
          ),
          if (drifted) ...[
            const SizedBox(width: 8),
            Tooltip(
              key: const Key('fxInspector_versionChanged'),
              message: l10n.signalPluginVersionChanged,
              child: Icon(
                Icons.info_outline,
                size: 15,
                color: surface.textTertiary,
              ),
            ),
          ],
          const Spacer(),
          IconButton(
            key: const Key('fxInspector_remove'),
            iconSize: 18,
            color: surface.textSecondary,
            tooltip: l10n.removeEffectTooltip,
            icon: const Icon(Icons.delete_outline),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// The built-in block's type picker — the current type's name with a dropdown
/// affordance; selecting another type retypes the block in place (reseeding its
/// DSP + default params). `none` is omitted (a block is removed with ×, not
/// turned into a no-op).
class _TypeMenu extends StatelessWidget {
  const _TypeMenu({required this.current, required this.onSelected});

  final TrackEffectType current;
  final void Function(TrackEffectType type) onSelected;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return PopupMenuButton<TrackEffectType>(
      key: const Key('fxInspector_type'),
      tooltip: l10n.a11yEffectType,
      onSelected: onSelected,
      color: surface.cardHigh,
      shape: signalMenuShape(surface),
      elevation: 10,
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        for (final type in TrackEffectType.values)
          if (type != TrackEffectType.none)
            PopupMenuItem<TrackEffectType>(
              value: type,
              height: 40,
              child: Text(
                l10n.effectTypeLabel(type),
                style: signalLabel(
                  color: type == current ? surface.accent : surface.textPrimary,
                  size: 13,
                  weight: type == current ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              l10n.effectTypeLabel(current),
              overflow: TextOverflow.ellipsis,
              style: signalLabel(
                color: surface.textPrimary,
                size: 14,
                weight: FontWeight.w600,
              ),
            ),
          ),
          Icon(Icons.arrow_drop_down, size: 18, color: surface.textSecondary),
        ],
      ),
    );
  }
}

/// The relink placeholder for an unresolved plugin — a message (missing vs.
/// rejected) and the relink action. Its params can't render, but it stays
/// removable via the header.
class _PluginPlaceholder extends StatelessWidget {
  const _PluginPlaceholder({required this.unsupported, required this.onRelink});

  final bool unsupported;
  final VoidCallback onRelink;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          key: const Key('fxInspector_reason'),
          unsupported
              ? l10n.signalPluginUnsupported
              : l10n.signalPluginUnavailable,
          textAlign: TextAlign.center,
          style: signalLabel(color: surface.textTertiary, size: 12.5),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('fxInspector_relink'),
          onPressed: onRelink,
          icon: const Icon(Icons.link, size: 16),
          label: Text(l10n.signalPluginRelinkTooltip),
        ),
      ],
    );
  }
}

/// A centered dim note (e.g. a params-less effect's em dash).
class _Note extends StatelessWidget {
  const _Note({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(
          text,
          style: signalLabel(color: surface.textTertiary, size: 12.5),
        ),
      ),
    );
  }
}
