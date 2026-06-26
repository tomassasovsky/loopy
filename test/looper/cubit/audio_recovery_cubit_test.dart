import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/looper.dart';
import 'package:mocktail/mocktail.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

LooperState _state({required bool connected}) =>
    LooperState(status: EngineStatus(isConnected: connected));

const _config = EngineConfig(playbackDeviceId: 'out-1');
const _device = AudioDevice(
  id: 'out-1',
  name: 'Scarlett',
  isDefault: false,
  isInput: false,
);

const _captureConfig = EngineConfig(captureDeviceId: 'in-1');
const _inputDevice = AudioDevice(
  id: 'in-1',
  name: 'Mic',
  isDefault: false,
  isInput: true,
);

void main() {
  setUpAll(() => registerFallbackValue(const EngineConfig()));

  group('AudioRecoveryCubit', () {
    late _MockLooperRepository looper;
    late StreamController<void> ticker;

    setUp(() {
      looper = _MockLooperRepository();
      ticker = StreamController<void>.broadcast();
      when(() => looper.state).thenReturn(_state(connected: false));
      when(looper.devices).thenReturn(const []);
      when(() => looper.startEngine(any())).thenReturn(EngineResult.ok);
    });

    tearDown(() => ticker.close());

    Future<AudioRecoveryCubit> build({EngineConfig? config = _config}) async {
      final cubit = AudioRecoveryCubit(
        looper: looper,
        recoveryConfig: config,
        ticker: ticker.stream,
      );
      addTearDown(cubit.close);
      await cubit.load();
      return cubit;
    }

    group('inert', () {
      test('does nothing when there is no recovery config', () async {
        final cubit = await build(config: null);
        expect(cubit.state.status, AudioRecoveryStatus.idle);
        verifyNever(looper.devices);
        verifyNever(() => looper.startEngine(any()));
      });

      test('does nothing for a system-default (unpinned) config', () async {
        final cubit = await build(config: const EngineConfig());
        expect(cubit.state.status, AudioRecoveryStatus.idle);
        verifyNever(() => looper.startEngine(any()));
      });

      test('goes idle when the engine is already running', () async {
        when(() => looper.state).thenReturn(_state(connected: true));
        final cubit = await build();
        expect(cubit.state.status, AudioRecoveryStatus.idle);
        verifyNever(() => looper.startEngine(any()));
      });
    });

    group('waiting + auto-start', () {
      test('waits when the pinned device is absent', () async {
        final cubit = await build();
        expect(cubit.state.status, AudioRecoveryStatus.waitingForDevice);
        verifyNever(() => looper.startEngine(any()));
      });

      test('auto-starts the engine when the device appears', () async {
        final cubit = await build();
        expect(cubit.state.status, AudioRecoveryStatus.waitingForDevice);

        when(looper.devices).thenReturn(const [_device]);
        ticker.add(null);
        await pumpEventQueue();

        verify(() => looper.startEngine(_config)).called(1);
      });

      test('does not re-start while the device stays present', () async {
        final cubit = await build();
        when(looper.devices).thenReturn(const [_device]);

        ticker.add(null);
        await pumpEventQueue();
        ticker.add(null); // still present, no absent->present edge
        await pumpEventQueue();

        verify(() => looper.startEngine(_config)).called(1);
        expect(cubit.state.status, AudioRecoveryStatus.waitingForDevice);
      });

      test('auto-starts when the device is present at load', () async {
        when(looper.devices).thenReturn(const [_device]);
        await build();
        verify(() => looper.startEngine(_config)).called(1);
      });

      test('recovers a capture-only pinned device', () async {
        final cubit = await build(config: _captureConfig);
        expect(cubit.state.status, AudioRecoveryStatus.waitingForDevice);

        when(looper.devices).thenReturn(const [_inputDevice]);
        ticker.add(null);
        await pumpEventQueue();

        verify(() => looper.startEngine(_captureConfig)).called(1);
      });

      test('does not thrash when a present device cannot be opened', () async {
        when(() => looper.startEngine(any())).thenReturn(EngineResult.device);
        when(looper.devices).thenReturn(const [_device]);
        await build(); // present at load -> one attempt

        ticker.add(null); // still present, start still failing -> no retry
        await pumpEventQueue();

        verify(() => looper.startEngine(_config)).called(1);
      });
    });

    group('defers to the in-repo supervisor once connected', () {
      test('goes idle and stops attempting after a connect', () async {
        final cubit = await build();
        when(looper.devices).thenReturn(const [_device]);
        ticker.add(null); // attempts the start
        await pumpEventQueue();

        // The engine is now running; the recovery cubit must back off.
        when(() => looper.state).thenReturn(_state(connected: true));
        ticker.add(null);
        await pumpEventQueue();
        expect(cubit.state.status, AudioRecoveryStatus.idle);

        // A later transient loss is the supervisor's job, not ours.
        clearInteractions(looper);
        when(() => looper.state).thenReturn(_state(connected: false));
        ticker.add(null);
        await pumpEventQueue();
        verifyNever(() => looper.startEngine(any()));
      });
    });
  });
}
