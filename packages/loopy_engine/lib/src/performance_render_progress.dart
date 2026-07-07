import 'package:meta/meta.dart';

/// One track's offline-render outcome, from `AudioEngine.renderTrackStatus`.
@immutable
class PerformanceRenderTrackStatus {
  /// Creates a [PerformanceRenderTrackStatus].
  const PerformanceRenderTrackStatus({
    required this.channel,
    required this.succeeded,
  });

  /// Track channel index.
  final int channel;

  /// Whether this track's dry stem was written successfully. `false` is a
  /// per-stem failure (an unreadable lane/layer file) — the render still
  /// completes for every other track (partial success), it does not abort.
  final bool succeeded;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PerformanceRenderTrackStatus &&
          runtimeType == other.runtimeType &&
          channel == other.channel &&
          succeeded == other.succeeded;

  @override
  int get hashCode => Object.hash(channel, succeeded);

  @override
  String toString() =>
      'PerformanceRenderTrackStatus(channel: $channel, succeeded: $succeeded)';
}

/// A snapshot of an in-progress (or finished) offline render, from
/// `AudioEngine.renderPoll`.
@immutable
class PerformanceRenderProgress {
  /// Creates a [PerformanceRenderProgress].
  const PerformanceRenderProgress({
    required this.done,
    required this.progressPercent,
  });

  /// No render active (or none ever started).
  static const PerformanceRenderProgress empty = PerformanceRenderProgress(
    done: true,
    progressPercent: 100,
  );

  /// Whether the render worker has finished.
  final bool done;

  /// Overall progress, `0..100`, monotonic.
  final int progressPercent;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PerformanceRenderProgress &&
          runtimeType == other.runtimeType &&
          done == other.done &&
          progressPercent == other.progressPercent;

  @override
  int get hashCode => Object.hash(done, progressPercent);

  @override
  String toString() =>
      'PerformanceRenderProgress(done: $done, '
      'progressPercent: $progressPercent)';
}
