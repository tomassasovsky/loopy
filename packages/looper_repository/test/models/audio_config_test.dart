// Tests the engine <-> domain boundary mappers directly, so the src file is
// imported (the mappers are package-internal, not exported from the barrel).
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/src/models/audio_config.dart';
import 'package:loopy_engine/loopy_engine.dart' as le;

void main() {
  group('AudioBackend', () {
    test('round-trips through the engine enum for every value', () {
      for (final backend in AudioBackend.values) {
        expect(audioBackendFromEngine(audioBackendToEngine(backend)), backend);
      }
    });

    test('covers every engine backend value', () {
      for (final engineBackend in le.AudioBackend.values) {
        // Mapping engine -> domain -> engine is identity (no value dropped).
        final domain = audioBackendFromEngine(engineBackend);
        expect(audioBackendToEngine(domain), engineBackend);
      }
    });
  });

  group('enum mirrors cover every engine value (by name)', () {
    test('LatencyState', () {
      for (final state in le.LatencyState.values) {
        expect(latencyStateFromEngine(state).name, state.name);
      }
    });

    test('LoopbackKind', () {
      for (final kind in le.LoopbackKind.values) {
        expect(loopbackKindFromEngine(kind).name, kind.name);
      }
    });
  });

  test('audioDeviceFromEngine preserves every field', () {
    const engineDevice = le.AudioDevice(
      id: 'asio-1',
      name: 'Focusrite USB ASIO',
      isDefault: true,
      isInput: false,
      inputChannels: 18,
      outputChannels: 20,
      bufferSizes: [128, 256],
      sampleRates: [44100, 48000, 96000],
    );

    expect(
      audioDeviceFromEngine(engineDevice),
      const AudioDevice(
        id: 'asio-1',
        name: 'Focusrite USB ASIO',
        isDefault: true,
        isInput: false,
        inputChannels: 18,
        outputChannels: 20,
        bufferSizes: [128, 256],
        sampleRates: [44100, 48000, 96000],
      ),
    );
  });

  test('loopbackInfoFromEngine preserves fields + isAutoRoutable', () {
    const engineInfo = le.LoopbackInfo(
      available: true,
      kind: le.LoopbackKind.monitor,
      deviceName: 'Monitor of Built-in',
    );

    final domain = loopbackInfoFromEngine(engineInfo);

    expect(domain.available, isTrue);
    expect(domain.kind, LoopbackKind.monitor);
    expect(domain.deviceName, 'Monitor of Built-in');
    expect(domain.isAutoRoutable, isTrue);
  });

  group('LoopbackInfo', () {
    test('none() is an empty, non-routable result', () {
      const info = LoopbackInfo.none();
      expect(info.available, isFalse);
      expect(info.kind, LoopbackKind.none);
      expect(info.deviceName, '');
      expect(info.isAutoRoutable, isFalse);
    });

    test('value equality is by props', () {
      expect(
        const LoopbackInfo(
          available: true,
          kind: LoopbackKind.monitor,
          deviceName: 'x',
        ),
        const LoopbackInfo(
          available: true,
          kind: LoopbackKind.monitor,
          deviceName: 'x',
        ),
      );
      expect(
        const LoopbackInfo.none(),
        isNot(
          const LoopbackInfo(
            available: true,
            kind: LoopbackKind.monitor,
            deviceName: 'x',
          ),
        ),
      );
    });
  });

  test('engineConfigToEngine maps each field to the engine struct '
      '(distinct per-field values catch any transposition)', () {
    const config = EngineConfig(
      sampleRate: 48000,
      bufferFrames: 128,
      playbackDeviceId: 'pb',
      captureDeviceId: 'cap',
      backend: AudioBackend.asio,
      asioDriver: 'Driver',
      useLoopbackCapture: true,
      maxLoopFrames: 99,
      inputChannels: 2,
      outputChannels: 6,
    );

    final engineConfig = engineConfigToEngine(config);

    expect(engineConfig.sampleRate, 48000);
    expect(engineConfig.bufferFrames, 128);
    expect(engineConfig.playbackDeviceId, 'pb');
    expect(engineConfig.captureDeviceId, 'cap');
    expect(engineConfig.backend, le.AudioBackend.asio);
    expect(engineConfig.asioDriver, 'Driver');
    expect(engineConfig.useLoopbackCapture, isTrue);
    expect(engineConfig.maxLoopFrames, 99);
    expect(engineConfig.inputChannels, 2);
    expect(engineConfig.outputChannels, 6);
  });
}
