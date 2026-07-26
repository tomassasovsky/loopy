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
SessionChains chainsFromLooper(LooperRepository looper) {
  final trackPosts = looper.allTrackPostEffects();
  final trackPres = looper.allTrackPreEffects();
  final liveSignals = looper.allTrackLiveSignal();
  final channels = {
    ...trackPosts.keys,
    ...trackPres.keys,
    ...liveSignals.keys,
  };
  return SessionChains(
    laneChains: [
      for (final entry in looper.allLaneEffects().entries)
        SessionLaneChain(
          channel: entry.key.$1,
          lane: entry.key.$2,
          encoded: encodeTrackEffects(entry.value),
        ),
    ],
    trackRacks: [
      for (final channel in channels.toList()..sort())
        SessionTrackRack(
          channel: channel,
          preEncoded: encodeTrackEffects(trackPres[channel] ?? const []),
          postEncoded: encodeTrackEffects(trackPosts[channel] ?? const []),
          liveSignal: (liveSignals[channel] ?? LiveSignalMode.off).name,
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
          encoded: encodeTrackEffects(monitor.postEffects),
          preEncoded: encodeTrackEffects(monitor.preEffects),
        ),
    ],
  );
}

/// Maps a decoded session [bundle] into the looper-domain [SessionRig] the
/// looper repository applies, decoding the manifest's opaque chain strings back
/// into effect models. A lane with no decoded audio is dropped; a track left
/// with no lane is dropped whole.
///
/// Schema v4→v5: Input `encoded` → Input Post; lane chains → Track Post (lane 0
/// wins when lanes disagree). Explicit [Session.trackRacks] win when present.
SessionRig rigFromBundle(SessionBundle bundle) {
  final trackPost = <int, List<TrackEffect>>{};
  final trackPre = <int, List<TrackEffect>>{};
  final trackLive = <int, LiveSignalMode>{};

  if (bundle.session.trackRacks.isNotEmpty) {
    for (final rack in bundle.session.trackRacks) {
      trackPre[rack.channel] = decodeTrackEffects(rack.preEncoded);
      trackPost[rack.channel] = decodeTrackEffects(rack.postEncoded);
      trackLive[rack.channel] = _liveSignalFromName(rack.liveSignal);
    }
  } else {
    // v4 migration: lane 0 wins per channel for Track Post.
    final byChannel = <int, List<TrackEffect>>{};
    for (final chain in bundle.session.laneChains) {
      if (chain.lane != 0 && byChannel.containsKey(chain.channel)) continue;
      if (chain.lane == 0 || !byChannel.containsKey(chain.channel)) {
        byChannel[chain.channel] = decodeTrackEffects(chain.encoded);
      }
    }
    trackPost.addAll(byChannel);
  }

  return SessionRig(
    baseLengthFrames: bundle.session.baseLengthFrames,
    tracks: _rigTracks(bundle),
    laneEffects: {
      for (final chain in bundle.session.laneChains)
        (chain.channel, chain.lane): decodeTrackEffects(chain.encoded),
    },
    trackPreEffects: trackPre,
    trackPostEffects: trackPost,
    trackLiveSignal: trackLive,
    monitors: [
      for (final monitor in bundle.session.monitors)
        SessionRigMonitor(
          input: monitor.input,
          enabled: monitor.enabled,
          outputMask: monitor.outputMask,
          volume: monitor.volume,
          muted: monitor.muted,
          preEffects: decodeTrackEffects(monitor.preEncoded),
          effects: decodeTrackEffects(monitor.encoded),
        ),
    ],
    // Looper mode + crown (schema v4, B5c) — session-level, so read straight
    // off the manifest rather than through `_rigTracks`.
    looperMode: bundle.session.looperMode,
    primaryTrack: bundle.session.primaryTrack,
    // One Shot (post-B5c independent review fix) — also session-level and read
    // straight off the manifest, so a channel armed with no content (and thus
    // no `_rigTracks` entry) still restores; see `SessionRig.oneShotChannels`'s
    // doc.
    oneShotChannels: bundle.session.oneShotChannels.toSet(),
  );
}

LiveSignalMode _liveSignalFromName(String name) {
  for (final mode in LiveSignalMode.values) {
    if (mode.name == name) return mode;
  }
  return LiveSignalMode.off;
}

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
