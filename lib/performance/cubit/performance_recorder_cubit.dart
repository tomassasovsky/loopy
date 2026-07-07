import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:daw_export/daw_export.dart';
import 'package:equatable/equatable.dart';
import 'package:performance_repository/performance_repository.dart';

part 'performance_recorder_state.dart';

/// Drives performance-recording's full app-facing lifecycle: arming/disarming
/// [PerformanceRepository], the offline render + `.als`/`fx-chains.txt`
/// pipeline once a capture finalizes, and boot-time crash-recovery salvage
/// (D-SALVAGE).
///
/// State transitions for a *live* arm/disarm are driven reactively off
/// [PerformanceRepository.captureStatus] rather than from [toggleArm]'s own
/// call sites — `SessionCubit` also calls [PerformanceRepository.disarm]
/// directly (auto-disarm-before-load), and this cubit must reflect that too.
/// Boot-salvage ([recoverBootCapture]) is the one path the status stream
/// never reports (`recoverCapture` has no live session to disarm), so it
/// drives the same render pipeline directly instead.
///
/// The manifest → [DawProject] mapping stays inside `daw_export`
/// ([DawManifestReader]) — this cubit only decides *when* to call it and
/// writes the resulting bytes to disk, keeping `daw_export` itself free of
/// write-side I/O.
class PerformanceRecorderCubit extends Cubit<PerformanceRecorderState> {
  /// Creates a [PerformanceRecorderCubit] driving [performance].
  ///
  /// [armedTickInterval] paces the [PerformanceRecorderArmed] elapsed-time
  /// readout; [renderPollInterval] paces polling
  /// [PerformanceRepository.renderProgress] after a disarm. [now] supplies
  /// the double-press-guard clock; injectable for deterministic tests.
  PerformanceRecorderCubit({
    required PerformanceRepository performance,
    this.armedTickInterval = const Duration(milliseconds: 250),
    this.renderPollInterval = const Duration(milliseconds: 200),
    DateTime Function() now = DateTime.now,
    Future<int?> Function(String path)? freeSpaceBytes,
  }) : _performance = performance,
       _now = now,
       _freeSpaceBytes = freeSpaceBytes ?? _dfFreeSpaceBytes,
       super(const PerformanceRecorderIdle()) {
    _statusSubscription = _performance.captureStatus.listen(_onStatus);
  }

  /// Below this, [PerformanceRecorderArmed.lowDiskWarning] is set (D-FAIL).
  static const int lowDiskThresholdBytes = 500 * 1024 * 1024;

  final PerformanceRepository _performance;
  final DateTime Function() _now;
  final Future<int?> Function(String path) _freeSpaceBytes;

  /// How often [PerformanceRecorderArmed.elapsed] refreshes while armed.
  final Duration armedTickInterval;

  /// How often [PerformanceRepository.renderProgress] is polled after
  /// disarm.
  final Duration renderPollInterval;

  late final StreamSubscription<PerformanceCaptureStatus> _statusSubscription;
  Timer? _armedTicker;
  Timer? _renderPoller;
  String? _captureDir;
  DateTime? _armedAt;
  bool _lowDiskAtArm = false;
  bool _loaded = false;

  /// Best-effort free-space check on [path]'s volume via `df` — `null` (no
  /// warning) on any platform or failure this can't read, since the warning
  /// is non-blocking and this must never fail `arm`.
  static Future<int?> _dfFreeSpaceBytes(String path) async {
    if (!Platform.isMacOS && !Platform.isLinux) return null;
    try {
      final result = await Process.run('df', ['-k', path]);
      if (result.exitCode != 0) return null;
      final lines = (result.stdout as String).trim().split('\n');
      if (lines.length < 2) return null;
      final fields = lines.last.trim().split(RegExp(r'\s+'));
      if (fields.length < 4) return null;
      final availableKb = int.tryParse(fields[3]);
      return availableKb == null ? null : availableKb * 1024;
    } on ProcessException {
      return null;
    }
  }

  /// Scans for a capture left unfinalized by a crash (D-SALVAGE) and, if
  /// found, surfaces it via [PerformanceRecorderIdle.recoveryDirectory].
  /// Idempotent — safe to call once at boot.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final unfinalized = await _performance.findUnfinalized();
    if (unfinalized.isEmpty) return;
    final current = state;
    if (current is PerformanceRecorderIdle) {
      _emit(
        PerformanceRecorderIdle(recoveryDirectory: unfinalized.first.directory),
      );
    }
  }

  /// Salvages the crash-recovered capture [load] found: finalizes it, then
  /// runs it through the same render/`.als` pipeline a normal disarm does.
  Future<void> recoverBootCapture() async {
    final dir = _pendingRecoveryDirectory();
    if (dir == null) return;
    _emit(const PerformanceRecorderFinalizing());
    await _performance.recoverCapture(dir);
    await _runRenderPipeline(dir);
  }

  /// Discards the crash-recovered capture [load] found, outright.
  Future<void> discardBootCapture() async {
    final dir = _pendingRecoveryDirectory();
    if (dir == null) return;
    await _performance.discardUnfinalized(dir);
    _emit(const PerformanceRecorderIdle());
  }

  String? _pendingRecoveryDirectory() {
    final current = state;
    return current is PerformanceRecorderIdle
        ? current.recoveryDirectory
        : null;
  }

  /// Renames the just-delivered capture to [to] (D-NAME) — the completion
  /// sheet's rename action. A no-op when not currently
  /// [PerformanceRecorderCompleted] with a delivered result. Rethrows
  /// [ArgumentError] / [PerformanceNameCollision] so the caller can show an
  /// inline error, same as `SessionCubit.renameSession`'s callers.
  Future<void> renameCompletedCapture(String to) async {
    final current = state;
    if (current is! PerformanceRecorderCompleted) return;
    final result = current.result;
    if (result == null) return;
    final oldPath = switch (result) {
      PerformanceRecordDone(:final path) => path,
      PerformanceRecordPartial(:final path) => path,
      PerformanceRecordStoppedEarly(:final path) => path,
    };
    final newPath = await _performance.renameCapture(oldPath, to);
    final renamed = switch (result) {
      PerformanceRecordDone() => PerformanceRecordDone(newPath),
      PerformanceRecordPartial() => PerformanceRecordPartial(newPath),
      PerformanceRecordStoppedEarly(:final reason) =>
        PerformanceRecordStoppedEarly(
          newPath,
          reason,
        ),
    };
    _emit(PerformanceRecorderCompleted(renamed));
  }

  /// Arms or disarms depending on the current state; a no-op while
  /// finalizing/rendering/completed (no queue) or while a boot-recovery
  /// prompt is still unresolved. A disarm within 1s of arming is ignored
  /// (double-press guard) — the arm gesture and the disarm gesture are easy
  /// to fat-finger back to back on the same control.
  Future<void> toggleArm() async {
    switch (state) {
      case PerformanceRecorderIdle(recoveryDirectory: null):
        await _performance.arm();
      case PerformanceRecorderArmed():
        final armedAt = _armedAt;
        if (armedAt != null &&
            _now().difference(armedAt) < const Duration(seconds: 1)) {
          return;
        }
        await _performance.disarmAndFinalize();
      case PerformanceRecorderIdle():
      case PerformanceRecorderFinalizing():
      case PerformanceRecorderRendering():
      case PerformanceRecorderCompleted():
        break;
    }
  }

  void _onStatus(PerformanceCaptureStatus status) {
    switch (status) {
      case PerformanceCaptureStatus.idle:
        break; // only ever the initial replay; nothing to react to yet
      case PerformanceCaptureStatus.armed:
        _captureDir = _performance.armedDirectory;
        _armedAt = _now();
        _lowDiskAtArm = false;
        _armedTicker?.cancel();
        _emitArmedTick();
        _armedTicker = Timer.periodic(
          armedTickInterval,
          (_) => _emitArmedTick(),
        );
        unawaited(_checkLowDisk(_captureDir));
      case PerformanceCaptureStatus.finalizing:
        _armedTicker?.cancel();
        _armedTicker = null;
        _emit(const PerformanceRecorderFinalizing());
      case PerformanceCaptureStatus.done:
        unawaited(_afterFinalized());
    }
  }

  void _emitArmedTick() {
    final progress = _performance.captureProgress;
    _emit(
      PerformanceRecorderArmed(
        elapsed: progress.elapsed,
        overrun: progress.overrun,
        lowDiskWarning: _lowDiskAtArm,
      ),
    );
  }

  Future<void> _checkLowDisk(String? dir) async {
    if (dir == null) return;
    final free = await _freeSpaceBytes(dir);
    _lowDiskAtArm = free != null && free < lowDiskThresholdBytes;
    if (state is PerformanceRecorderArmed) _emitArmedTick();
  }

  Future<void> _afterFinalized() async {
    final dir = _captureDir;
    final armedAt = _armedAt;
    _armedAt = null;
    if (dir == null) return;
    final elapsed = armedAt == null
        ? Duration.zero
        : _now().difference(armedAt);
    if (_isShortEmptyCapture(dir, elapsed)) {
      // The offline render already started in the background (disarm's own
      // fire-and-forget) — deleting the directory here only wastes its
      // in-flight writes (the renderer only ever writes files, never asserts
      // the directory still exists between writes), so this race is benign.
      await _performance.discardUnfinalized(dir);
      _captureDir = null;
      _emit(const PerformanceRecorderCompleted.discardedShort());
      return;
    }
    await _runRenderPipeline(dir);
  }

  bool _isShortEmptyCapture(String dir, Duration elapsed) {
    if (elapsed >= const Duration(seconds: 2)) return false;
    final entries = EventLogReader.readAll(dir);
    return entries == null || entries.isEmpty;
  }

  Future<void> _runRenderPipeline(String dir) async {
    _emit(const PerformanceRecorderRendering(percent: 0));
    final completer = Completer<void>();
    _renderPoller?.cancel();
    _renderPoller = Timer.periodic(renderPollInterval, (_) {
      _pollRender(dir, completer);
    });
    _pollRender(dir, completer);
    return completer.future;
  }

  void _pollRender(String dir, Completer<void> completer) {
    if (completer.isCompleted) return;
    final progress = _performance.renderProgress;
    _emit(PerformanceRecorderRendering(percent: progress.progressPercent));
    if (!progress.done) return;
    _renderPoller?.cancel();
    unawaited(_finishRender(dir).whenComplete(completer.complete));
  }

  Future<void> _finishRender(String dir) async {
    await _writeDawExports(dir);
    _captureDir = null;
    final anyFailed = _performance.renderTrackStatuses.any((s) => !s.succeeded);
    final stoppedEarly = _readStoppedEarly(dir);
    final PerformanceRecordResult result;
    if (stoppedEarly != null) {
      result = PerformanceRecordStoppedEarly(dir, stoppedEarly);
    } else if (anyFailed) {
      result = PerformanceRecordPartial(dir);
    } else {
      result = PerformanceRecordDone(dir);
    }
    _emit(PerformanceRecorderCompleted(result));
  }

  Future<void> _writeDawExports(String dir) async {
    final project = DawManifestReader.read(dir);
    if (project != null) {
      await File('$dir/project.als').writeAsBytes(buildAls(project));
    }
    final chains = FxChainsWriter.render(dir);
    if (chains != null) {
      await File('$dir/fx-chains.txt').writeAsString(chains);
    }
  }

  PerformanceStopReason? _readStoppedEarly(String dir) {
    final manifestFile = File('$dir/${PerformanceRepository.manifestName}');
    if (!manifestFile.existsSync()) return null;
    try {
      final manifest = PerformanceManifest.fromJson(
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>,
      );
      return switch (manifest.stoppedEarly) {
        'disk_full' => PerformanceStopReason.diskFull,
        'device_changed' => PerformanceStopReason.deviceChanged,
        _ => null,
      };
    } on FormatException {
      return null;
    }
  }

  void _emit(PerformanceRecorderState next) {
    if (isClosed) return;
    emit(next);
  }

  @override
  Future<void> close() {
    _armedTicker?.cancel();
    _renderPoller?.cancel();
    unawaited(_statusSubscription.cancel());
    return super.close();
  }
}
