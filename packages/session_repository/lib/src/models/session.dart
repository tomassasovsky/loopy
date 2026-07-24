import 'package:loopy_engine/loopy_engine.dart';
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

  /// Playback gain in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above unity).
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

  /// Maximum layers a lane can hold, mirroring the engine's `LE_POOL_SLOTS`
  /// (one live buffer plus up to 255 undo/redo snapshots). A bundle claiming
  /// more is rejected on load.
  static const int maxLayers = 256;

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
    this.lengthPresetBars = 0,
    this.oneShot = false,
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
    final channel = (json['channel'] as num).toInt();
    for (final lane in lanes) {
      final expected = lane.undoCount + 1 + lane.redoCount;
      if (lane.undoCount < 0 || lane.redoCount < 0) {
        throw SessionCorruptLayers(
          channel: channel,
          lane: lane.lane,
          reason: 'negative undo/redo count',
        );
      }
      if (lane.layers.length != expected) {
        throw SessionCorruptLayers(
          channel: channel,
          lane: lane.lane,
          reason:
              '${lane.layers.length} layers but undoCount+1+redoCount == '
              '$expected',
        );
      }
      if (expected > SessionLane.maxLayers) {
        throw SessionCorruptLayers(
          channel: channel,
          lane: lane.lane,
          reason: '$expected layers exceeds the ${SessionLane.maxLayers} cap',
        );
      }
    }
    return SessionTrack(
      channel: channel,
      multiple: (json['multiple'] as num).toInt(),
      lengthFrames: (json['lengthFrames'] as num).toInt(),
      lanes: lanes,
      lengthPresetBars: (json['lengthPresetBars'] as num?)?.toInt() ?? 0,
      oneShot: json['oneShot'] as bool? ?? false,
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

  /// This track's persisted length preset in bars (schema v4, Phase A);
  /// `0` = AUTO (no preset — today's only behavior).
  ///
  /// Placeholder pending A6 (`2026-07-22-feat-tempo-aware-looper-modes-part-1
  /// -plan.md`, task A6 — track length presets): as of this PR the looper
  /// domain's `Track` model has no length-preset field yet, so
  /// `session_repository`'s capture path always writes `0` here. The field
  /// exists now — matching the manifest v4 schema in full per D12 — so a
  /// session saved on this code round-trips the value once A6 lands the
  /// real per-track preset choice; no migration is needed later.
  final int lengthPresetBars;

  /// This track's persisted One Shot flag (schema v4, B5c; song-mode-spec.md
  /// §2): `true` = the track plays once and then stops instead of looping.
  /// Default `false` (today's only behavior pre-B5c).
  final bool oneShot;

  /// Serializes this track to a JSON map.
  Map<String, dynamic> toJson() => {
    'channel': channel,
    'multiple': multiple,
    'lengthFrames': lengthFrames,
    'lanes': [for (final l in lanes) l.toJson()],
    'lengthPresetBars': lengthPresetBars,
    'oneShot': oneShot,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionTrack &&
          runtimeType == other.runtimeType &&
          channel == other.channel &&
          multiple == other.multiple &&
          lengthFrames == other.lengthFrames &&
          lengthPresetBars == other.lengthPresetBars &&
          oneShot == other.oneShot &&
          _listEquals(lanes, other.lanes);

  @override
  int get hashCode => Object.hash(
    channel,
    multiple,
    lengthFrames,
    lengthPresetBars,
    oneShot,
    Object.hashAll(lanes),
  );
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

  /// Monitor output gain in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above
  /// unity).
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
///
/// Schema v4 (`2026-07-22-feat-tempo-aware-looper-modes-plan.md`, decision
/// D12) adds the Phase-A tempo grid + click + count-in fields below. Every
/// one of them defaults to the tempo-free/grid-off value, so a v3 manifest
/// loads as "Multi, grid off" with zero data loss — the same
/// "grid-off is the compatible default" pattern used across the whole tempo
/// series (D6). [clickMode]/[clickOutputMask]/[clickVolume] and
/// [countInBars] intentionally carry the richer shape the engine/repository
/// layer actually shipped in A1/A2 (`TransportState`/`EngineSnapshot`) rather
/// than the index plan ERD's earlier sketch (`bool metronomeOn`,
/// `bool countIn`) — the ERD predates those implementation details and the
/// plan's own D12 says to prefer fidelity to the real model.
///
/// B5c adds [looperMode] and [primaryTrack] here (session-level) and
/// [SessionTrack.oneShot] (per-track) — the `songSections`/`bandGroups`
/// fields the index plan ERD originally sketched are DROPPED per the B1
/// spec (a Song/Band "section" is a track, nothing separate to persist).
///
/// [oneShotChannels] is a post-B5c addition (independent review of #295):
/// [SessionTrack.oneShot] only exists for a channel `_capture()` actually
/// builds a [SessionTrack] for, which requires the channel to hold content
/// (`lanes` non-empty) — but `LooperModeControl.setOneShot`'s own doc says
/// One Shot is "a persistent per-track SETTING, not content" and is settable
/// on an empty track in advance of recording (the UI honors this:
/// `SetupTrackOneShotRow` renders for every track regardless of state). A
/// flag armed on a still-empty channel therefore had no manifest field to
/// round-trip through — silently dropped on save. [oneShotChannels] fixes
/// this the same way [looperMode]/[primaryTrack] fixed the equivalent gap
/// for those fields: hoisted to session level, captured from every channel
/// unconditionally (see `SessionRepository._sessionFrom`), independent of
/// whether that channel has a [SessionTrack] entry at all.
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
    this.tempoBpm = 0,
    this.tempoSource = TempoSource.none,
    this.tsNum = 4,
    this.tsDen = 4,
    this.quantizeDiv = GridDivision.off,
    this.clickMode = ClickMode.off,
    this.clickOutputMask = 0,
    this.clickVolume = 1,
    this.countInBars = 0,
    this.looperMode = LooperMode.multi,
    this.primaryTrack = -1,
    this.oneShotChannels = const [],
  });

  /// Projects a [Session] from a decoded JSON map.
  ///
  /// A v1 manifest (no `laneChains` / `monitors`) loads with empty chains, so a
  /// legacy bundle restores explicitly-cleared chains rather than leftovers. A
  /// v3-or-earlier manifest (no tempo grid fields at all) loads with every new
  /// field at its grid-off default (see the class doc) — zero data loss, and
  /// indistinguishable from a v4 session someone deliberately saved with the
  /// grid off. Throws [SessionUnsupportedVersion] for a manifest written by a
  /// newer, incompatible schema version than this code understands.
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
      tempoBpm: (json['tempoBpm'] as num?)?.toDouble() ?? 0,
      tempoSource: _tempoSourceFromJson(json['tempoSource'] as String?),
      tsNum: (json['tsNum'] as num?)?.toInt() ?? 4,
      tsDen: (json['tsDen'] as num?)?.toInt() ?? 4,
      quantizeDiv: _gridDivisionFromJson(json['quantizeDiv'] as String?),
      clickMode: _clickModeFromJson(json['clickMode'] as String?),
      clickOutputMask: (json['clickOutputMask'] as num?)?.toInt() ?? 0,
      clickVolume: (json['clickVolume'] as num?)?.toDouble() ?? 1,
      countInBars: (json['countInBars'] as num?)?.toInt() ?? 0,
      looperMode: _looperModeFromJson(json['looperMode'] as String?),
      primaryTrack: (json['primaryTrack'] as num?)?.toInt() ?? -1,
      oneShotChannels: [
        for (final c in (json['oneShotChannels'] as List<dynamic>? ?? const []))
          (c as num).toInt(),
      ],
    );
  }

  /// The manifest schema version this code writes and accepts. v4 adds the
  /// tempo-grid + click + count-in fields (see the class doc); every field is
  /// additive and defaults to grid-off, so v3 (and earlier) manifests still
  /// load losslessly. v3 replaced the per-track single `stem` with per-lane
  /// [SessionTrack.lanes] (each holding ordered audio layers); v2 added the
  /// lane + monitor effect chains. v1, v2, and v3 bundles still load — a
  /// legacy track migrates to one lane-0 live layer, and a v1 bundle loads
  /// with empty chains.
  static const int formatVersion = 4;

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

  /// Denominator-note beats per minute (schema v4, Phase A); `0` = unset (no
  /// tempo was ever set — mirrors `TransportState.tempoBpm`/
  /// `EngineSnapshot.tempoBpm`).
  final double tempoBpm;

  /// Where [tempoBpm] came from (D7 precedence); [TempoSource.none] when
  /// unset (default, and every pre-v4 session).
  final TempoSource tempoSource;

  /// Time-signature numerator (schema v4, Phase A; default `4`).
  final int tsNum;

  /// Time-signature denominator, `4` or `8` (schema v4, Phase A; default
  /// `4`).
  final int tsDen;

  /// Musical quantization granularity (schema v4, Phase A; default
  /// [GridDivision.off]).
  final GridDivision quantizeDiv;

  /// Click audibility mode (schema v4, Phase A; default [ClickMode.off]).
  /// The richer 4-value replacement for the index plan ERD's `metronomeOn`
  /// sketch — see the class doc.
  final ClickMode clickMode;

  /// Bitmask of hardware output channels the click sounds on (schema v4,
  /// Phase A; default `0`, no outputs — matches D5's "click defaults to no
  /// master outputs").
  final int clickOutputMask;

  /// Click volume in `0..LE_MAX_GAIN` (schema v4, Phase A; default `1`).
  final double clickVolume;

  /// Count-in length in measures (schema v4, Phase A); `0` = off (default).
  /// The richer measures-count replacement for the index plan ERD's
  /// `countIn` boolean sketch — see the class doc.
  final int countInBars;

  /// The session's looper mode (schema v4, B5c; default [LooperMode.multi]).
  /// Wired through `LooperRepository.applySession` on load (unlike the
  /// tempo-grid fields above, which are captured on save but not yet applied
  /// on load — see that method's doc).
  final LooperMode looperMode;

  /// The session's crowned primary track (schema v4, B5c, D18); `-1` = none
  /// was ever crowned (default).
  final int primaryTrack;

  /// Every channel with One Shot armed (schema v4, post-B5c independent
  /// review fix), captured regardless of whether that channel holds content
  /// — see the class doc. The authoritative, content-independent source for
  /// restoring One Shot on load; [SessionTrack.oneShot] remains the
  /// per-track mirror of this for a content-bearing channel (kept for a
  /// manifest a pre-fix build might still need to read defensively).
  final List<int> oneShotChannels;

  /// Serializes this session manifest to a JSON map. Always writes the
  /// current [formatVersion] (v4, per D12 — this code never writes v3).
  Map<String, dynamic> toJson() => {
    'version': formatVersion,
    'sampleRate': sampleRate,
    'channels': channels,
    'baseLengthFrames': baseLengthFrames,
    'tracks': [for (final t in tracks) t.toJson()],
    'laneChains': [for (final c in laneChains) c.toJson()],
    'monitors': [for (final m in monitors) m.toJson()],
    'tempoBpm': tempoBpm,
    'tempoSource': tempoSource.name,
    'tsNum': tsNum,
    'tsDen': tsDen,
    'quantizeDiv': quantizeDiv.name,
    'clickMode': clickMode.name,
    'clickOutputMask': clickOutputMask,
    'clickVolume': clickVolume,
    'countInBars': countInBars,
    'looperMode': looperMode.name,
    'primaryTrack': primaryTrack,
    'oneShotChannels': oneShotChannels,
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
          tempoSource == other.tempoSource &&
          tsNum == other.tsNum &&
          tsDen == other.tsDen &&
          quantizeDiv == other.quantizeDiv &&
          clickMode == other.clickMode &&
          clickOutputMask == other.clickOutputMask &&
          clickVolume == other.clickVolume &&
          countInBars == other.countInBars &&
          looperMode == other.looperMode &&
          primaryTrack == other.primaryTrack &&
          _listEquals(tracks, other.tracks) &&
          _listEquals(laneChains, other.laneChains) &&
          _listEquals(monitors, other.monitors) &&
          _listEquals(oneShotChannels, other.oneShotChannels);

  @override
  int get hashCode => Object.hash(
    sampleRate,
    channels,
    baseLengthFrames,
    tempoBpm,
    tempoSource,
    tsNum,
    tsDen,
    quantizeDiv,
    clickMode,
    clickOutputMask,
    clickVolume,
    countInBars,
    looperMode,
    primaryTrack,
    Object.hashAll(tracks),
    Object.hashAll(laneChains),
    Object.hashAll(monitors),
    Object.hashAll(oneShotChannels),
  );
}

/// Maps a persisted [Session.tempoSource] name back to a [TempoSource].
/// Absent (pre-v4) or unrecognized (a hypothetical future value this code
/// predates) values map to [TempoSource.none] — the same "grid-off" default
/// every other new v4 field falls back to.
TempoSource _tempoSourceFromJson(String? name) => TempoSource.values.firstWhere(
  (v) => v.name == name,
  orElse: () => TempoSource.none,
);

/// Maps a persisted [Session.quantizeDiv] name back to a [GridDivision].
/// Absent or unrecognized values map to [GridDivision.off].
GridDivision _gridDivisionFromJson(String? name) => GridDivision.values
    .firstWhere((v) => v.name == name, orElse: () => GridDivision.off);

/// Maps a persisted [Session.clickMode] name back to a [ClickMode]. Absent or
/// unrecognized values map to [ClickMode.off].
ClickMode _clickModeFromJson(String? name) => ClickMode.values.firstWhere(
  (v) => v.name == name,
  orElse: () => ClickMode.off,
);

/// Maps a persisted [Session.looperMode] name back to a [LooperMode]. Absent
/// (pre-v4, or a v4 session predating B5c) or unrecognized values map to
/// [LooperMode.multi] — the same "grid-off"-style default every other new v4
/// field falls back to.
LooperMode _looperModeFromJson(String? name) => LooperMode.values.firstWhere(
  (v) => v.name == name,
  orElse: () => LooperMode.multi,
);

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
