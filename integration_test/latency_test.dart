// Real-hardware loopback latency diagnostic.
//
// Drives the *native* engine on the macOS audio device (no fakes) and prints
// what the audio thread actually sees: device name, negotiated format, live
// input/output levels, and the latency-harness result. Run with a physical
// loopback connected (headphone output -> line input 1):
//
//   /Users/Tomas/development/flutter/bin/flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/latency_test.dart \
//     -d macos --dart-define=loopy.flavor=development
//
// This is a diagnostic, not a CI gate: it logs generously and only hard-fails
// if the engine cannot open the device at all.
import 'dart:developer';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:loopy_engine/loopy_engine.dart';

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('loopback latency on real hardware', () async {
    final engine = NativeAudioEngine();
    log('engine version: ${engine.version}');

    final result = engine.start(
      const EngineConfig(
        sampleRate: 48000,
        bufferFrames: 128,
        inputChannels: 2,
        outputChannels: 2,
      ),
    );
    log('start -> ${result.name}');
    expect(result, EngineResult.ok, reason: 'engine must open the device');

    // Let the device settle, then report what miniaudio actually negotiated.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final opened = engine.snapshot();
    log('device: "${engine.deviceName}"');
    log(
      'negotiated: ${opened.sampleRate} Hz, '
      '${opened.bufferFrames} frames, '
      '${opened.inputChannels} in / ${opened.outputChannels} out',
    );

    // --- Step 1: ambient input level (informational) ---
    // A line-input loopback only carries what we send out, so with the track
    // empty and passthrough off this is expected to read ~0. It's logged purely
    // to spot a stuck/noisy input; the real proof that capture is live is the
    // pulse echo in step 2. (If capture were dead — e.g. missing mic
    // entitlement — step 2's inPeak would also stay at 0 and we'd time out.)
    var maxInPeak = 0.0;
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      maxInPeak = engine.snapshot().inputPeak.clamp(maxInPeak, 1.0);
    }
    log(
      'ambient input peak over 500ms: ${maxInPeak.toStringAsFixed(4)} '
      '(≈0 is expected for a silent loopback)',
    );

    // --- Step 2: run the latency harness ---
    final m = engine.measureLatency();
    log('measureLatency -> ${m.name}');

    var lastState = LatencyState.idle;
    var measured = -1.0;
    for (var i = 0; i < 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      final s = engine.snapshot();
      if (s.latencyState != lastState) {
        lastState = s.latencyState;
        log(
          '  state -> ${s.latencyState.name} '
          '(inPeak=${s.inputPeak.toStringAsFixed(3)})',
        );
      }
      if (s.latencyState == LatencyState.done) {
        measured = s.measuredLatencyMs;
        break;
      }
      if (s.latencyState == LatencyState.timeout) break;
    }

    log(
      '=== RESULT: $lastState'
      '${measured >= 0 ? ' ${measured.toStringAsFixed(2)} ms' : ''} ===',
    );

    engine
      ..stop()
      ..dispose();

    expect(
      lastState,
      LatencyState.done,
      reason:
          'loopback pulse must be detected (check the physical loop and '
          'that the engine opened the loopback device)',
    );
    expect(measured, greaterThan(0), reason: 'a real round-trip is > 0 ms');
  });
}
