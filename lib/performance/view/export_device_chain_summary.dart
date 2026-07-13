import 'package:daw_export/daw_export.dart';
import 'package:flutter/material.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/surface_theme.dart';

/// A per-track export summary on the performance-completion sheet (part
/// 11): for each exported track, whether it carried a live, editable Loopy
/// VST3 device chain or bounced (wet) audio, and — only when it bounced
/// *because* effects existed but couldn't be honestly represented as one
/// (umbrella D-CHAIN-FALLBACK) — the specific reason. A track with no
/// effects at all gets no fallback callout; there's nothing to explain
/// there (matching [DawTrack.deviceChainFallbackReason]'s own contract:
/// never set for a channel with no effects at all).
///
/// Fed [DawTrack]s directly (the same list `daw_export`'s manifest reader
/// already produces) rather than a separate app-layer summary model — no
/// new `daw_export` API work was needed for this part.
class ExportDeviceChainSummary extends StatelessWidget {
  /// Creates an [ExportDeviceChainSummary] for [tracks].
  const ExportDeviceChainSummary({required this.tracks, super.key});

  /// One entry per exported track, in `daw_export`'s own order.
  final List<DawTrack> tracks;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) return const SizedBox.shrink();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      key: const Key('exportSummary'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.perfExportSummaryTitle, style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        for (final track in tracks) _TrackExportRow(track: track),
      ],
    );
  }
}

/// One track's row: name, live-vs-bounced label, and (when applicable) the
/// specific fallback reason.
class _TrackExportRow extends StatelessWidget {
  const _TrackExportRow({required this.track});

  final DawTrack track;

  /// The user-facing reason text for [reason], or `null` for no callout —
  /// a small, exhaustive `switch` so a future fourth
  /// [DeviceChainFallbackReason] fails to compile here rather than silently
  /// showing no reason.
  static String? _reasonText(
    AppLocalizations l10n,
    DeviceChainFallbackReason? reason,
  ) => switch (reason) {
    null => null,
    DeviceChainFallbackReason.mixedLaneChains =>
      l10n.perfExportReasonMixedLanes,
    DeviceChainFallbackReason.thirdPartyPlugin =>
      l10n.perfExportReasonThirdPartyPlugin,
    DeviceChainFallbackReason.unrepresentedEffectType =>
      l10n.perfExportReasonUnrepresented,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final chain = track.deviceChain;
    final isLive = chain != null && chain.isNotEmpty;
    final reasonText = _reasonText(l10n, track.deviceChainFallbackReason);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isLive ? Icons.tune : Icons.graphic_eq,
            size: 16,
            color: isLive ? surface.accent : surface.textTertiary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.name,
                  style: TextStyle(color: surface.textPrimary, fontSize: 13),
                ),
                Text(
                  isLive
                      ? l10n.perfExportTrackLive
                      : l10n.perfExportTrackBounced,
                  style: TextStyle(color: surface.textSecondary, fontSize: 11),
                ),
                if (reasonText != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      reasonText,
                      style: TextStyle(
                        color: surface.textTertiary,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
