@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/session/session_mapping.dart';
import 'package:loopy_engine/loopy_engine.dart'
    show FxFingerprint, PumpedNativeEngine;
import 'package:session_repository/session_repository.dart';

/// End-to-end FX-in-session round-trip against the REAL native engine
/// (device-free pump): record a take, stage lane + monitor chains, SAVE, clear
/// the rig, LOAD, and assert the chains / volumes / mutes are restored AND the
/// engine's published chains match the repository cache (fingerprint-verified).
/// This is acceptance criterion #1 of the FX-state-robustness plan.
///
/// Self-skips when `LOOPY_ENGINE_LIB` is unset:
///   export LOOPY_ENGINE_LIB="$(bash packages/loopy_engine/tool/build_test_lib.sh)"
void main() {
  final lib = Platform.environment['LOOPY_ENGINE_LIB'];
  final skip = lib == null || lib.isEmpty
      ? 'LOOPY_ENGINE_LIB not set — run packages/loopy_engine/tool/build_test_lib.sh'
      : null;

  late PumpedNativeEngine engine;
  late LooperRepository looper;
  late SessionRepository session;
  late Directory tempDir;
  Timer? pumpDriver;

  setUp(() {
    engine = PumpedNativeEngine();
    looper = LooperRepository(engine: engine)
      ..startEngine(
        const EngineConfig(
          sampleRate: 48000,
          inputChannels: 2,
          outputChannels: 1,
          maxLoopFrames: 48000,
        ),
      );
    session = SessionRepository(engine: engine);
    tempDir = Directory.systemTemp.createTempSync('loopy_fx_session');
    // The pump engine only advances (and drains ring commands) when pumped;
    // a background driver lets the repositories' async clear/settle waits make
    // progress the way a live audio device would.
    pumpDriver = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => engine.pump(frames: 0),
    );
  });

  tearDown(() async {
    pumpDriver?.cancel();
    await looper.dispose();
    tempDir.deleteSync(recursive: true);
  });

  // Save-capture and load-apply go through the SAME bloc-layer mapping the
  // SessionCubit uses (session_mapping.dart), so this exercises the real
  // translation — only the engine pumping is bespoke to the device-free test.

  test('a session with lane + monitor chains round-trips, engine and cache '
      'agree after load', () async {
    // Record a 256-frame take on track 0.
    looper.record();
    engine.pump(frames: 256, input: 0.5);
    looper.record(); // finalize -> playing
    engine.pump(frames: 0);

    // Stage a lane chain + mix, and a monitor chain.
    looper
      ..setLaneEffects(
        channel: 0,
        lane: 0,
        effects: [
          BuiltInEffect(
            type: TrackEffectType.delay,
            params: const [0.3, 0.4, 0.5, 0],
          ),
          BuiltInEffect(type: TrackEffectType.reverb),
        ],
      )
      ..setLaneVolume(0.6, channel: 0, lane: 0)
      ..setLaneMute(muted: true, channel: 0, lane: 0)
      ..setMonitorEffects(
        input: 0,
        effects: [BuiltInEffect(type: TrackEffectType.filter)],
      )
      // A DRY monitor: enabled + routed, NO FX chain. It carries no entry in
      // the effects map, so it was historically dropped on save (the bug) —
      // assert it survives the round-trip.
      ..setMonitorInputEnabled(input: 1, enabled: true)
      ..setMonitorOutput(input: 1, mask: 0x1);
    engine.pump(frames: 0);

    final dir = '${tempDir.path}/take';
    final saved = await session.save(dir, chains: chainsFromLooper(looper));
    expect(saved.laneChains, isNotEmpty);
    // BOTH monitors are captured: the FX chain on input 0 AND the dry monitor
    // on input 1 (the regression would have saved only input 0).
    expect(saved.monitors.map((m) => m.input).toSet(), {0, 1});

    // Wipe the rig to something DIFFERENT, so a failed load would show.
    await looper.applySession(
      const SessionRig(),
      clearPollInterval: const Duration(milliseconds: 1),
    );
    engine.pump(frames: 0);
    expect(looper.laneEffects(0, 0), isEmpty);
    expect(looper.monitorEffects(0), isEmpty);
    expect(looper.monitorEnabled(1), isFalse); // dry monitor cleared too

    // Load the saved bundle back through the one apply path.
    final bundle = await session.read(dir);
    await looper.applySession(
      rigFromBundle(bundle),
      clearPollInterval: const Duration(milliseconds: 1),
    );
    engine.pump(frames: 0);

    // Chains, volume, and mute are restored.
    final lane = looper.laneEffects(0, 0);
    expect(lane, hasLength(2));
    expect((lane[0] as BuiltInEffect).type, TrackEffectType.delay);
    expect((lane[1] as BuiltInEffect).type, TrackEffectType.reverb);
    expect(looper.state.tracks[0].lanes[0].volume, closeTo(0.6, 1e-6));
    expect(looper.state.tracks[0].lanes[0].muted, isTrue);
    expect(
      (looper.monitorEffects(0).single as BuiltInEffect).type,
      TrackEffectType.filter,
    );
    // The dry monitor is restored: enabled + routed, still no FX — the fix for
    // "some inputs stop monitoring after a session change".
    expect(looper.monitorEnabled(1), isTrue);
    expect(looper.monitorOutput(1), 0x1);
    expect(looper.monitorEffects(1), isEmpty);

    // Engine and cache agree — no leftover, no drift (fingerprint-verified).
    expect(
      looper.laneChainFingerprint(0, 0),
      engine.laneFxFingerprint(channel: 0, lane: 0),
    );
    expect(
      looper.monitorChainFingerprint(0),
      engine.monitorFxFingerprint(input: 0),
    );
  }, skip: skip);

  test('loading a v1-style session (no chains) explicitly clears leftovers, '
      'not resurrects them', () async {
    // Stage a lane chain, then load a chain-less session over it: the leftover
    // must be cleared on BOTH sides (F2c), not left sounding.
    looper.setLaneEffects(
      channel: 0,
      lane: 0,
      effects: [BuiltInEffect(type: TrackEffectType.drive)],
    );
    engine.pump(frames: 0);

    await looper.applySession(
      const SessionRig(), // a v1 bundle decodes to an empty rig
      clearPollInterval: const Duration(milliseconds: 1),
    );
    engine.pump(frames: 0);

    expect(looper.laneEffects(0, 0), isEmpty);
    expect(
      looper.laneChainFingerprint(0, 0),
      engine.laneFxFingerprint(channel: 0, lane: 0),
    );
    expect(engine.laneFxFingerprint(channel: 0, lane: 0), FxFingerprint.offset);
  }, skip: skip);
}
