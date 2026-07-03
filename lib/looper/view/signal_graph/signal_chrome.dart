part of 'signal_list_view.dart';

// --- Chrome --------------------------------------------------------------

/// The bottom legend — a quiet key for the row vocabulary (gate / snapshot /
/// routing chip), like a patchbay's silk-screen.
class _SignalLegend extends StatelessWidget {
  const _SignalLegend();

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    Widget item(Widget glyph, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        glyph,
        const SizedBox(width: 6),
        Text(label, style: signalLabel(color: surface.textTertiary, size: 10)),
      ],
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0B0F),
        border: Border(top: BorderSide(color: surface.line)),
      ),
      child: Wrap(
        spacing: 20,
        runSpacing: 6,
        children: [
          item(
            const SignalGateDot(on: true, size: 8),
            l10n.signalLegendLive,
          ),
          item(
            Icon(Icons.auto_awesome, size: 11, color: surface.accent),
            l10n.signalLegendSnapshot,
          ),
          item(
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: surface.accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: surface.accent.withValues(alpha: 0.55),
                ),
              ),
              child: Text(
                '→',
                style: signalMono(color: surface.accent, size: 9),
              ),
            ),
            l10n.signalLegendChip,
          ),
        ],
      ),
    );
  }
}

class _SignalChromeBar extends StatelessWidget {
  const _SignalChromeBar();

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 18, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: surface.line)),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF101016), Color(0xFF0C0C10)],
        ),
      ),
      child: Row(
        children: [
          TextButton.icon(
            key: const Key('signalGraph_back'),
            onPressed: () => unawaited(Navigator.of(context).maybePop()),
            icon: const Icon(Icons.chevron_left, size: 18),
            label: Text(
              l10n.close,
              style: signalLabel(color: surface.textSecondary),
            ),
            style: TextButton.styleFrom(
              foregroundColor: surface.textSecondary,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            l10n.signalTitle.toUpperCase(),
            style: signalLabel(
              color: surface.textPrimary,
              size: 14,
              weight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            l10n.signalFlowSubtitle,
            style: signalLabel(color: surface.textTertiary),
          ),
        ],
      ),
    );
  }
}

/// A non-blocking notice surfaced when every output is gated off (E1/F-12).
class _NoActiveOutputsNotice extends StatelessWidget {
  const _NoActiveOutputsNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final warning = context.surface.warning;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        key: const Key('signalGraph_noActiveOutputs'),
        margin: const EdgeInsets.only(bottom: 9),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: warning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: warning.withValues(alpha: 0.32)),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 16, color: warning),
            const SizedBox(width: 9),
            Expanded(
              child: Text(message, style: signalMono(color: warning)),
            ),
          ],
        ),
      ),
    );
  }
}
