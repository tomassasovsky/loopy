/// The repository-owned phase of a performance capture, published on
/// `PerformanceRepository.captureStatus`.
///
/// Deliberately minimal: the full sealed `PerformanceRecorderState` (armed
/// elapsed/overrun readouts, render progress, completion result) is part 11's
/// `PerformanceRecorderCubit` concern, which projects this status plus the
/// engine snapshot's own perf fields into its richer UI state. This enum only
/// exists so that cubit has something to observe for the coarse
/// idle/armed/finalizing/done transitions this repository itself drives.
enum PerformanceCaptureStatus {
  /// Not armed; no capture in progress.
  idle,

  /// Armed: the engine's capture taps are running.
  armed,

  /// Disarmed; converting raw PCM to WAV and assembling the bundle.
  finalizing,

  /// The most recent capture's bundle is complete on disk.
  done,
}
