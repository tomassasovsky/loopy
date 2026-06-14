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

    test('snapshot echoes the requested backend (no fallback in the mock)', () {
      // Stopped, or started on miniaudio, the negotiated backend is miniaudio.
      expect(engine.snapshot().activeBackend, AudioBackend.miniaudio);
      engine.start(engine.defaultConfig);
      expect(engine.snapshot().activeBackend, AudioBackend.miniaudio);
      // Started on ASIO, the mock "succeeds" and reports ASIO as negotiated —
      // the requested-ASIO/reality-miniaudio fallback is never exercised here.
      engine
        ..stop()
        ..start(
          const EngineConfig(
            backend: AudioBackend.asio,
            asioDriver: 'mock-asio',
          ),
        );
      expect(engine.snapshot().activeBackend, AudioBackend.asio);
    });

    test('enumerates one duplex ASIO driver with probed channel counts', () {
      final drivers = engine.enumerateAsioDrivers();
      expect(drivers, hasLength(1));
      final driver = drivers.single;
      // An ASIO driver is one duplex device (never split by direction), so it
      // is tagged isInput: false and carries the counts the picker shows.
      expect(driver.isInput, isFalse);
      expect(driver.inputChannels, 18);
      expect(driver.outputChannels, 20);
      // It also carries the driver's selectable buffer sizes / sample rates.
      expect(driver.bufferSizes, [128, 256, 512]);
      expect(driver.sampleRates, [48000, 96000]);
    });

    test('enumerates a duplex mock device', () {
      final devices = engine.enumerateDevices();
      expect(devices, hasLength(2));
      expect(
        devices.map((d) => d.id).toSet(),
        equals({MockAudioEngine.deviceId}),
      );
      // The mock does not probe per-device channel counts, so they read 0
      // (unknown) — matching the native miniaudio enumeration path.
      for (final device in devices) {
        expect(device.inputChannels, 0);
        expect(device.outputChannels, 0);
      }
    });

    test(
      'master gain defaults to unity, clamps, and surfaces in the snapshot',
      () {
        engine.start(engine.defaultConfig);
        expect(engine.snapshot().masterGain, 1);

        expect(engine.setMasterGain(0.25), EngineResult.ok);
        expect(engine.snapshot().masterGain, closeTo(0.25, 1e-6));

        // Out-of-range values clamp to 0..1, mirroring the native engine.
        engine.setMasterGain(-1);
        expect(engine.snapshot().masterGain, 0);
        engine.setMasterGain(2);
        expect(engine.snapshot().masterGain, 1);
      },
    );

    test('a fresh start resets the master gain to unity', () {
      engine
        ..start(engine.defaultConfig)
        ..setMasterGain(0.5)
        ..stop()
        ..start(engine.defaultConfig);
      expect(engine.snapshot().masterGain, 1);
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
