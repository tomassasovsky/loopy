import 'package:looper_repository/looper_repository.dart';
import 'package:session_repository/session_repository.dart';

/// Bloc-layer mapping between the session bundle (data) and the looper
/// repository (domain) — the two never depend on each other, so the
/// translation lives here, above both. Shared by `SessionCubit` and the
/// end-to-end round-trip test so the mapping has a single definition.

/// Gathers the live lane + monitor chains from [looper] into the manifest
/// models a save persists. The rig — not settings — is the truth being saved,
/// so chains are read straight from the repository. Chains encode with the same
/// wire format settings use, so a saved chain round-trips exactly.
SessionChains chainsFromLooper(LooperRepository looper) => SessionChains(
  laneChains: [
    for (final entry in looper.allLaneEffects().entries)
      SessionLaneChain(
        channel: entry.key.$1,
        lane: entry.key.$2,
        encoded: encodeTrackEffects(entry.value),
      ),
  ],
  monitors: [
    // Every CONFIGURED monitor, not just inputs carrying an FX chain — a
    // dry-but-enabled monitor must round-trip too, or it would be dropped on
    // save and disabled on the next load.
    for (final monitor in looper.allMonitors().values)
      SessionMonitor(
        input: monitor.input,
        enabled: monitor.enabled,
        outputMask: monitor.outputMask,
        volume: monitor.volume,
        muted: monitor.muted,
        encoded: encodeTrackEffects(monitor.effects),
      ),
  ],
);

/// Maps a decoded session [bundle] into the looper-domain [SessionRig] the
/// looper repository applies, decoding the manifest's opaque chain strings back
/// into effect models. A lane with no decoded audio is dropped; a track left
/// with no lane is dropped whole.
SessionRig rigFromBundle(SessionBundle bundle) => SessionRig(
  baseLengthFrames: bundle.session.baseLengthFrames,
  tracks: _rigTracks(bundle),
  laneEffects: {
    for (final chain in bundle.session.laneChains)
      (chain.channel, chain.lane): decodeTrackEffects(chain.encoded),
  },
  monitors: [
    for (final monitor in bundle.session.monitors)
      SessionRigMonitor(
        input: monitor.input,
        enabled: monitor.enabled,
        outputMask: monitor.outputMask,
        volume: monitor.volume,
        muted: monitor.muted,
        effects: decodeTrackEffects(monitor.encoded),
      ),
  ],
  // Looper mode + crown (schema v4, B5c) — session-level, so read straight
  // off the manifest rather than through `_rigTracks`.
  looperMode: bundle.session.looperMode,
  primaryTrack: bundle.session.primaryTrack,
);

/// Builds the rig's tracks from [bundle], zipping each manifest lane with its
/// decoded PCM. A lane with no decoded audio is dropped; a track left with no
/// lane is dropped whole.
List<SessionRigTrack> _rigTracks(SessionBundle bundle) {
  final tracks = <SessionRigTrack>[];
  for (final track in bundle.session.tracks) {
    final lanes = <SessionRigLane>[];
    for (final lane in track.lanes) {
      final layers = bundle.laneStems[(track.channel, lane.lane)];
      if (layers == null || layers.isEmpty) continue;
      lanes.add(
        SessionRigLane(
          lane: lane.lane,
          layers: layers,
          volume: lane.volume,
          muted: lane.muted,
          outputMask: lane.outputMask,
          inputChannel: lane.inputChannel,
          undoCount: lane.undoCount,
          redoCount: lane.redoCount,
        ),
      );
    }
    if (lanes.isNotEmpty) {
      tracks.add(
        SessionRigTrack(
          channel: track.channel,
          lanes: lanes,
          lengthPresetBars: track.lengthPresetBars,
          oneShot: track.oneShot,
        ),
      );
    }
  }
  return tracks;
}
