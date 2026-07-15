import 'package:loopy_engine/loopy_engine.dart';
import 'package:meta/meta.dart';
import 'package:performance_repository/src/models/performance_chains.dart';

/// One lane's PCM + (arm-only) effect chain at the moment of a performance
/// snapshot.
///
/// [deferred] mirrors the umbrella plan's D-SNAP: a lane mid-overdub at arm
/// has no stable PCM to export yet (the audio thread is still writing it) —
/// [pcmFile] is `null` and [deferred] is `true`. Its content instead reaches
/// disk via the retired-layer persistence path (part 5) when the overdub
/// pass finally retires; the disarm-time snapshot pass covers the common case
/// (a track recorded fresh and finished during the performance).
@immutable
class PerformanceLaneSnapshot {
  /// Creates a [PerformanceLaneSnapshot].
  const PerformanceLaneSnapshot({
    required this.lane,
    required this.lengthFrames,
    required this.deferred,
    this.pcmFile,
    this.effects = const [],
  });

  /// Rebuilds a [PerformanceLaneSnapshot] from a decoded JSON map.
  factory PerformanceLaneSnapshot.fromJson(Map<String, dynamic> json) =>
      PerformanceLaneSnapshot(
        lane: (json['lane'] as num).toInt(),
        lengthFrames: (json['lenFrames'] as num).toInt(),
        deferred: json['deferred'] as bool,
        pcmFile: json['pcmRef'] as String?,
        effects: [
          for (final e in (json['effects'] as List<dynamic>? ?? const []))
            TrackEffect.fromJson(e as Map<String, dynamic>),
        ],
      );

  /// Lane index within the track.
  final int lane;

  /// Captured length in frames (`0` for a deferred lane).
  final int lengthFrames;

  /// Whether this lane was mid-overdub at snapshot time (no stable PCM yet).
  final bool deferred;

  /// The lane's exported WAV filename relative to the bundle directory (e.g.
  /// `loops/track0-lane0.wav`), or `null` when [deferred] or empty.
  final String? pcmFile;

  /// The lane's effect chain, in order. Only ever populated on an arm-time
  /// snapshot ("chain at t=0" — the ER diagram's `FX_ENTRY`); a disarm-time
  /// snapshot leaves this empty since chain changes are already logged
  /// (D-LOG), not re-snapshotted.
  final List<TrackEffect> effects;

  /// Serializes this lane snapshot to a JSON map.
  Map<String, dynamic> toJson() => {
    'lane': lane,
    'lenFrames': lengthFrames,
    'deferred': deferred,
    if (pcmFile != null) 'pcmRef': pcmFile,
    if (effects.isNotEmpty) 'effects': [for (final e in effects) e.toJson()],
  };
}

/// One track's state + lanes at the moment of a performance snapshot.
@immutable
class PerformanceTrackSnapshot {
  /// Creates a [PerformanceTrackSnapshot].
  const PerformanceTrackSnapshot({
    required this.channel,
    required this.state,
    required this.volume,
    required this.muted,
    required this.multiple,
    this.lanes = const [],
  });

  /// Rebuilds a [PerformanceTrackSnapshot] from a decoded JSON map.
  factory PerformanceTrackSnapshot.fromJson(Map<String, dynamic> json) =>
      PerformanceTrackSnapshot(
        channel: (json['channel'] as num).toInt(),
        state: TrackState.values.byName(json['state'] as String),
        volume: (json['volume'] as num).toDouble(),
        muted: json['muted'] as bool,
        multiple: (json['multiple'] as num).toInt(),
        lanes: [
          for (final l in (json['lanes'] as List<dynamic>? ?? const []))
            PerformanceLaneSnapshot.fromJson(l as Map<String, dynamic>),
        ],
      );

  /// Track channel index.
  final int channel;

  /// State-machine phase at snapshot time.
  final TrackState state;

  /// Playback gain in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above unity).
  final double volume;

  /// Whether the track is muted.
  final bool muted;

  /// Track length in whole base loops.
  final int multiple;

  /// Per-lane snapshots, in lane order.
  final List<PerformanceLaneSnapshot> lanes;

  /// Serializes this track snapshot to a JSON map.
  Map<String, dynamic> toJson() => {
    'channel': channel,
    'state': state.name,
    'volume': volume,
    'muted': muted,
    'multiple': multiple,
    'lanes': [for (final l in lanes) l.toJson()],
  };
}

/// The arm-time snapshot (ARM_SNAPSHOT / TRACK_STATE / LANE_SNAPSHOT /
/// FX_ENTRY in the umbrella plan's data model): clock position, transport +
/// mix state, and every settled lane's PCM + effect chain, plus the monitor
/// and master-bus state the engine snapshot alone cannot supply (see
/// [PerformanceChains]).
@immutable
class PerformanceArmSnapshot {
  /// Creates a [PerformanceArmSnapshot].
  const PerformanceArmSnapshot({
    required this.clockFrame,
    required this.masterLengthFrames,
    required this.masterGain,
    required this.limiterEnabled,
    required this.limiterCeiling,
    required this.latencyOffsetFrames,
    this.tracks = const [],
    this.monitors = const [],
  });

  /// Rebuilds a [PerformanceArmSnapshot] from a decoded JSON map.
  factory PerformanceArmSnapshot.fromJson(Map<String, dynamic> json) =>
      PerformanceArmSnapshot(
        clockFrame: (json['clockFrame'] as num).toInt(),
        masterLengthFrames: (json['masterLenFrames'] as num).toInt(),
        masterGain: (json['masterGain'] as num).toDouble(),
        limiterEnabled: json['limiterOn'] as bool,
        limiterCeiling: (json['limiterCeiling'] as num).toDouble(),
        latencyOffsetFrames: (json['latencyOffsetFrames'] as num).toInt(),
        tracks: [
          for (final t in (json['tracks'] as List<dynamic>? ?? const []))
            PerformanceTrackSnapshot.fromJson(t as Map<String, dynamic>),
        ],
        monitors: [
          for (final m in (json['monitors'] as List<dynamic>? ?? const []))
            m as Map<String, dynamic>,
        ],
      );

  /// Master playhead position at the arm instant.
  final int clockFrame;

  /// Master loop length in frames at arm time.
  final int masterLengthFrames;

  /// Master output gain at arm time.
  final double masterGain;

  /// Whether the master peak limiter was enabled at arm time.
  final bool limiterEnabled;

  /// The master peak limiter's ceiling at arm time.
  final double limiterCeiling;

  /// The active device profile's latency offset in frames at arm time.
  final int latencyOffsetFrames;

  /// Every track's state at arm time.
  final List<PerformanceTrackSnapshot> tracks;

  /// Every monitor input's configuration at arm time, as pre-encoded JSON
  /// maps (`{input, enabled, outputMask, volume, muted, effects}`).
  final List<Map<String, dynamic>> monitors;

  /// Serializes this snapshot to a JSON map.
  Map<String, dynamic> toJson() => {
    'clockFrame': clockFrame,
    'masterLenFrames': masterLengthFrames,
    'masterGain': masterGain,
    'limiterOn': limiterEnabled,
    'limiterCeiling': limiterCeiling,
    'latencyOffsetFrames': latencyOffsetFrames,
    'tracks': [for (final t in tracks) t.toJson()],
    'monitors': monitors,
  };
}

/// The disarm-time snapshot (DISARM_SNAPSHOT): a second settled-lane capture
/// pass covering a track recorded fresh during the performance and then just
/// played — recording finalization produces no retire event, so without this
/// pass its stem would have no PCM source anywhere (D-SNAP).
@immutable
class PerformanceDisarmSnapshot {
  /// Creates a [PerformanceDisarmSnapshot].
  const PerformanceDisarmSnapshot({this.tracks = const []});

  /// Rebuilds a [PerformanceDisarmSnapshot] from a decoded JSON map.
  factory PerformanceDisarmSnapshot.fromJson(Map<String, dynamic> json) =>
      PerformanceDisarmSnapshot(
        tracks: [
          for (final t in (json['tracks'] as List<dynamic>? ?? const []))
            PerformanceTrackSnapshot.fromJson(t as Map<String, dynamic>),
        ],
      );

  /// Every track's state at disarm time.
  final List<PerformanceTrackSnapshot> tracks;

  /// Serializes this snapshot to a JSON map.
  Map<String, dynamic> toJson() => {
    'tracks': [for (final t in tracks) t.toJson()],
  };
}

/// One retired overdub layer's raw PCM file (already written natively by
/// `perf_drain.c`, part 5) — parsed here read-only so callers (the offline
/// renderer, tests) get typed access instead of re-parsing JSON.
@immutable
class PerformanceLayerEntry {
  /// Creates a [PerformanceLayerEntry].
  const PerformanceLayerEntry({
    required this.channel,
    required this.slot,
    required this.generation,
    required this.frame,
    required this.frameCount,
    required this.laneCount,
    required this.filename,
  });

  /// Rebuilds a [PerformanceLayerEntry] from a decoded JSON map.
  factory PerformanceLayerEntry.fromJson(Map<String, dynamic> json) =>
      PerformanceLayerEntry(
        channel: (json['channel'] as num).toInt(),
        slot: (json['slot'] as num).toInt(),
        generation: (json['generation'] as num).toInt(),
        frame: (json['frame'] as num).toInt(),
        frameCount: (json['frame_count'] as num).toInt(),
        laneCount: (json['lane_count'] as num).toInt(),
        filename: json['filename'] as String,
      );

  /// Track channel the layer belongs to.
  final int channel;

  /// The pool slot the layer occupied at retire time.
  final int slot;

  /// The track's dub generation at retire time.
  final int generation;

  /// Best-effort capture-frame snapshot at retire time (not sample-accurate;
  /// see `layer_staging_ring.h`).
  final int frame;

  /// Frame count of the layer's PCM.
  final int frameCount;

  /// Number of interleaved lanes in the layer's PCM file.
  final int laneCount;

  /// The raw PCM filename within the capture directory.
  final String filename;
}

/// The `performance.json` sidecar manifest, merging the native fields
/// `perf_drain.c` writes continuously while armed (sample rate, capture
/// frames, overrun accounting, the retired-layer manifest) with the arm +
/// disarm snapshots and slug this Dart layer adds at finalize.
///
/// The native fields are kept as a raw, passed-through map ([native]) rather
/// than individually re-modeled: this package only ever augments and
/// re-serializes them, so round-tripping the exact map avoids any risk of a
/// lossy re-encoding drifting from what `perf_drain.c` actually wrote.
@immutable
class PerformanceManifest {
  /// Creates a [PerformanceManifest].
  const PerformanceManifest({
    required this.slug,
    required this.finalized,
    required this.native,
    this.armSnapshot,
    this.disarmSnapshot,
  });

  /// Rebuilds a [PerformanceManifest] from a decoded `performance.json` map.
  ///
  /// [native] strips this package's own fields (`slug`, `armSnapshot`,
  /// `disarmSnapshot`, `finalized`) out of [json] rather than storing it
  /// whole: a manifest that has already been finalized once carries those
  /// fields itself, and storing them in `native` would let a stale prior
  /// `armSnapshot`/`disarmSnapshot` leak back out of [toJson] on a second
  /// finalize pass that doesn't happen to supply a fresh replacement (see
  /// `PerformanceRepository._finalize`, which re-finalizes via this factory
  /// for exactly that reason).
  factory PerformanceManifest.fromJson(Map<String, dynamic> json) {
    final armJson = json['armSnapshot'];
    final disarmJson = json['disarmSnapshot'];
    final native = Map<String, dynamic>.of(json)
      ..remove('slug')
      ..remove('armSnapshot')
      ..remove('disarmSnapshot')
      ..remove('finalized');
    return PerformanceManifest(
      slug: json['slug'] as String? ?? '',
      finalized: json['finalized'] as bool? ?? false,
      native: native,
      armSnapshot: armJson is Map<String, dynamic>
          ? PerformanceArmSnapshot.fromJson(armJson)
          : null,
      disarmSnapshot: disarmJson is Map<String, dynamic>
          ? PerformanceDisarmSnapshot.fromJson(disarmJson)
          : null,
    );
  }

  /// The bundle's directory-name slug (`perf-YYYYMMDD-HHMMSS`, D-NAME).
  final String slug;

  /// Whether finalize completed (the crash-salvage marker, D-SALVAGE).
  final bool finalized;

  /// The raw decoded `performance.json` map, as last read from disk —
  /// carries every native field (`sample_rate`, `capture_frames`,
  /// `overrun_count`, `overrun_gaps`, `layers`, `stopped_early`) verbatim.
  final Map<String, dynamic> native;

  /// The arm-time snapshot, or `null` if the capture crashed before it could
  /// be written (see `arm-snapshot.json`'s own crash-survival note).
  final PerformanceArmSnapshot? armSnapshot;

  /// The disarm-time snapshot, or `null` for a capture recovered from a crash
  /// (there is no live engine left to take a second pass from).
  final PerformanceDisarmSnapshot? disarmSnapshot;

  /// The negotiated sample rate, from the native fields.
  int get sampleRate => (native['sample_rate'] as num?)?.toInt() ?? 0;

  /// Total frames captured since arm, from the native fields.
  int get captureFrames => (native['capture_frames'] as num?)?.toInt() ?? 0;

  /// Capture ring overruns since arm, from the native fields.
  int get overrunCount => (native['overrun_count'] as num?)?.toInt() ?? 0;

  /// Why capture stopped early (`disk_full` / `device_changed`), or `null`
  /// for a normal disarm.
  String? get stoppedEarly => native['stopped_early'] as String?;

  /// Every retired overdub layer's raw PCM file (part 5), from the native
  /// fields.
  List<PerformanceLayerEntry> get layers => [
    for (final l in (native['layers'] as List<dynamic>? ?? const []))
      PerformanceLayerEntry.fromJson(l as Map<String, dynamic>),
  ];

  /// Serializes this manifest to a JSON map: every native field verbatim,
  /// overlaid with this package's own fields.
  Map<String, dynamic> toJson() => {
    ...native,
    'slug': slug,
    if (armSnapshot != null) 'armSnapshot': armSnapshot!.toJson(),
    if (disarmSnapshot != null) 'disarmSnapshot': disarmSnapshot!.toJson(),
    'finalized': finalized,
  };
}
