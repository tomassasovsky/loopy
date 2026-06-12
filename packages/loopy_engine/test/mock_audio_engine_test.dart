import 'package:flutter_test/flutter_test.dart';
import 'package:loopy_engine/loopy_engine.dart';

void main() {
  group('MockAudioEngine', () {
    late MockAudioEngine engine;

    setUp(() => engine = MockAudioEngine());

    test('defaults to 18 inputs and 20 outputs', () {
      expect(engine.defaultConfig.inputChannels, 18);
      expect(engine.defaultConfig.outputChannels, 20);
      expect(engine.start(engine.defaultConfig), EngineResult.ok);
      final snapshot = engine.snapshot();
      expect(snapshot.inputChannels, 18);
      expect(snapshot.outputChannels, 20);
      expect(snapshot.isRunning, isTrue);
      expect(engine.deviceName, contains('18i20o'));
    });

    test('snapshot reports the WASAPI backend (the only mock path)', () {
      expect(engine.snapshot().activeBackend, AudioBackend.wasapi);
      engine.start(engine.defaultConfig);
      expect(engine.snapshot().activeBackend, AudioBackend.wasapi);
    });

    test('enumerates a duplex mock device', () {
      final devices = engine.enumerateDevices();
      expect(devices, hasLength(2));
      expect(
        devices.map((d) => d.id).toSet(),
        equals({MockAudioEngine.deviceId}),
      );
      // The mock does not probe per-device channel counts, so they read 0
      // (unknown) — matching the native WASAPI enumeration path.
      for (final device in devices) {
        expect(device.inputChannels, 0);
        expect(device.outputChannels, 0);
      }
    });

    test('reflects lane routing in snapshots', () {
      engine
        ..start(engine.defaultConfig)
        ..setLaneInput(channel: 0, lane: 0, inputChannel: 5)
        ..setLaneOutput(channel: 0, lane: 0, mask: 0x40);

      final lane = engine.snapshot().tracks[0].lanes.first;
      expect(lane.inputChannel, 5);
      expect(lane.outputMask, 0x40);
    });
  });
}
