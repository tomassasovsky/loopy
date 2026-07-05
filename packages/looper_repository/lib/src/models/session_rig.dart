import 'package:flutter/foundation.dart';
import 'package:looper_repository/src/models/track_effect.dart';

/// One track's restored audio and mix inside a [SessionRig].
@immutable
class SessionRigTrack {
  /// Creates a [SessionRigTrack].
  const SessionRigTrack({
    required this.channel,
    required this.pcm,
    required this.volume,
    required this.muted,
  });

  /// Track channel index.
  final int channel;

  /// The track's mono loop PCM (lane 0; multi-lane stems are a follow-up).
  final Float32List pcm;

  /// Playback gain in `0..1`.
  final double volume;

  /// Whether the track is muted.
  final bool muted;
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

  /// Monitor output gain in `0..1`.
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
}
