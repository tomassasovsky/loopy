import 'package:flutter/foundation.dart';
import 'package:looper_repository/src/models/track_effect.dart';
import 'package:loopy_engine/loopy_engine.dart' show LooperMode;

/// One lane's restored audio, routing, and mix inside a [SessionRigTrack].
///
/// Carries the lane's ordered audio [layers] (part 1 restores one live buffer;
/// the undo/redo layers are a later revision) plus its routing/mix. [liveIndex]
/// (== [undoCount]) selects the currently playing buffer.
@immutable
class SessionRigLane {
  /// Creates a [SessionRigLane].
  const SessionRigLane({
    required this.lane,
    required this.layers,
    required this.volume,
    required this.muted,
    required this.outputMask,
    required this.inputChannel,
    this.undoCount = 0,
    this.redoCount = 0,
  });

  /// Lane index within the track.
  final int lane;

  /// The lane's mono audio buffers, oldest undo → live → newest redo.
  final List<Float32List> layers;

  /// Playback gain in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above unity).
  final double volume;

  /// Whether the lane is muted.
  final bool muted;

  /// Bitmask of output channels this lane plays to (bit c => output c).
  final int outputMask;

  /// Hardware input channel this lane records (`-1` = none).
  final int inputChannel;

  /// Number of leading [layers] that are undo snapshots.
  final int undoCount;

  /// Number of trailing [layers] that are redo snapshots.
  final int redoCount;

  /// Index into [layers] of the live (currently playing) buffer.
  int get liveIndex => undoCount;

  /// The lane's live (currently playing) buffer.
  Float32List get livePcm => layers[liveIndex];
}

/// One track's restored lanes inside a [SessionRig].
@immutable
class SessionRigTrack {
  /// Creates a [SessionRigTrack].
  const SessionRigTrack({
    required this.channel,
    required this.lanes,
    this.lengthPresetBars = 0,
    this.oneShot = false,
  });

  /// Track channel index.
  final int channel;

  /// The track's lanes, each with its own audio, routing, and mix. Lane 0 is
  /// first — it is the primary import that resets the track's undo state.
  final List<SessionRigLane> lanes;

  /// The track's length preset (A6): `0` = AUTO, `1..64` = a fixed bar count.
  /// Restored on session load; it only governs a FUTURE defining recording on
  /// this track, so restoring it here is inert for the audio the load just
  /// imported — it only matters if the user re-records the track later.
  final int lengthPresetBars;

  /// The track's One Shot flag (song-mode-spec.md §2, B5c): `true` = plays
  /// once then stops. Restored on session load — see
  /// `LooperRepository.applySession`'s reset-then-restore handling.
  final bool oneShot;
}

/// One hardware input's live-monitor configuration inside a [SessionRig].
@immutable
class SessionRigMonitor {
  /// Creates a [SessionRigMonitor].
  const SessionRigMonitor({
    required this.input,
    required this.enabled,
    required this.outputMask,
    required this.volume,
    required this.muted,
    required this.effects,
  });

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

  /// The monitor's effect chain (empty = the clean/dry path).
  final List<TrackEffect> effects;
}

/// Everything a saved session defines, expressed in looper-domain types.
///
/// The bloc layer builds this from a decoded session manifest and hands it to
/// `LooperRepository.applySession` — the ONE session-apply path — so the
/// repositories stay decoupled (a repository never imports a repository).
/// Chains the rig does NOT define are explicitly reset on apply: a legacy
/// manifest with no chains loads as "all chains cleared", never "whatever was
/// lying around".
///
/// A transient apply-time DTO (built once from a decoded bundle, consumed once
/// by `LooperRepository.applySession`); it is immutable but carries no value
/// equality by design — it is never compared, only applied.
@immutable
class SessionRig {
  /// Creates a [SessionRig].
  const SessionRig({
    this.baseLengthFrames = 0,
    this.tracks = const [],
    this.laneEffects = const {},
    this.monitors = const [],
    this.looperMode = LooperMode.multi,
    this.primaryTrack = -1,
    this.oneShotChannels = const {},
  });

  /// The base (master) loop length in frames; `0` for an empty session.
  final int baseLengthFrames;

  /// The tracks holding audio, with their restored mix.
  final List<SessionRigTrack> tracks;

  /// Every lane effect chain the session defines, keyed by `(channel, lane)`.
  /// Chains exist independently of audio, so keys may reference tracks with no
  /// [tracks] entry.
  final Map<(int, int), List<TrackEffect>> laneEffects;

  /// The per-input live monitors the session defines.
  final List<SessionRigMonitor> monitors;

  /// The session's looper mode (schema v4, B5c). Restored unconditionally on
  /// apply, like [baseLengthFrames] — a session with no tracks still carries a
  /// mode choice.
  final LooperMode looperMode;

  /// The session's crowned primary track (Sync/Band, D18), or `-1` when none
  /// was ever crowned. See `LooperRepository.applySession`'s doc for why this
  /// cannot always be fully reset to `-1` on the LIVE engine (no "un-crown"
  /// native call exists) even though it is captured/restored here.
  final int primaryTrack;

  /// Every channel with One Shot armed (post-B5c independent review fix),
  /// independent of whether that channel has a [SessionRigTrack] entry — a
  /// channel pre-armed with One Shot but never recorded onto has no track
  /// entry at all (see `SessionRepository._capture`'s doc), so its flag only
  /// round-trips through this session-level set, not through
  /// [SessionRigTrack.oneShot]. Restored unconditionally on apply, like
  /// [looperMode]/[primaryTrack] above.
  final Set<int> oneShotChannels;
}
