import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/view/fx_editor/fx_block_chip.dart';
import 'package:loopy/looper/view/signal_graph/signal_fx_chrome.dart';
import 'package:loopy/looper/view/signal_graph/signal_style.dart';
import 'package:loopy/theme/surface_theme.dart';

/// A compact, read-only **FX summary** on a stage row — the chain's block names
/// as small chips (or a quiet "No FX" affordance when empty), all wrapped in a
/// single tap target that opens the chain in the bottom FX dock. Shared by all
/// four stages: input cards, take (loop) cards, the track bus row, and the
/// Master strip. The routing surface shows *what* FX a chain carries; shaping
/// happens in the dock.
///
/// Power state is honest here, not just in the dock (R26): a powered-off entry
/// dims its own chip, and a chain-disabled row dims and strikes through as a
/// whole, with a "chain off" marker so the state survives a colour-blind or
/// screen-reader read. A hosted plugin that is missing, still scanning, or
/// unsupported carries its placeholder glyph on the chip, so those states are
/// visible without opening the dock.
class SignalFxSummary extends StatelessWidget {
  /// Creates a [SignalFxSummary].
  const SignalFxSummary({
    required this.summaryKey,
    required this.effects,
    required this.onEdit,
    this.chainEnabled = true,
    this.semanticLabel,
    super.key,
  });

  /// A stable key on the tap surface (for tests).
  final Key summaryKey;

  /// The chain to summarise, in processing order.
  final List<TrackEffect> effects;

  /// Whether the whole chain is engaged (R15).
  final bool chainEnabled;

  /// The tap target's semantic label; defaults to the generic "Edit FX chain"
  /// when null (the stage rows pass their own, e.g. the master chain).
  final String? semanticLabel;

  /// Opens the FX editor for this chain's scope.
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Semantics(
      button: true,
      label: semanticLabel ?? l10n.signalEditFx,
      child: InkWell(
        key: summaryKey,
        onTap: onEdit,
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: effects.isEmpty
              ? _AddFxChip(label: l10n.signalNoFx)
              // Dimming happens per chip, exactly once: an outer wrapper here
              // would multiply with the chips' own dim and would bury the
              // chain-off marker, which exists precisely so the state does not
              // rest on the dim (R26).
              : Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (!chainEnabled)
                      _ChainOffChip(label: l10n.signalChainOff),
                    for (final e in effects)
                      _SummaryChip(
                        label: fxBlockName(l10n, e),
                        enabled: e.enabled && chainEnabled,
                        status: fxPluginStatus(l10n, e),
                      ),
                    Icon(Icons.tune, size: 14, color: surface.textTertiary),
                  ],
                ),
        ),
      ),
    );
  }
}

/// One block-name chip in the summary — quiet and neutral (tone is shaped in
/// the editor, not colour-coded on the routing card). A powered-off entry dims
/// and strikes through; a plugin needing attention leads with its glyph.
class _SummaryChip extends StatelessWidget {
  const _SummaryChip({
    required this.label,
    required this.enabled,
    this.status,
  });

  final String label;

  /// Whether this entry is audible — its own power flag AND its chain's.
  final bool enabled;

  /// The plugin attention state to flag, or null.
  final ({IconData icon, String message})? status;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final glyph = status;
    final chip = FxDisabledDim(
      enabled: enabled,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: surface.cardHigh,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: surface.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (glyph != null) ...[
              Icon(glyph.icon, size: 11, color: surface.warning),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: signalMono(color: surface.textSecondary, size: 10)
                  .copyWith(
                    decoration: enabled ? null : TextDecoration.lineThrough,
                  ),
            ),
          ],
        ),
      ),
    );
    if (glyph == null) return chip;
    return Tooltip(
      message: glyph.message,
      child: Semantics(label: '$label, ${glyph.message}', child: chip),
    );
  }
}

/// The chain-disabled marker leading a dimmed summary row — the state in words,
/// so "this chain is off" never rests on the dim alone.
class _ChainOffChip extends StatelessWidget {
  const _ChainOffChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: surface.warning),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.power_off, size: 11, color: surface.warning),
          const SizedBox(width: 4),
          Text(
            label,
            style: signalMono(color: surface.warning, size: 10),
          ),
        ],
      ),
    );
  }
}

/// The empty-chain affordance — a dashed-feel "No FX" chip that still opens the
/// editor (where the first block is added). The same affordance on every stage,
/// so a Track bus or the Master insert invites a first block exactly as an
/// input or lane card does.
class _AddFxChip extends StatelessWidget {
  const _AddFxChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: surface.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.add, size: 13, color: surface.textTertiary),
          const SizedBox(width: 4),
          Text(
            label,
            style: signalMono(color: surface.textTertiary, size: 10),
          ),
        ],
      ),
    );
  }
}
