import 'package:looper_repository/looper_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:session_repository/session_repository.dart';

/// Bloc-layer mapping between the session bundle (data) and the looper
/// repository (domain) — the two never depend on each other, so the
/// translation lives here, above both. Shared by `SessionCubit` and the
/// end-to-end round-trip test so the mapping has a single definition.
///
/// This is also where the FX chain ENVELOPE (R13/R15) crosses the boundary:
/// `looper_repository` owns the codec, `session_repository` only ever sees the
/// resulting opaque string, so the encode/decode calls all live here.

/// Gathers the live chains of all four FX stages from [looper] into the
/// manifest models a save persists. The rig — not settings — is the truth being
/// saved, so chains are read straight from the repository. Chains encode with
/// the same envelope format settings use, so a saved chain round-trips exactly:
/// entries, per-slot enabled bits, stable slot ids, the chain-enabled flag, and
/// (for the Loop stage) inheritance provenance.
SessionChains chainsFromLooper(LooperRepository looper) => SessionChains(
  laneChains: [
    for (final entry in looper.allLaneChains().entries)
      SessionLaneChain(
        channel: entry.key.$1,
        lane: entry.key.$2,
        encoded: encodeFxChain(entry.value),
      ),
  ],
  monitors: [
    // Every CONFIGURED monitor, not just inputs carrying an FX chain — a
    // dry-but-enabled monitor must round-trip too, or it would be dropped on
    // save and disabled on the next load.
    for (final monitor in looper.allMonitors().values)
      SessionMonitor(
        input: monitor.input,
        enabled: monitor.mode != MonitorMode.off,
        outputMask: monitor.outputMask,
        volume: monitor.volume,
        muted: monitor.muted,
        encoded: encodeFxChain(
          FxChainEnvelope(
            chainEnabled: monitor.chainEnabled,
            entries: monitor.effects,
          ),
        ),
      ),
  ],
  // The two bus stages (manifest v5). Both go through the same envelope codec
  // as the stages above; the Master insert is a single chain, so it persists as
  // one string rather than a keyed list.
  trackChains: [
    for (final entry in looper.allTrackChains().entries)
      SessionTrackChain(
        channel: entry.key,
        encoded: encodeFxChain(entry.value),
      ),
  ],
  masterChain: _encodedMasterChain(looper),
);

/// The Master insert as an envelope string, or the manifest's own "no chain"
/// spelling (`''`) when the rig has no Master state at all — so a default rig
/// does not persist a redundant envelope, and the manifest has ONE way to say
/// "empty". Both spellings decode to the same empty enabled envelope, and both
/// reset a leftover Master chain on load.
String _encodedMasterChain(LooperRepository looper) {
  final master = looper.masterChainEnvelope();
  return master == const FxChainEnvelope() ? '' : encodeFxChain(master);
}

/// Gathers the same live four-stage chains into the models a
/// performance-capture arm snapshot records, plus the master-limiter state the
/// engine snapshot cannot read back. The rig — not settings — is the truth
/// being captured, exactly as in [chainsFromLooper]; the manifest keeps effects
/// structured (canonical JSON `daw_export` reads directly) rather than encoded,
/// so the chains cross the boundary as engine models — with each stage's
/// chain-enabled flag alongside, since a bypassed chain must replay bypassed
/// (R3).
PerformanceChains performanceChainsFromLooper(LooperRepository looper) {
  // One read path for the Master stage, the same accessor [chainsFromLooper]
  // uses — two ways to read one piece of state at one boundary would be free
  // to drift.
  final master = looper.masterChainEnvelope();
  return PerformanceChains(
    laneChains: [
      for (final entry in looper.allLaneChains().entries)
        PerformanceLaneChain(
          channel: entry.key.$1,
          lane: entry.key.$2,
          effects: trackEffectsToEngine(entry.value.entries),
          chainEnabled: entry.value.chainEnabled,
        ),
    ],
    monitors: [
      // Every CONFIGURED monitor, not just inputs carrying an FX chain —
      // same rule as [chainsFromLooper]: a dry-but-enabled monitor is part of
      // the rig the capture is documenting.
      for (final monitor in looper.allMonitors().values)
        PerformanceMonitorState(
          input: monitor.input,
          enabled: monitor.mode != MonitorMode.off,
          outputMask: monitor.outputMask,
          volume: monitor.volume,
          muted: monitor.muted,
          effects: trackEffectsToEngine(monitor.effects),
          chainEnabled: monitor.chainEnabled,
        ),
    ],
    trackChains: [
      for (final entry in looper.allTrackChains().entries)
        PerformanceTrackChain(
          channel: entry.key,
          effects: trackEffectsToEngine(entry.value.entries),
          chainEnabled: entry.value.chainEnabled,
        ),
    ],
    masterEffects: trackEffectsToEngine(master.entries),
    masterChainEnabled: master.chainEnabled,
    limiterEnabled: looper.limiterEnabled,
    limiterCeiling: looper.limiterCeiling,
  );
}

/// Maps a decoded session [bundle] into the looper-domain [SessionRig] the
/// looper repository applies, decoding the manifest's opaque chain strings back
/// into effect models. A lane with no decoded audio is dropped; a track left
/// with no lane is dropped whole.
SessionRig rigFromBundle(SessionBundle bundle) => SessionRig(
  baseLengthFrames: bundle.session.baseLengthFrames,
  tracks: _rigTracks(bundle),
  // Envelope-aware decode (R15): a v5+ manifest carries the chain envelope in
  // the opaque string; a v4-or-earlier bare-array chain decodes with every
  // level defaulted to enabled. The whole envelope reaches the rig — the flag
  // and the provenance marker restore with the entries, and any stage the
  // manifest does NOT describe is reset on apply, never inherited (R17).
  laneChains: {
    for (final chain in bundle.session.laneChains)
      (chain.channel, chain.lane): decodeFxChain(chain.encoded),
  },
  monitors: [
    for (final monitor in bundle.session.monitors)
      _rigMonitor(monitor, decodeFxChain(monitor.encoded)),
  ],
  // The bus stages (manifest v5). A v4-or-earlier bundle carries neither, so
  // both arrive empty — and `applySession` resets whatever the live rig had.
  trackChains: {
    for (final chain in bundle.session.trackChains)
      chain.channel: decodeFxChain(chain.encoded),
  },
  masterChain: decodeFxChain(bundle.session.masterChain),
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

/// Projects one manifest monitor + its decoded chain into the rig's Input-stage
/// model. The monitor carries routing/mix of its own, so the envelope is
/// flattened onto it rather than nested (see [SessionRig]'s doc).
SessionRigMonitor _rigMonitor(SessionMonitor monitor, FxChainEnvelope chain) =>
    SessionRigMonitor(
      input: monitor.input,
      // The manifest's monitor gate is still a boolean, so a saved session
      // restores `on` or `off` and never `auto`. Flattening happens HERE, at
      // the format boundary, so widening the manifest later is a change to
      // this line and nothing behind it. Tracked as its own issue.
      mode: monitor.enabled ? MonitorMode.on : MonitorMode.off,
      outputMask: monitor.outputMask,
      volume: monitor.volume,
      muted: monitor.muted,
      effects: chain.entries,
      chainEnabled: chain.chainEnabled,
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
