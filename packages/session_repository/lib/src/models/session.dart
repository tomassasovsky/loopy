import 'package:meta/meta.dart';
import 'package:session_repository/src/session_exception.dart';

/// One track's persisted settings within a [Session]. The audio itself lives in
/// the referenced [stem] WAV file, not in this manifest.
@immutable
class SessionTrack {
  /// Creates a [SessionTrack].
  const SessionTrack({
    required this.channel,
    required this.volume,
    required this.muted,
    required this.multiple,
    required this.lengthFrames,
    required this.stem,
  });

  /// Projects a [SessionTrack] from a decoded JSON map.
  factory SessionTrack.fromJson(Map<String, dynamic> json) => SessionTrack(
    channel: (json['channel'] as num).toInt(),
    volume: (json['volume'] as num).toDouble(),
    muted: json['muted'] as bool,
    multiple: (json['multiple'] as num).toInt(),
    lengthFrames: (json['lengthFrames'] as num).toInt(),
    stem: json['stem'] as String,
  );

  /// Track channel index.
  final int channel;

  /// Playback gain in `0..1`.
  final double volume;

  /// Whether the track is muted.
  final bool muted;

  /// Track length in whole base loops (`>= 1`).
  final int multiple;

  /// Captured length in frames (`multiple` × the base length).
  final int lengthFrames;

  /// Filename of this track's stem WAV within the session bundle.
  final String stem;

  /// Serializes this track to a JSON map.
  Map<String, dynamic> toJson() => {
    'channel': channel,
    'volume': volume,
    'muted': muted,
    'multiple': multiple,
    'lengthFrames': lengthFrames,
    'stem': stem,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionTrack &&
          runtimeType == other.runtimeType &&
          channel == other.channel &&
          volume == other.volume &&
          muted == other.muted &&
          multiple == other.multiple &&
          lengthFrames == other.lengthFrames &&
          stem == other.stem;

  @override
  int get hashCode =>
      Object.hash(channel, volume, muted, multiple, lengthFrames, stem);
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
/// v2+) the lane + monitor effect chains. Paired with per-track stem WAV files
/// in a `.loopy` bundle directory.
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

  /// The manifest schema version this code writes and accepts. v2 added the
  /// lane + monitor effect chains; v1 bundles still load (with empty chains).
  static const int formatVersion = 2;

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
