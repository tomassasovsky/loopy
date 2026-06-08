import 'package:loopy_engine/loopy_engine.dart';
import 'package:meta/meta.dart';

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

/// A saved Loopy session: the transport/tempo settings plus the tracks. Paired
/// with per-track stem WAV files in a `.loopy` bundle directory.
@immutable
class Session {
  /// Creates a [Session].
  const Session({
    required this.sampleRate,
    required this.channels,
    required this.baseLengthFrames,
    required this.tempoBpm,
    required this.syncLoopToTempo,
    required this.quantizeMode,
    required this.metronomeOn,
    required this.countInEnabled,
    required this.tracks,
  });

  /// Projects a [Session] from a decoded JSON map.
  factory Session.fromJson(Map<String, dynamic> json) => Session(
    sampleRate: (json['sampleRate'] as num).toInt(),
    channels: (json['channels'] as num).toInt(),
    baseLengthFrames: (json['baseLengthFrames'] as num).toInt(),
    tempoBpm: (json['tempoBpm'] as num).toDouble(),
    syncLoopToTempo: json['syncLoopToTempo'] as bool,
    quantizeMode: QuantizeMode.values.byName(json['quantizeMode'] as String),
    metronomeOn: json['metronomeOn'] as bool,
    countInEnabled: json['countInEnabled'] as bool,
    tracks: [
      for (final t in json['tracks'] as List<dynamic>)
        SessionTrack.fromJson(t as Map<String, dynamic>),
    ],
  );

  /// The manifest schema version this code writes and accepts.
  static const int formatVersion = 1;

  /// The manifest filename within a session bundle.
  static const String manifestName = 'session.json';

  /// Negotiated device sample rate the session was recorded at.
  final int sampleRate;

  /// Interleaved channel count of the stems.
  final int channels;

  /// The base (master) loop length in frames.
  final int baseLengthFrames;

  /// Tempo in beats per minute.
  final double tempoBpm;

  /// Whether loop-to-tempo sync is enabled.
  final bool syncLoopToTempo;

  /// Quantize-start resolution.
  final QuantizeMode quantizeMode;

  /// Whether the metronome is enabled.
  final bool metronomeOn;

  /// Whether the one-bar count-in is enabled.
  final bool countInEnabled;

  /// The session's tracks (those that hold audio).
  final List<SessionTrack> tracks;

  /// Serializes this session manifest to a JSON map.
  Map<String, dynamic> toJson() => {
    'version': formatVersion,
    'sampleRate': sampleRate,
    'channels': channels,
    'baseLengthFrames': baseLengthFrames,
    'tempoBpm': tempoBpm,
    'syncLoopToTempo': syncLoopToTempo,
    'quantizeMode': quantizeMode.name,
    'metronomeOn': metronomeOn,
    'countInEnabled': countInEnabled,
    'tracks': [for (final t in tracks) t.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Session &&
          runtimeType == other.runtimeType &&
          sampleRate == other.sampleRate &&
          channels == other.channels &&
          baseLengthFrames == other.baseLengthFrames &&
          tempoBpm == other.tempoBpm &&
          syncLoopToTempo == other.syncLoopToTempo &&
          quantizeMode == other.quantizeMode &&
          metronomeOn == other.metronomeOn &&
          countInEnabled == other.countInEnabled &&
          _listEquals(tracks, other.tracks);

  @override
  int get hashCode => Object.hash(
    sampleRate,
    channels,
    baseLengthFrames,
    tempoBpm,
    syncLoopToTempo,
    quantizeMode,
    metronomeOn,
    countInEnabled,
    Object.hashAll(tracks),
  );
}

bool _listEquals(List<SessionTrack> a, List<SessionTrack> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
