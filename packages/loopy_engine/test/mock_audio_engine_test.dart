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

    test(
      'setLaneVolume clamps to LE_MAX_GAIN (2.0), not 0..1, mirroring the '
      'native engine',
      () {
        engine.start(engine.defaultConfig);

        // A boost above unity is not clamped down to 1.0 — the native engine
        // allows up to LE_MAX_GAIN (+6 dB headroom), and the mock must match.
        expect(engine.setLaneVolume(1.5), EngineResult.ok);
        expect(engine.snapshot().tracks[0].volume, closeTo(1.5, 1e-6));

        // Out-of-range values clamp to 0..LE_MAX_GAIN, not 0..1.
        expect(engine.setLaneVolume(2.5), EngineResult.ok);
        expect(engine.snapshot().tracks[0].volume, closeTo(2, 1e-6));
        expect(engine.setLaneVolume(-1), EngineResult.ok);
        expect(engine.snapshot().tracks[0].volume, 0);

        // The explicit (channel, lane) addressing path behaves identically.
        expect(engine.setLaneVolume(1.5, channel: 2), EngineResult.ok);
        expect(
          engine.snapshot().tracks[2].lanes[0].volume,
          closeTo(1.5, 1e-6),
        );
      },
    );

    group('performance recording capture', () {
      test('requires the engine to be running', () {
        expect(engine.perfArm('test-capture'), EngineResult.notRunning);
      });

      test('rejects an empty capture directory', () {
        engine.start(engine.defaultConfig);
        expect(engine.perfArm(''), EngineResult.invalid);
        expect(engine.snapshot().isPerfArmed, isFalse);
      });

      test('arms, disarms, and is idempotent both ways', () {
        engine.start(engine.defaultConfig);
        expect(engine.snapshot().isPerfArmed, isFalse);

        expect(engine.perfArm('test-capture'), EngineResult.ok);
        expect(engine.snapshot().isPerfArmed, isTrue);
        expect(
          engine.perfArm('test-capture'),
          EngineResult.ok,
        ); // already armed: no-op

        expect(engine.perfDisarm(), EngineResult.ok);
        expect(engine.snapshot().isPerfArmed, isFalse);
        expect(engine.perfDisarm(), EngineResult.ok); // already disarmed: no-op
      });

      test('perfFrames advances while armed and stays 0 when disarmed', () {
        engine.start(engine.defaultConfig);
        expect(engine.snapshot().perfFrames, 0);

        engine
          ..perfArm('test-capture')
          ..snapshot(); // advances frames by one buffer
        expect(engine.snapshot().perfFrames, greaterThan(0));

        engine.perfDisarm();
        final frozen = engine.snapshot().perfFrames;
        engine.snapshot();
        expect(engine.snapshot().perfFrames, frozen); // no longer advancing
      });

      test('the mock models no ring capacity: overruns stay 0', () {
        engine
          ..start(engine.defaultConfig)
          ..perfArm('test-capture');
        for (var i = 0; i < 5; i++) {
          engine.snapshot();
        }
        expect(engine.snapshot().perfOverruns, 0);
      });

      test('a fresh start disarms and resets frames', () {
        engine
          ..start(engine.defaultConfig)
          ..perfArm('test-capture')
          ..snapshot()
          ..stop()
          ..start(engine.defaultConfig);
        final snapshot = engine.snapshot();
        expect(snapshot.isPerfArmed, isFalse);
        expect(snapshot.perfFrames, 0);
      });
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

    group('TempoControl', () {
      test('every setter requires the engine to be running', () {
        expect(engine.setTempo(120), EngineResult.notRunning);
        expect(engine.setTimeSignature(4, 4), EngineResult.notRunning);
        expect(engine.tapTempo(), EngineResult.notRunning);
        expect(engine.setSyncTempo(on: false), EngineResult.notRunning);
        expect(
          engine.setQuantizeDiv(GridDivision.bar),
          EngineResult.notRunning,
        );
        expect(
          engine.setClickMode(ClickMode.rec),
          EngineResult.notRunning,
        );
        expect(engine.setClickOutput(0x3), EngineResult.notRunning);
        expect(engine.setClickVolume(0.5), EngineResult.notRunning);
        expect(engine.setCountIn(2), EngineResult.notRunning);
        expect(
          engine.setTrackLengthPreset(channel: 0, bars: 4),
          EngineResult.notRunning,
        );
      });

      test('snapshot defaults to the grid-off state', () {
        engine.start(engine.defaultConfig);
        final s = engine.snapshot();
        expect(s.tempoBpm, 0);
        expect(s.tempoSource, TempoSource.none);
        expect(s.tsNum, 4);
        expect(s.tsDen, 4);
        expect(s.syncTempo, isTrue);
        expect(s.quantizeDiv, GridDivision.off);
        expect(s.clickMode, ClickMode.off);
        expect(s.clickMask, 0);
        expect(s.clickVolume, 1);
        expect(s.countInBars, 0);
      });

      test('setTempo sets the value, source, and clamps to 30..300', () {
        engine.start(engine.defaultConfig);
        expect(engine.setTempo(140), EngineResult.ok);
        var s = engine.snapshot();
        expect(s.tempoBpm, closeTo(140, 1e-6));
        expect(s.tempoSource, TempoSource.manual);

        engine.setTempo(10);
        s = engine.snapshot();
        expect(s.tempoBpm, 30);

        engine.setTempo(1000);
        s = engine.snapshot();
        expect(s.tempoBpm, 300);
      });

      test(
        'setTimeSignature accepts a valid signature and rejects an '
        'invalid one',
        () {
          engine.start(engine.defaultConfig);
          expect(engine.setTimeSignature(7, 4), EngineResult.ok);
          var s = engine.snapshot();
          expect(s.tsNum, 7);
          expect(s.tsDen, 4);

          expect(engine.setTimeSignature(15, 8), EngineResult.ok);
          s = engine.snapshot();
          expect(s.tsNum, 15);
          expect(s.tsDen, 8);

          // 2/8 and 8/4 are not among the 17 Sheeran-verified signatures.
          expect(engine.setTimeSignature(2, 8), EngineResult.invalid);
          expect(engine.setTimeSignature(8, 4), EngineResult.invalid);
          // A rejected signature does not change the published state.
          expect(engine.snapshot().tsNum, 15);
          expect(engine.snapshot().tsDen, 8);
        },
      );

      test('tapTempo ignores a lone first tap', () {
        engine.start(engine.defaultConfig);
        expect(engine.tapTempo(), EngineResult.ok);
        final s = engine.snapshot();
        expect(s.tempoBpm, 0);
        expect(s.tempoSource, TempoSource.none);
      });

      test('two taps within the 30..300 BPM window set the tempo', () async {
        engine
          ..start(engine.defaultConfig)
          ..tapTempo();
        // ~120 BPM: a 500 ms tap interval (bpm in 30..300 needs an interval
        // in 200..2000 ms).
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(engine.tapTempo(), EngineResult.ok);
        final s = engine.snapshot();
        expect(s.tempoSource, TempoSource.tapped);
        expect(s.tempoBpm, greaterThan(0));
      });

      test('a fresh start clears the pending tap pair', () async {
        engine
          ..start(engine.defaultConfig)
          ..tapTempo()
          ..stop()
          ..start(engine.defaultConfig);
        // The pending first tap from before the restart must not pair with
        // this one (mirrors engine.c resetting has_tap on every configure).
        expect(engine.tapTempo(), EngineResult.ok);
        expect(engine.snapshot().tempoSource, TempoSource.none);
      });

      test('setSyncTempo toggles and surfaces in the snapshot', () {
        engine.start(engine.defaultConfig);
        expect(engine.snapshot().syncTempo, isTrue);
        expect(engine.setSyncTempo(on: false), EngineResult.ok);
        expect(engine.snapshot().syncTempo, isFalse);
      });

      test('setQuantizeDiv surfaces in the snapshot', () {
        engine.start(engine.defaultConfig);
        expect(
          engine.setQuantizeDiv(GridDivision.eighth),
          EngineResult.ok,
        );
        expect(engine.snapshot().quantizeDiv, GridDivision.eighth);
      });

      test('setClickMode surfaces in the snapshot', () {
        engine.start(engine.defaultConfig);
        expect(
          engine.setClickMode(ClickMode.playRec),
          EngineResult.ok,
        );
        expect(engine.snapshot().clickMode, ClickMode.playRec);
      });

      test('setClickOutput surfaces in the snapshot', () {
        engine.start(engine.defaultConfig);
        expect(engine.setClickOutput(0x6), EngineResult.ok);
        expect(engine.snapshot().clickMask, 0x6);
      });

      test(
        'setClickVolume clamps to LE_MAX_GAIN (2.0), not 0..1, mirroring '
        'the native engine',
        () {
          engine.start(engine.defaultConfig);
          expect(engine.setClickVolume(1.5), EngineResult.ok);
          expect(engine.snapshot().clickVolume, closeTo(1.5, 1e-6));

          engine.setClickVolume(2.5);
          expect(engine.snapshot().clickVolume, closeTo(2, 1e-6));
          engine.setClickVolume(-1);
          expect(engine.snapshot().clickVolume, 0);
        },
      );

      test('setCountIn accepts 0..LE_COUNT_IN_MAX_BARS and rejects beyond', () {
        engine.start(engine.defaultConfig);
        expect(engine.setCountIn(2), EngineResult.ok);
        expect(engine.snapshot().countInBars, 2);

        expect(engine.setCountIn(0), EngineResult.ok);
        expect(engine.snapshot().countInBars, 0);

        expect(engine.setCountIn(-1), EngineResult.invalid);
        expect(engine.setCountIn(65), EngineResult.invalid);
        // A rejected value does not change the published state.
        expect(engine.snapshot().countInBars, 0);
      });

      test(
        'setTrackLengthPreset accepts 0..LE_LENGTH_PRESET_MAX_BARS and '
        'rejects beyond',
        () {
          engine.start(engine.defaultConfig);
          expect(
            engine.setTrackLengthPreset(channel: 0, bars: 4),
            EngineResult.ok,
          );
          expect(engine.snapshot().tracks[0].lengthPresetBars, 4);

          expect(
            engine.setTrackLengthPreset(channel: 0, bars: 0),
            EngineResult.ok,
          );
          expect(engine.snapshot().tracks[0].lengthPresetBars, 0);

          expect(
            engine.setTrackLengthPreset(channel: 0, bars: -1),
            EngineResult.invalid,
          );
          expect(
            engine.setTrackLengthPreset(channel: 0, bars: 65),
            EngineResult.invalid,
          );
          // A rejected value does not change the published state.
          expect(engine.snapshot().tracks[0].lengthPresetBars, 0);
        },
      );

      test('setTrackLengthPreset is per-track', () {
        engine
          ..start(engine.defaultConfig)
          ..setTrackLengthPreset(channel: 0, bars: 4)
          ..setTrackLengthPreset(channel: 1, bars: 8);
        final tracks = engine.snapshot().tracks;
        expect(tracks[0].lengthPresetBars, 4);
        expect(tracks[1].lengthPresetBars, 8);
        expect(tracks[2].lengthPresetBars, 0);
      });

      test('tempo grid settings persist across stop/start', () {
        engine
          ..start(engine.defaultConfig)
          ..setTempo(150)
          ..setClickMode(ClickMode.rec)
          ..setCountIn(2)
          ..stop()
          ..start(engine.defaultConfig);
        final s = engine.snapshot();
        // Unlike masterGain (reset to unity on every fresh start), the tempo
        // grid + click settings are SEEDED ONCE and persist across
        // start/stop — mirrors engine.c:552-571.
        expect(s.tempoBpm, closeTo(150, 1e-6));
        expect(s.clickMode, ClickMode.rec);
        expect(s.countInBars, 2);
      });
    });

    group('LooperModeControl', () {
      test('setLooperMode requires the engine to be running', () {
        expect(
          engine.setLooperMode(LooperMode.sync),
          EngineResult.notRunning,
        );
      });

      test('snapshot defaults to multi', () {
        engine.start(engine.defaultConfig);
        expect(engine.snapshot().looperMode, LooperMode.multi);
      });

      test('setLooperMode surfaces in the snapshot', () {
        engine.start(engine.defaultConfig);
        expect(engine.setLooperMode(LooperMode.band), EngineResult.ok);
        expect(engine.snapshot().looperMode, LooperMode.band);
      });

      test('looper mode persists across stop/start', () {
        // Seeded once (mirrors the tempo grid settings), not reset to the
        // default on every fresh start.
        engine
          ..start(engine.defaultConfig)
          ..setLooperMode(LooperMode.free)
          ..stop()
          ..start(engine.defaultConfig);
        expect(engine.snapshot().looperMode, LooperMode.free);
      });
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

    test('exportTrackLane returns an empty list (mock models no PCM)', () {
      expect(engine.exportTrackLane(0, 0), isEmpty);
    });
  });
}
