/// The repository-owned phase of a performance capture, published on
/// `PerformanceRepository.captureStatus`.
///
/// Deliberately minimal: the full sealed `PerformanceRecorderState` (armed
/// elapsed/overrun readouts, render progress, completion result) is part 11's
/// `PerformanceRecorderCubit` concern, which projects this status plus the
/// engine snapshot's own perf fields into its richer UI state. This enum only
/// exists so that cubit has something to observe for the coarse
/// idle/armed/finalizing/done transitions this repository itself drives.
///
/// The offline dry-stem render (part 7) `_finalize` kicks off is
/// deliberately NOT tracked here — `done` means "the bundle + manifest are
/// complete," independent of whether its stems have finished rendering yet.
/// A caller that needs render progress polls
/// `PerformanceRepository.renderProgress`/`renderTrackStatuses` directly
/// (poll-on-demand, the same convention `EngineSnapshot`'s own perf fields
/// use), rather than this repository owning a second internal polling loop.
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
