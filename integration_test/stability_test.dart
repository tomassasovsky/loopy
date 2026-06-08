// Silent device-stability check.
//
// Opens the engine and holds it for 8 s WITHOUT monitoring or the latency pulse
// (no audible output, no feedback risk), verifying the device never drops and
// the audio callback keeps advancing frames. Answers "does the engine reboot
// itself while running?" without making any noise.
import 'dart:developer';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:loopy_engine/loopy_engine.dart';

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('engine stays running for 8s', () async {
    final engine = NativeAudioEngine();

    final result = engine.start(
      const EngineConfig(
        sampleRate: 48000,
        bufferFrames: 128,
        channels: 2,
      ),
    );
    log('start -> ${result.name}, device "${engine.deviceName}"');
    expect(result, EngineResult.ok);

    var drops = 0;
    var stalls = 0;
    var lastFrames = 0;
    for (var i = 0; i < 16; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final s = engine.snapshot();
      final advanced = s.framesProcessed - lastFrames;
      lastFrames = s.framesProcessed;
      if (!s.isRunning) drops++;
      if (i > 0 && advanced <= 0) stalls++;
      log(
        't=${(i + 1) * 500}ms running=${s.isRunning} '
        '+${advanced}frames xruns=${s.xrunCount}',
      );
    }

    engine
      ..stop()
      ..dispose();

    log('=== drops=$drops stalls=$stalls ===');
    expect(drops, 0, reason: 'device must not drop while running');
    expect(stalls, 0, reason: 'audio callback must keep advancing frames');
  });
}
