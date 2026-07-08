import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/performance/cubit/performance_recorder_cubit.dart';
import 'package:loopy/theme/theme.dart';

/// A persistent elapsed-time readout shown while performance recording is
/// armed — collapses to nothing otherwise. Self-contained (mirrors the
/// record button's own pattern): decides its own visibility from
/// [PerformanceRecorderCubit] rather than the host conditionally including
/// it.
class ArmedIndicator extends StatelessWidget {
  /// Creates an [ArmedIndicator].
  const ArmedIndicator({super.key});

  static String _format(Duration elapsed) {
    final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PerformanceRecorderCubit>().state;
    if (state is! PerformanceRecorderArmed) return const SizedBox.shrink();

    final l10n = context.l10n;
    final theme = Theme.of(context);
    final looper = theme.extension<LooperTheme>()!;

    return Padding(
      key: const Key('tracks_armedIndicator'),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_manual_record, size: 12, color: looper.recordColor),
          const SizedBox(width: 6),
          Text(
            l10n.perfArmedElapsed(_format(state.elapsed)),
            style: theme.textTheme.labelLarge?.copyWith(
              color: looper.recordColor,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (state.overrun) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: l10n.perfCaptureGlitch,
              child: Icon(
                Icons.warning_amber_rounded,
                size: 14,
                color: theme.colorScheme.error,
              ),
            ),
          ],
          if (state.lowDiskWarning) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: l10n.perfLowDisk,
              child: Icon(
                Icons.sd_card_alert_outlined,
                size: 14,
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
