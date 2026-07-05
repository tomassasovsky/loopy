import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/view/signal_graph/signal_style.dart';
import 'package:loopy/theme/surface_theme.dart';

/// The display name for chain entry [effect] — a built-in type's label, or a
/// hosted plugin's resolved name (its id, then a generic label, as fallbacks).
String fxBlockName(AppLocalizations l10n, TrackEffect effect) =>
    switch (effect) {
      BuiltInEffect(:final type) => l10n.effectTypeLabel(type),
      PluginEffect(:final name, :final ref) =>
        name.isNotEmpty
            ? name
            : (ref.id.isEmpty ? l10n.signalPluginUnknownName : ref.id),
    };

/// One block in the FX chain strip — a single chain entry rendered as a compact
/// chip. Selection is the only lit state (`accent`), since a block is always
/// engaged (bypass is deferred); an unresolved / drifted plugin carries a small
/// status glyph so the state reads at a glance. Tapping selects it for the
/// inspector; the strip owns drag-reorder.
class FxBlockChip extends StatelessWidget {
  /// Creates an [FxBlockChip] for [effect].
  const FxBlockChip({
    required this.chipKey,
    required this.effect,
    required this.selected,
    required this.onTap,
    super.key,
  });

  /// A stable key on the tap surface (for tests).
  final Key chipKey;

  /// The chain entry this chip represents.
  final TrackEffect effect;

  /// Whether this block is the inspector's current selection.
  final bool selected;

  /// Selects this block for editing.
  final VoidCallback onTap;

  /// The status glyph for a plugin entry that needs attention, or null.
  IconData? get _statusIcon => switch (effect) {
    PluginEffect(:final unavailable) when unavailable =>
      Icons.warning_amber_rounded,
    PluginEffect(:final versionChanged) when versionChanged =>
      Icons.info_outline,
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final name = fxBlockName(l10n, effect);
    final icon = _statusIcon;
    final fg = selected ? surface.accent : surface.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      label: l10n.fxEditorEditBlock(name),
      child: InkWell(
        key: chipKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? surface.accent.withValues(alpha: 0.16)
                : surface.cardHigh,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected ? surface.accent : surface.line,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 13, color: surface.textTertiary),
                const SizedBox(width: 6),
              ],
              Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: signalLabel(
                  color: fg,
                  size: 12,
                  weight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
