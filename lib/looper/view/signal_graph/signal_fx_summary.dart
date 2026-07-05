import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/view/fx_editor/fx_block_chip.dart';
import 'package:loopy/looper/view/signal_graph/signal_style.dart';
import 'package:loopy/theme/surface_theme.dart';

/// A compact, read-only **FX summary** on a routing card — the chain's block
/// names as small chips (or a quiet "No FX" affordance when empty), all wrapped
/// in a single tap target that opens the full FX editor. The routing surface
/// shows *what* FX a chain carries; shaping happens in the editor, so this
/// replaced the inline knob rack that used to live in the dock.
class SignalFxSummary extends StatelessWidget {
  /// Creates a [SignalFxSummary].
  const SignalFxSummary({
    required this.summaryKey,
    required this.effects,
    required this.onEdit,
    super.key,
  });

  /// A stable key on the tap surface (for tests).
  final Key summaryKey;

  /// The chain to summarise, in processing order.
  final List<TrackEffect> effects;

  /// Opens the FX editor for this chain's scope.
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Semantics(
      button: true,
      label: l10n.signalEditFx,
      child: InkWell(
        key: summaryKey,
        onTap: onEdit,
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: effects.isEmpty
              ? _AddFxChip(label: l10n.signalNoFx)
              : Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final e in effects)
                      _SummaryChip(label: fxBlockName(l10n, e)),
                    Icon(
                      Icons.tune,
                      size: 14,
                      color: surface.textTertiary,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// One block-name chip in the summary — quiet and neutral (tone is shaped
/// in the editor, not colour-coded on the routing card).
class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: surface.cardHigh,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: surface.line),
      ),
      child: Text(
        label,
        style: signalMono(color: surface.textSecondary, size: 10),
      ),
    );
  }
}

/// The empty-chain affordance — a dashed-feel "No FX" chip that still opens the
/// editor (where the first block is added).
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
