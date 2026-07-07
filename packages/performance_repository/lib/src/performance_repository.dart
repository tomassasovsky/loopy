import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:loopy_engine/loopy_engine.dart';
import 'package:performance_repository/src/models/performance_chains.dart';
import 'package:performance_repository/src/models/performance_manifest.dart';
import 'package:performance_repository/src/models/unfinalized_capture.dart';
import 'package:performance_repository/src/performance_capture_status.dart';
import 'package:performance_repository/src/performance_slug.dart';
import 'package:wav_codec/wav_codec.dart';

/// Owns the performance-recording capture lifecycle end-to-end.
///
/// Composes [AudioEngine] (never `NativeAudioEngine`) the same way every other
/// repository does. A capture's directory IS its final bundle location from
/// the moment of [arm] — `{exportsRoot}/<slug>/` — so there is no separate
/// temp-then-move step: raw continuous taps (master/monitor, `perf_drain.c`)
/// and this layer's own settled-lane WAV exports all land directly where the
/// finished bundle expects them, and [disarm] only needs to convert the raw
/// taps to WAV and merge the snapshot metadata into the sidecar.
class PerformanceRepository {
  /// Creates a [PerformanceRepository] driving [engine].
  ///
  /// [exportsRoot] resolves the `exports/` root directory new bundles are
  /// created under (mirrors `SessionRepository`'s `sessionsRoot`). [now]
  /// supplies the timestamp [arm] slugs from; injectable for deterministic
  /// tests.
  PerformanceRepository({
    required AudioEngine engine,
    required Future<String> Function() exportsRoot,
    DateTime Function() now = DateTime.now,
  }) : _engine = engine,
       _exportsRoot = exportsRoot,
       _now = now;

  final AudioEngine _engine;
  final Future<String> Function() _exportsRoot;
  final DateTime Function() _now;

  final StreamController<PerformanceCaptureStatus> _statusController =
      StreamController<PerformanceCaptureStatus>.broadcast();
  PerformanceCaptureStatus _status = PerformanceCaptureStatus.idle;

  /// The current capture directory, or `null` when not armed.
  String? _armedDir;
  PerformanceArmSnapshot? _armSnapshot;

  /// The sidecar manifest filename within a capture directory.
  static const String manifestName = 'performance.json';

  /// The arm-time snapshot's own file, written immediately at [arm] so it
  /// survives a crash before [disarm]'s finalize ever merges it into
  /// [manifestName] (which the drain thread keeps rewriting with only its own
  /// native fields while armed). Deleted once finalize folds it in.
  static const String _armSnapshotFileName = 'arm-snapshot.json';

  /// The repository-owned capture phase, replaying the current value to a new
  /// listener before live updates (mirrors `LooperRepository.looperState`).
  Stream<PerformanceCaptureStatus> get captureStatus async* {
    yield _status;
    yield* _statusController.stream;
  }

  /// The directory of the in-progress capture, or `null` when not armed.
  String? get armedDirectory => _armedDir;

  /// The offline renderer's current progress — dry stems (part 7), wet
  /// (FX-applied) stems, and the reconstructed master bus (both part 8) all
  /// run within the same render session, so one progress value covers all of
  /// them. A pure passthrough poll, the same on-demand convention
  /// `EngineSnapshot`'s own perf fields use. `PerformanceRenderProgress.empty`
  /// when no render has ever been started (or the most recent one already
  /// finished and nothing new has started since).
  PerformanceRenderProgress get renderProgress => _engine.renderPoll();

  /// Every track's render outcome discovered so far — grows progressively as
  /// each stem completes. `succeeded` reflects both that track's dry AND wet
  /// stem (either failing marks the track failed). A per-track failure does
  /// not mean the render as a whole failed (partial success); check
  /// [PerformanceRenderTrackStatus.succeeded] per entry.
  List<PerformanceRenderTrackStatus> get renderTrackStatuses =>
      _engine.renderTrackStatuses();

  void _setStatus(PerformanceCaptureStatus status) {
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }

  /// Arms performance-recording capture: resolves a new collision-free
  /// `{exportsRoot}/perf-YYYYMMDD-HHMMSS/` bundle directory, takes the
  /// arm-time settled-lane snapshot (mid-overdub lanes marked deferred, never
  /// blocking on them), and arms the engine's capture taps into it.
  ///
  /// Idempotent — calling this while already armed is a no-op success,
  /// mirroring `EnginePerformanceCapture.perfArm`'s own idempotency (the
  /// original session keeps draining into its original directory). [chains]
  /// supplies the lane/monitor effect chains and master-limiter state the
  /// engine snapshot alone cannot read back (see [PerformanceChains]).
  Future<EngineResult> arm({
    PerformanceChains chains = const PerformanceChains(),
  }) async {
    if (_armedDir != null) return EngineResult.ok;

    final root = await _exportsRoot();
    final base = performanceSlug(_now());
    var slug = base;
    var dir = '$root/$slug';
    var suffix = 1;
    while (Directory(dir).existsSync()) {
      slug = '$base-$suffix';
      dir = '$root/$slug';
      suffix++;
    }
    await Directory(dir).create(recursive: true);

    final snapshot = _engine.snapshot();
    final tracks = _captureSettledLanes(dir, chains: chains, writeChains: true);
    final armSnapshot = PerformanceArmSnapshot(
      clockFrame: snapshot.masterPositionFrames,
      masterLengthFrames: snapshot.masterLengthFrames,
      masterGain: snapshot.masterGain,
      limiterEnabled: chains.limiterEnabled,
      limiterCeiling: chains.limiterCeiling,
      latencyOffsetFrames: snapshot.recordOffsetFrames,
      tracks: tracks,
      monitors: _monitorsJson(chains),
    );
    await File(
      '$dir/$_armSnapshotFileName',
    ).writeAsString(jsonEncode(armSnapshot.toJson()));

    final result = _engine.perfArm(dir);
    if (!result.isOk) {
      final created = Directory(dir);
      if (created.existsSync()) created.deleteSync(recursive: true);
      return result;
    }

    _armedDir = dir;
    _armSnapshot = armSnapshot;
    _setStatus(PerformanceCaptureStatus.armed);
    return EngineResult.ok;
  }

  /// Disarms performance-recording capture: takes the disarm-time
  /// settled-lane snapshot pass (covers a track recorded fresh during the
  /// performance — recording finalization produces no retire event, so
  /// nothing else would persist its PCM), disarms the engine, converts the
  /// raw master/monitor PCM to WAV, and merges every snapshot into the
  /// sidecar with `finalized: true`.
  ///
  /// Idempotent — calling this while already disarmed is a no-op success.
  /// If `EnginePerformanceCapture.perfDisarm` itself fails (a stalled
  /// device), capture is left armed and finalize does not run — the rings
  /// and drain thread are retracted-but-running per its own contract, so
  /// finalizing now would race the still-writing drain thread.
  ///
  /// Once the bundle is finalized, starts the offline render (dry stems,
  /// wet/FX-applied stems, and the reconstructed master bus — parts 7-8) in
  /// the background — this method returns as soon as the bundle itself is
  /// complete, without waiting on the render; poll [renderProgress] /
  /// [renderTrackStatuses] for its outcome.
  Future<EngineResult> disarm() async {
    final dir = _armedDir;
    if (dir == null) return EngineResult.ok;

    _setStatus(PerformanceCaptureStatus.finalizing);
    final disarmSnapshot = PerformanceDisarmSnapshot(
      tracks: _captureSettledLanes(
        dir,
        chains: const PerformanceChains(),
        writeChains: false,
      ),
    );

    final result = _engine.perfDisarm();
    if (!result.isOk) {
      _setStatus(PerformanceCaptureStatus.armed);
      return result;
    }

    await _finalize(
      dir,
      armSnapshot: _armSnapshot,
      disarmSnapshot: disarmSnapshot,
    );

    _armedDir = null;
    _armSnapshot = null;
    _setStatus(PerformanceCaptureStatus.done);
    return EngineResult.ok;
  }

  /// An alias for [disarm], named for the load-while-armed call site
  /// (`SessionCubit` awaits this before applying a loaded session) so that
  /// caller reads self-documented rather than a bare `disarm()`.
  Future<EngineResult> disarmAndFinalize() => disarm();

  /// Exports every currently-settled (non-capturing) lane's PCM into the
  /// in-progress capture directory's `loops/`, overwriting any prior export
  /// for that lane. A no-op when not armed.
  ///
  /// Supports D-CLEAR: `ControlCubit` awaits this before issuing a clear
  /// while armed — clear-all is a legitimate performance move (logged as an
  /// event), but a track currently capturing is skipped here (its buffer is
  /// being written by the audio thread and would tear); the retired-layer
  /// persistence path (part 5) covers those instead.
  Future<void> persistLiveLanes() async {
    final dir = _armedDir;
    if (dir == null) return;
    _captureSettledLanes(
      dir,
      chains: const PerformanceChains(),
      writeChains: false,
    );
  }

  /// Scans the exports root for capture directories whose sidecar lacks
  /// `finalized: true` — evidence of a crash while armed (D-SALVAGE). An
  /// unreadable/corrupt sidecar counts as unfinalized too (the write itself
  /// was interrupted).
  Future<List<UnfinalizedCapture>> findUnfinalized() async {
    final root = Directory(await _exportsRoot());
    if (!root.existsSync()) return const [];
    final out = <UnfinalizedCapture>[];
    for (final entity in root.listSync()) {
      if (entity is! Directory) continue;
      final manifestFile = File('${entity.path}/$manifestName');
      if (!manifestFile.existsSync()) continue;
      var finalized = false;
      try {
        final json =
            jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
        finalized = json['finalized'] == true;
      } on FormatException {
        finalized = false;
      }
      if (!finalized) {
        out.add(
          UnfinalizedCapture(
            directory: entity.path,
            slug: _basename(entity.path),
          ),
        );
      }
    }
    return out;
  }

  /// Recovers a crashed (unfinalized) capture at [directory]: runs the same
  /// finalize path [disarm] does, minus a live disarm (there is no engine
  /// session left to stop) and minus a disarm-time snapshot pass (there is no
  /// live engine state left to snapshot). The arm-time snapshot recovers from
  /// its own crash-survival file when present. Also starts the offline
  /// render (dry stems, wet stems, master reconstruction), same as [disarm]
  /// — a salvage render is free (D-RENDER reads only from the capture
  /// directory, never the live engine).
  Future<void> recoverCapture(String directory) =>
      _finalize(directory, armSnapshot: null, disarmSnapshot: null);

  Future<void> _finalize(
    String dir, {
    required PerformanceArmSnapshot? armSnapshot,
    required PerformanceDisarmSnapshot? disarmSnapshot,
  }) async {
    final manifestFile = File('$dir/$manifestName');
    final Map<String, dynamic> native;
    try {
      native = PerformanceManifest.fromJson(
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>,
      ).native;
    } on FormatException {
      return; // corrupt sidecar: nothing recoverable to finalize
    } on FileSystemException {
      return; // no sidecar was ever written (e.g. disarmed within the drain
      // thread's first ~250ms cycle): nothing to finalize
    }
    final layout =
        native['channel_layout'] as Map<String, dynamic>? ?? const {};
    final sampleRate = (native['sample_rate'] as num?)?.toInt() ?? 0;
    final masterChannels = (layout['master_channels'] as num?)?.toInt() ?? 1;
    final capturedInputs = [
      for (final c in (layout['captured_inputs'] as List<dynamic>? ?? const []))
        (c as num).toInt(),
    ];

    final masterPcm = File('$dir/master.pcm');
    if (masterPcm.existsSync()) {
      final samples = _readRawPcm(masterPcm);
      await File('$dir/master.wav').writeAsBytes(
        WavCodec.encodeFloat32(
          samples: samples,
          sampleRate: sampleRate,
          channels: masterChannels,
        ),
      );
    }
    for (final input in capturedInputs) {
      final raw = File('$dir/input-$input.pcm');
      if (!raw.existsSync()) continue;
      final samples = _readRawPcm(raw);
      await File('$dir/live-input-$input.wav').writeAsBytes(
        WavCodec.encodeFloat32(
          samples: samples,
          sampleRate: sampleRate,
          channels: 2,
        ),
      );
    }

    var resolvedArm = armSnapshot;
    final armFile = File('$dir/$_armSnapshotFileName');
    if (resolvedArm == null && armFile.existsSync()) {
      resolvedArm = PerformanceArmSnapshot.fromJson(
        jsonDecode(await armFile.readAsString()) as Map<String, dynamic>,
      );
    }

    final manifest = PerformanceManifest(
      slug: _basename(dir),
      finalized: true,
      native: native,
      armSnapshot: resolvedArm,
      disarmSnapshot: disarmSnapshot,
    );
    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
    );
    if (armFile.existsSync()) armFile.deleteSync();

    // Kick off the offline render (dry stems, wet stems, master
    // reconstruction — parts 7-8, one render session covers all three):
    // fire-and-forget — the worker thread reads only from `dir` on disk from
    // here on, with no further dependency on this finalize call, so its
    // outcome is exposed purely via the poll-on-demand
    // `renderProgress`/`renderTrackStatuses` getters above rather than
    // awaited here. A failure to even START a
    // render (e.g. one is already running) is silently accepted — the
    // bundle itself is already complete and valid without its stems, which
    // is exactly the umbrella's partial-success posture applied one level up.
    _engine.renderBegin(dir);
  }

  /// Exports every currently-settled lane's PCM as a WAV directly into
  /// `<dir>/loops/`, and returns one [PerformanceTrackSnapshot] per non-empty
  /// track. A track currently capturing (recording/overdubbing) contributes
  /// `deferred: true` lane entries instead of exporting (D-SNAP) — its buffer
  /// is being written by the audio thread and exporting it would tear.
  List<PerformanceTrackSnapshot> _captureSettledLanes(
    String dir, {
    required PerformanceChains chains,
    required bool writeChains,
  }) {
    final snapshot = _engine.snapshot();
    final tracks = <PerformanceTrackSnapshot>[];
    for (var channel = 0; channel < snapshot.tracks.length; channel++) {
      final track = snapshot.tracks[channel];
      final capturing =
          track.state == TrackState.recording ||
          track.state == TrackState.overdubbing;
      final lanes = <PerformanceLaneSnapshot>[];
      for (var laneIndex = 0; laneIndex < track.lanes.length; laneIndex++) {
        if (capturing) {
          lanes.add(
            PerformanceLaneSnapshot(
              lane: laneIndex,
              lengthFrames: 0,
              deferred: true,
            ),
          );
          continue;
        }
        final lane = track.lanes[laneIndex];
        if (lane.lengthFrames <= 0) continue;
        final pcm = _engine.exportTrackLane(channel, laneIndex);
        if (pcm.isEmpty) continue;

        final filename = 'loops/track$channel-lane$laneIndex.wav';
        final wavFile = File('$dir/$filename');
        wavFile.parent.createSync(recursive: true);
        wavFile.writeAsBytesSync(
          WavCodec.encodeFloat32(
            samples: pcm,
            sampleRate: snapshot.sampleRate,
            channels: 1,
          ),
        );
        lanes.add(
          PerformanceLaneSnapshot(
            lane: laneIndex,
            lengthFrames: pcm.length,
            deferred: false,
            pcmFile: filename,
            effects: writeChains
                ? _laneEffects(chains, channel, laneIndex)
                : const [],
          ),
        );
      }
      if (lanes.isEmpty) continue;
      tracks.add(
        PerformanceTrackSnapshot(
          channel: channel,
          state: track.state,
          volume: track.volume,
          muted: track.muted,
          multiple: track.multiple,
          lanes: lanes,
        ),
      );
    }
    return tracks;
  }

  List<TrackEffect> _laneEffects(
    PerformanceChains chains,
    int channel,
    int lane,
  ) {
    for (final c in chains.laneChains) {
      if (c.channel == channel && c.lane == lane) return c.effects;
    }
    return const [];
  }

  List<Map<String, dynamic>> _monitorsJson(PerformanceChains chains) => [
    for (final m in chains.monitors)
      {
        'input': m.input,
        'enabled': m.enabled,
        'outputMask': m.outputMask,
        'volume': m.volume,
        'muted': m.muted,
        'effects': [for (final e in m.effects) e.toJson()],
      },
  ];

  Float32List _readRawPcm(File file) {
    final bytes = file.readAsBytesSync();
    return Float32List.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes ~/ 4,
    );
  }

  String _basename(String path) =>
      path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last;

  /// Releases the status stream. Does not disarm — callers that own the
  /// engine lifecycle are responsible for disarming before disposal.
  void dispose() {
    unawaited(_statusController.close());
  }
}
