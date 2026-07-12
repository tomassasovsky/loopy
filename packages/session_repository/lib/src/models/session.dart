import 'package:meta/meta.dart';
import 'package:session_repository/src/session_exception.dart';

/// One captured audio buffer within a [SessionLane]: a single overdub layer,
/// stored as the WAV [file] in the session bundle. The audio itself lives in
/// the referenced file, not in this manifest.
///
/// A track's schema-v3 lanes carry an ordered list of these. Part 1 writes
/// exactly one per lane (the live buffer); the undo/redo layers are a later
/// revision, at which point a lane holds several.
@immutable
class SessionLayer {
  /// Creates a [SessionLayer].
  const SessionLayer({required this.file});

  /// Projects a [SessionLayer] from a decoded JSON map.
  factory SessionLayer.fromJson(Map<String, dynamic> json) =>
      SessionLayer(file: json['file'] as String);

  /// Filename of this layer's WAV within the session bundle.
  final String file;

  /// Serializes this layer to a JSON map.
  Map<String, dynamic> toJson() => {'file': file};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionLayer &&
          runtimeType == other.runtimeType &&
          file == other.file;

  @override
  int get hashCode => file.hashCode;
}

/// One lane of a [SessionTrack] (schema v3): its mix/routing plus the ordered
/// audio [layers]. A lane records one input into its own mono buffer, so a
/// track persists one of these per active lane.
///
/// [layers] is the lane's pool contents oldest→newest: the [undoCount] undo
/// snapshots, then the live buffer, then the [redoCount] redo snapshots. The
/// live buffer is `layers[liveIndex]` (== [undoCount]), and
/// `layers.length == undoCount + 1 + redoCount`. Part 1 always emits a single
/// live layer (`undoCount == redoCount == 0`); later revisions populate the
/// undo/redo layers so a reloaded lane can undo/redo.
@immutable
class SessionLane {
  /// Creates a [SessionLane].
  const SessionLane({
    required this.lane,
    required this.volume,
    required this.muted,
    required this.outputMask,
    required this.inputChannel,
    required this.layers,
    this.undoCount = 0,
    this.redoCount = 0,
  });

  /// Projects a [SessionLane] from a decoded JSON map.
  factory SessionLane.fromJson(Map<String, dynamic> json) => SessionLane(
    lane: (json['lane'] as num).toInt(),
    volume: (json['volume'] as num).toDouble(),
    muted: json['muted'] as bool,
    outputMask: (json['outputMask'] as num).toInt(),
    inputChannel: (json['inputChannel'] as num).toInt(),
    layers: [
      for (final l in json['layers'] as List<dynamic>)
        SessionLayer.fromJson(l as Map<String, dynamic>),
    ],
    undoCount: (json['undoCount'] as num?)?.toInt() ?? 0,
    redoCount: (json['redoCount'] as num?)?.toInt() ?? 0,
  );

  /// Lane index within the track.
  final int lane;

  /// Playback gain in `0..1`.
  final double volume;

  /// Whether the lane is muted.
  final bool muted;

  /// Bitmask of output channels this lane plays to (bit c => output c).
  final int outputMask;

  /// Hardware input channel this lane records (`-1` = none).
  final int inputChannel;

  /// The lane's audio buffers, oldest undo → live → newest redo.
  final List<SessionLayer> layers;

  /// Number of leading [layers] that are undo snapshots (below the live
  /// buffer).
  final int undoCount;

  /// Number of trailing [layers] that are redo snapshots (above the live
  /// buffer).
  final int redoCount;

  /// Index into [layers] of the live (currently playing) buffer.
  int get liveIndex => undoCount;

  /// Serializes this lane to a JSON map.
  Map<String, dynamic> toJson() => {
    'lane': lane,
    'volume': volume,
    'muted': muted,
    'outputMask': outputMask,
    'inputChannel': inputChannel,
    'layers': [for (final l in layers) l.toJson()],
    'undoCount': undoCount,
    'redoCount': redoCount,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionLane &&
          runtimeType == other.runtimeType &&
          lane == other.lane &&
          volume == other.volume &&
          muted == other.muted &&
          outputMask == other.outputMask &&
          inputChannel == other.inputChannel &&
          undoCount == other.undoCount &&
          redoCount == other.redoCount &&
          _listEquals(layers, other.layers);

  @override
  int get hashCode => Object.hash(
    lane,
    volume,
    muted,
    outputMask,
    inputChannel,
    undoCount,
    redoCount,
    Object.hashAll(layers),
  );
}

/// One track's persisted settings within a [Session]: its length and its
/// [lanes] (schema v3). The audio lives in the lanes' layer WAV files, not in
/// this manifest.
@immutable
class SessionTrack {
  /// Creates a [SessionTrack].
  const SessionTrack({
    required this.channel,
    required this.multiple,
    required this.lengthFrames,
    required this.lanes,
  });

  /// Projects a [SessionTrack] from a decoded JSON map.
  ///
  /// A v1/v2 track (no `lanes`, one `stem` filename + track-level mix) migrates
  /// to a single lane-0 lane holding one live layer — presence-keyed on
  /// `lanes`, matching the manifest's other version rungs.
  factory SessionTrack.fromJson(Map<String, dynamic> json) {
    final rawLanes = json['lanes'] as List<dynamic>?;
    final lanes = rawLanes != null
        ? [
            for (final l in rawLanes)
              SessionLane.fromJson(l as Map<String, dynamic>),
          ]
        : <SessionLane>[
            SessionLane(
              lane: 0,
              volume: (json['volume'] as num).toDouble(),
              muted: json['muted'] as bool,
              outputMask: 0x3,
              inputChannel: -1,
              layers: [SessionLayer(file: json['stem'] as String)],
            ),
          ];
    return SessionTrack(
      channel: (json['channel'] as num).toInt(),
      multiple: (json['multiple'] as num).toInt(),
      lengthFrames: (json['lengthFrames'] as num).toInt(),
      lanes: lanes,
    );
  }

  /// Track channel index.
  final int channel;

  /// Track length in whole base loops (`>= 1`).
  final int multiple;

  /// Captured length in frames (`multiple` × the base length).
  final int lengthFrames;

  /// The track's lanes, each with its own mix/routing and audio layers.
  final List<SessionLane> lanes;

  /// Serializes this track to a JSON map.
  Map<String, dynamic> toJson() => {
    'channel': channel,
    'multiple': multiple,
    'lengthFrames': lengthFrames,
    'lanes': [for (final l in lanes) l.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionTrack &&
          runtimeType == other.runtimeType &&
          channel == other.channel &&
          multiple == other.multiple &&
          lengthFrames == other.lengthFrames &&
          _listEquals(lanes, other.lanes);

  @override
  int get hashCode =>
      Object.hash(channel, multiple, lengthFrames, Object.hashAll(lanes));
}

/// One lane's effect chain within a [Session] (schema v2+).
///
/// The chain is stored as the opaque [encoded] string produced by the looper
/// domain's `encodeTrackEffects` — the same wire format settings persist — so
/// this data package never depends on the effect model. Chains exist
/// independently of audio, so a [channel]/[lane] here may not match any
/// [SessionTrack].
@immutable
class SessionLaneChain {
  /// Creates a [SessionLaneChain].
  const SessionLaneChain({
    required this.channel,
    required this.lane,
    required this.encoded,
  });

  /// Projects a [SessionLaneChain] from a decoded JSON map.
  factory SessionLaneChain.fromJson(Map<String, dynamic> json) =>
      SessionLaneChain(
        channel: (json['channel'] as num).toInt(),
        lane: (json['lane'] as num).toInt(),
        encoded: json['encoded'] as String,
      );

  /// Track channel this chain belongs to.
  final int channel;

  /// Lane index within the track.
  final int lane;

  /// The chain as an opaque `encodeTrackEffects` string.
  final String encoded;

  /// Serializes this chain to a JSON map.
  Map<String, dynamic> toJson() => {
    'channel': channel,
    'lane': lane,
    'encoded': encoded,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionLaneChain &&
          runtimeType == other.runtimeType &&
          channel == other.channel &&
          lane == other.lane &&
          encoded == other.encoded;

  @override
  int get hashCode => Object.hash(channel, lane, encoded);
}

/// One hardware input's live-monitor configuration within a [Session] (schema
/// v2+): routing / mix plus the monitor's [encoded] effect chain.
@immutable
class SessionMonitor {
  /// Creates a [SessionMonitor].
  const SessionMonitor({
    required this.input,
    required this.enabled,
    required this.outputMask,
    required this.volume,
    required this.muted,
    required this.encoded,
  });

  /// Projects a [SessionMonitor] from a decoded JSON map.
  factory SessionMonitor.fromJson(Map<String, dynamic> json) => SessionMonitor(
    input: (json['input'] as num).toInt(),
    enabled: json['enabled'] as bool,
    outputMask: (json['outputMask'] as num).toInt(),
    volume: (json['volume'] as num).toDouble(),
    muted: json['muted'] as bool,
    encoded: json['encoded'] as String,
  );

  /// Hardware input index.
  final int input;

  /// Whether live monitoring of the input is enabled.
  final bool enabled;

  /// Bitmask of output channels the monitor plays to.
  final int outputMask;

  /// Monitor output gain in `0..1`.
  final double volume;

  /// Whether the monitor is muted.
  final bool muted;

  /// The monitor chain as an opaque `encodeTrackEffects` string.
  final String encoded;

  /// Serializes this monitor to a JSON map.
  Map<String, dynamic> toJson() => {
    'input': input,
    'enabled': enabled,
    'outputMask': outputMask,
    'volume': volume,
    'muted': muted,
    'encoded': encoded,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionMonitor &&
          runtimeType == other.runtimeType &&
          input == other.input &&
          enabled == other.enabled &&
          outputMask == other.outputMask &&
          volume == other.volume &&
          muted == other.muted &&
          encoded == other.encoded;

  @override
  int get hashCode =>
      Object.hash(input, enabled, outputMask, volume, muted, encoded);
}

/// A saved Loopy session: the transport/tempo settings, the tracks, and (schema
/// v2+) the lane + monitor effect chains. Paired with per-lane, per-layer WAV
/// files (schema v3) in a `.loopy` bundle directory.
@immutable
class Session {
  /// Creates a [Session].
  const Session({
    required this.sampleRate,
    required this.channels,
    required this.baseLengthFrames,
    required this.tracks,
    this.laneChains = const [],
    this.monitors = const [],
  });

  /// Projects a [Session] from a decoded JSON map.
  ///
  /// A v1 manifest (no `laneChains` / `monitors`) loads with empty chains, so a
  /// legacy bundle restores explicitly-cleared chains rather than leftovers.
  /// Throws [SessionUnsupportedVersion] for a manifest written by a newer,
  /// incompatible schema version than this code understands.
  factory Session.fromJson(Map<String, dynamic> json) {
    final version = (json['version'] as num?)?.toInt() ?? formatVersion;
    if (version > formatVersion) {
      throw SessionUnsupportedVersion(
        version: version,
        supported: formatVersion,
      );
    }
    return Session(
      sampleRate: (json['sampleRate'] as num).toInt(),
      channels: (json['channels'] as num).toInt(),
      baseLengthFrames: (json['baseLengthFrames'] as num).toInt(),
      tracks: [
        for (final t in json['tracks'] as List<dynamic>)
          SessionTrack.fromJson(t as Map<String, dynamic>),
      ],
      laneChains: [
        for (final c in (json['laneChains'] as List<dynamic>? ?? const []))
          SessionLaneChain.fromJson(c as Map<String, dynamic>),
      ],
      monitors: [
        for (final m in (json['monitors'] as List<dynamic>? ?? const []))
          SessionMonitor.fromJson(m as Map<String, dynamic>),
      ],
    );
  }

  /// The manifest schema version this code writes and accepts. v3 replaced the
  /// per-track single `stem` with per-lane [SessionTrack.lanes] (each holding
  /// ordered audio layers); v2 added the lane + monitor effect chains. v1 and
  /// v2 bundles still load — a legacy track migrates to one lane-0 live layer,
  /// and a v1 bundle loads with empty chains.
  static const int formatVersion = 3;

  /// The manifest filename within a session bundle.
  static const String manifestName = 'session.json';

  /// Negotiated device sample rate the session was recorded at.
  final int sampleRate;

  /// Interleaved channel count of the stems.
  final int channels;

  /// The base (master) loop length in frames.
  final int baseLengthFrames;

  /// The session's tracks (those that hold audio).
  final List<SessionTrack> tracks;

  /// The lane effect chains the session defines (empty for a v1 bundle).
  final List<SessionLaneChain> laneChains;

  /// The per-input live monitors the session defines (empty for a v1 bundle).
  final List<SessionMonitor> monitors;

  /// Serializes this session manifest to a JSON map.
  Map<String, dynamic> toJson() => {
    'version': formatVersion,
    'sampleRate': sampleRate,
    'channels': channels,
    'baseLengthFrames': baseLengthFrames,
    'tracks': [for (final t in tracks) t.toJson()],
    'laneChains': [for (final c in laneChains) c.toJson()],
    'monitors': [for (final m in monitors) m.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Session &&
          runtimeType == other.runtimeType &&
          sampleRate == other.sampleRate &&
          channels == other.channels &&
          baseLengthFrames == other.baseLengthFrames &&
          _listEquals(tracks, other.tracks) &&
          _listEquals(laneChains, other.laneChains) &&
          _listEquals(monitors, other.monitors);

  @override
  int get hashCode => Object.hash(
    sampleRate,
    channels,
    baseLengthFrames,
    Object.hashAll(tracks),
    Object.hashAll(laneChains),
    Object.hashAll(monitors),
  );
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
