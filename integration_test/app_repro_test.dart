// Reproduces the app's exact engine condition during a latency measurement:
// passthrough ON (monitorInput default), then watch whether the device drops or
// the callback stalls across measureLatency() — i.e. the "USB resets on
// Measure" report. Logs isRunning + frame advance every 50 ms through the
// measurement.
import 'dart:developer';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:loopy_engine/loopy_engine.dart';

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('measure latency with passthrough on (app condition)', () async {
    final engine = NativeAudioEngine();

    final r = engine.start(
      const EngineConfig(
        sampleRate: 48000,
        bufferFrames: 128,
        inputChannels: 2,
        outputChannels: 2,
        passthrough: true, // <-- matches the app default (monitorInput: true)
      ),
    );
    log('start -> ${r.name}, device "${engine.deviceName}"');
    expect(r, EngineResult.ok);

    await Future<void>.delayed(const Duration(seconds: 1));
    var last = engine.snapshot().framesProcessed;
    log(
      'pre-measure framesProcessed=$last '
      'running=${engine.snapshot().isRunning}',
    );

    engine.measureLatency();
    log('--- measureLatency posted ---');

    var drops = 0;
    var stalls = 0;
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final s = engine.snapshot();
      final adv = s.framesProcessed - last;
      last = s.framesProcessed;
      if (!s.isRunning) drops++;
      if (adv <= 0) stalls++;
      if (!s.isRunning ||
          adv <= 0 ||
          s.latencyState != LatencyState.measuring) {
        log(
          't=${(i + 1) * 50}ms running=${s.isRunning} +${adv}f '
          'lat=${s.latencyState.name} inPeak=${s.inputPeak.toStringAsFixed(3)}',
        );
      }
    }
    final fin = engine.snapshot();
    log(
      '=== final lat=${fin.latencyState.name} '
      '${fin.measuredLatencyMs.toStringAsFixed(2)}ms '
      'drops=$drops stalls=$stalls ===',
    );

    engine
      ..stop()
      ..dispose();
  });
}
