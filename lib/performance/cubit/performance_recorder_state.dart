part of 'performance_recorder_cubit.dart';

/// Why a capture stopped before disarm (D-FAIL): reported inside
/// [PerformanceRecordStoppedEarly].
enum PerformanceStopReason {
  /// The export volume ran out of space mid-capture (`perf_drain.c`'s
  /// self-stop).
  diskFull,

  /// The audio device changed mid-capture, forcing a reconfigure that can't
  /// keep the capture taps running.
  deviceChanged,
}

/// The outcome of a finished capture, carried by
/// [PerformanceRecorderCompleted].
sealed class PerformanceRecordResult extends Equatable {
  const PerformanceRecordResult();
}

/// The bundle finalized and every stem rendered successfully.
class PerformanceRecordDone extends PerformanceRecordResult {
  /// Creates a [PerformanceRecordDone] pointing at the finished bundle.
  const PerformanceRecordDone(this.path);

  /// The capture bundle's directory.
  final String path;

  @override
  List<Object?> get props => [path];
}

/// The bundle finalized, but at least one stem failed to render — the
/// captures themselves (master/inputs/loops) are still delivered intact
/// (partial success, matching `PerformanceRenderTrackStatus`'s own posture).
class PerformanceRecordPartial extends PerformanceRecordResult {
  /// Creates a [PerformanceRecordPartial] pointing at the still-usable bundle.
  const PerformanceRecordPartial(this.path);

  /// The capture bundle's directory.
  final String path;

  @override
  List<Object?> get props => [path];
}

/// The capture stopped before a normal disarm — [reason] explains why.
/// Whatever was captured up to that point is still finalized and delivered
/// at [path], same as [PerformanceRecordDone]/[PerformanceRecordPartial].
class PerformanceRecordStoppedEarly extends PerformanceRecordResult {
  /// Creates a [PerformanceRecordStoppedEarly] pointing at the delivered
  /// bundle, for [reason].
  const PerformanceRecordStoppedEarly(this.path, this.reason);

  /// The capture bundle's directory.
  final String path;

  /// Why the capture stopped.
  final PerformanceStopReason reason;

  @override
  List<Object?> get props => [path, reason];
}

/// The full lifecycle of a performance-recording capture, observed from
/// [PerformanceRepository] plus the render/`.als` pipeline this cubit itself
/// drives. Sealed so every transition is exhaustively handled at the call
/// site (UI `switch` expressions, `BlocListener.listenWhen`) rather than by
/// convention.
sealed class PerformanceRecorderState extends Equatable {
  const PerformanceRecorderState();
}

/// Not armed. [recoveryDirectory] is non-null only at boot, when a crashed
/// (unfinalized) capture was found and is offered for recovery/discard — it
/// clears once the user (or [PerformanceRecorderCubit.recoverBootCapture]/
/// [PerformanceRecorderCubit.discardBootCapture]) resolves it.
class PerformanceRecorderIdle extends PerformanceRecorderState {
  /// Creates a [PerformanceRecorderIdle].
  const PerformanceRecorderIdle({this.recoveryDirectory});

  /// The crashed capture directory offered for recovery, or `null` when
  /// there is nothing to recover.
  final String? recoveryDirectory;

  @override
  List<Object?> get props => [recoveryDirectory];
}

/// Armed: the engine's capture taps are running. [elapsed] and [overrun]
/// mirror the engine snapshot's own perf fields (part 1) so the
/// armed-indicator widget can show a live readout without a second data
/// path.
class PerformanceRecorderArmed extends PerformanceRecorderState {
  /// Creates a [PerformanceRecorderArmed].
  const PerformanceRecorderArmed({
    required this.elapsed,
    required this.overrun,
    this.lowDiskWarning = false,
  });

  /// Time elapsed since arm.
  final Duration elapsed;

  /// Whether the capture has dropped at least one frame (a ring overrun) —
  /// surfaced as a glitch flag, not a failure; the capture keeps running.
  final bool overrun;

  /// A one-time, non-blocking low-free-space check sampled at arm time
  /// (D-FAIL) — carried through every tick of this armed session rather than
  /// re-checked continuously.
  final bool lowDiskWarning;

  @override
  List<Object?> get props => [elapsed, overrun, lowDiskWarning];
}

/// Disarmed; converting raw PCM to WAV and assembling the bundle
/// (`PerformanceRepository.disarm`'s own `finalizing` phase). Brief —
/// there is nothing for the UI to show progress for.
class PerformanceRecorderFinalizing extends PerformanceRecorderState {
  /// Creates a [PerformanceRecorderFinalizing].
  const PerformanceRecorderFinalizing();

  @override
  List<Object?> get props => [];
}

/// The bundle is finalized; the offline dry/wet/master render (parts 7-8)
/// and the `.als`/`fx-chains.txt` generation (parts 9-10) this cubit itself
/// drives are in progress. [percent] mirrors
/// `PerformanceRepository.renderProgress.progressPercent`. Arm is refused
/// while in this state (umbrella — no render queue).
class PerformanceRecorderRendering extends PerformanceRecorderState {
  /// Creates a [PerformanceRecorderRendering].
  const PerformanceRecorderRendering({required this.percent});

  /// Render completion, `0..100`.
  final int percent;

  @override
  List<Object?> get props => [percent];
}

/// The capture is fully finished: bundle finalized, render (and `.als`
/// generation) settled. [discarded] is the short-capture auto-discard
/// signal (< 2s captured with zero logged events) — a `BlocListener` reacts
/// to it to show a notice, matching the plan's "no ephemeral state" rule:
/// this is a ordinary field on an ordinary transition, not a one-shot state
/// of its own.
class PerformanceRecorderCompleted extends PerformanceRecorderState {
  /// Creates a [PerformanceRecorderCompleted] with a delivered [result].
  const PerformanceRecorderCompleted(this.result) : discarded = false;

  /// Creates a [PerformanceRecorderCompleted] for a capture too short to
  /// deliver (< 2 s, nothing logged) — auto-discarded rather than finalized.
  const PerformanceRecorderCompleted.discardedShort()
    : result = null,
      discarded = true;

  /// The capture's outcome, or `null` when [discarded].
  final PerformanceRecordResult? result;

  /// Whether this capture was auto-discarded (too short, nothing logged)
  /// rather than delivered.
  final bool discarded;

  @override
  List<Object?> get props => [result, discarded];
}
