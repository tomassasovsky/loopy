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

    group('plugin scan stub', () {
      test('returns no results before a scan begins', () {
        expect(engine.scanResults(), isEmpty);
        expect(engine.scanPoll(), PluginScanProgress.empty);
      });

      test('returns the deterministic fixed list after scanBegin', () {
        expect(engine.scanBegin(), EngineResult.ok);
        final progress = engine.scanPoll();
        expect(progress.done, isTrue);
        expect(progress.found, MockAudioEngine.mockScanResults.length);

        final results = engine.scanResults();
        expect(results, MockAudioEngine.mockScanResults);
        expect(results.where((d) => d.isAvailable).length, 2);
        expect(results.where((d) => !d.isAvailable).length, 1);
      });

      test('cancel clears the started state', () {
        engine.scanBegin();
        expect(engine.scanCancel(), EngineResult.ok);
        expect(engine.scanResults(), isEmpty);
      });
    });

    group('plugin slot stub', () {
      test('setLanePlugin returns a handle carrying the plugin id', () {
        final handle = engine.setLanePlugin(
          channel: 0,
          lane: 1,
          index: 2,
          pluginId: 'com.acme.reverb',
        );
        expect(handle, isA<MockPluginSlotHandle>());
        expect(
          (handle! as MockPluginSlotHandle).pluginId,
          'com.acme.reverb',
        );
      });

      test('setMonitorPlugin returns a handle', () {
        final handle = engine.setMonitorPlugin(
          input: 3,
          index: 0,
          pluginId: 'com.acme.delay',
        );
        expect(handle, isA<MockPluginSlotHandle>());
        expect((handle! as MockPluginSlotHandle).pluginId, 'com.acme.delay');
      });

      test('clear calls return ok', () {
        expect(
          engine.clearLanePlugin(channel: 0, lane: 0, index: 0),
          EngineResult.ok,
        );
        expect(
          engine.clearMonitorPlugin(input: 0, index: 0),
          EngineResult.ok,
        );
      });

      test('enumerates three deterministic automatable params', () {
        final slot = engine.setLanePlugin(
          channel: 0,
          lane: 0,
          index: 0,
          pluginId: 'com.acme.reverb',
        )!;
        final params = engine.pluginParamInfos(slot);
        expect(params, hasLength(3));
        expect(params.map((p) => p.id), [100, 200, 300]);
        expect(params.every((p) => p.isUserVisible), isTrue);
      });

      test('paramGet returns the default until a set, then the new value', () {
        final slot = engine.setMonitorPlugin(
          input: 0,
          index: 0,
          pluginId: 'com.acme.delay',
        )!;
        expect(engine.pluginParamGet(slot, 100), 0.5);
        expect(engine.pluginParamSet(slot, 100, 0.8), EngineResult.ok);
        expect(engine.pluginParamGet(slot, 100), 0.8);
        // A second handle is an independent slot — unaffected by the set above.
        final other = engine.setMonitorPlugin(
          input: 1,
          index: 0,
          pluginId: 'com.acme.delay',
        )!;
        expect(engine.pluginParamGet(other, 100), 0.5);
      });

      test('an unknown param id reports invalid and reads zero', () {
        final slot = engine.setLanePlugin(
          channel: 0,
          lane: 0,
          index: 0,
          pluginId: 'com.acme.reverb',
        )!;
        expect(engine.pluginParamSet(slot, 999, 0.5), EngineResult.invalid);
        expect(engine.pluginParamGet(slot, 999), 0);
      });

      test('paramValueText formats a known param and nulls an unknown', () {
        final slot = engine.setLanePlugin(
          channel: 0,
          lane: 0,
          index: 0,
          pluginId: 'com.acme.reverb',
        )!;
        // Param 100 carries the 'dB' unit; 200 is unitless.
        expect(engine.pluginParamValueText(slot, 100, 0.5), '0.50 dB');
        expect(engine.pluginParamValueText(slot, 200, 0.25), '0.25');
        expect(engine.pluginParamValueText(slot, 999, 0.5), isNull);
      });
    });
  });
}
