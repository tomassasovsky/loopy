import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/performance/cubit/performance_recorder_cubit.dart';
import 'package:loopy/theme/theme.dart';

/// Toggles performance-recording arm/disarm from `TracksToolbar`.
/// Self-contained — reads [PerformanceRecorderCubit] directly rather than
/// threading callbacks through the host (mirrors `SessionMenu`'s own
/// pattern in this toolbar).
class PerfRecordButton extends StatelessWidget {
  /// Creates a [PerfRecordButton].
  const PerfRecordButton({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final looper = theme.extension<LooperTheme>()!;
    final state = context.watch<PerformanceRecorderCubit>().state;
    final armed = state is PerformanceRecorderArmed;
    final busy =
        state is PerformanceRecorderFinalizing ||
        state is PerformanceRecorderRendering;
    final recoveryPending =
        state is PerformanceRecorderIdle && state.recoveryDirectory != null;
    final enabled = !busy && !recoveryPending;
    final tooltip = armed
        ? l10n.perfDisarm
        : busy
        ? l10n.perfArmDisabledRendering
        : l10n.perfArm;

    return IconButton(
      key: const Key('tracks_perfRecord'),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      iconSize: 20,
      color: armed ? looper.recordColor : looper.toolbarIconColor,
      icon: Icon(
        armed ? Icons.fiber_manual_record : Icons.fiber_manual_record_outlined,
      ),
      onPressed: enabled
          ? () =>
                unawaited(context.read<PerformanceRecorderCubit>().toggleArm())
          : null,
    );
  }
}
