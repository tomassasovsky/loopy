import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/update/cubit/pedal_firmware_cubit.dart';
import 'package:update_repository/update_repository.dart';

class _FakeBackend implements PlatformUpdateBackend {
  _FakeBackend({this.supported = true, this.pending, this.flashError});

  final bool supported;
  final String? pending;
  final Object? flashError;

  int pendingCalls = 0;
  int flashCalls = 0;
  final controller = StreamController<double>();

  @override
  bool get isSupported => supported;

  @override
  Future<String?> pendingPedalFirmware() async {
    pendingCalls++;
    return pending;
  }

  @override
  Stream<double> flashPedalFirmware() {
    flashCalls++;
    if (flashError != null) return Stream.error(flashError!);
    return controller.stream;
  }

  @override
  String get channel => 'experimental';

  @override
  Future<void> setChannel(String channel) async {}

  @override
  Future<Version> currentVersion() async => Version.none;

  @override
  Future<Version> stagedVersion() async => Version.none;

  @override
  Future<UpdateManifest?> fetchManifest() async => null;

  @override
  Stream<double> downloadAndStage(UpdateManifest manifest) =>
      const Stream.empty();

  @override
  Future<void> applyAndRestart() async {}
}

void main() {
  group('PedalFirmwareCubit', () {
    test('goes idle without asking when updates are unsupported', () async {
      // Desktop and dev runs must not pay a process launch, and must never
      // draw the gate.
      final backend = _FakeBackend(supported: false, pending: '0.4.0');
      final cubit = PedalFirmwareCubit(
        updates: UpdateRepository(backend: backend),
      );
      addTearDown(cubit.close);

      await cubit.run();

      expect(cubit.state.stage, PedalFirmwareStage.idle);
      expect(cubit.state.blocksLooper, isFalse);
      expect(backend.pendingCalls, 0);
    });

    test('goes idle when nothing is pending', () async {
      final backend = _FakeBackend();
      final cubit = PedalFirmwareCubit(
        updates: UpdateRepository(backend: backend),
      );
      addTearDown(cubit.close);

      await cubit.run();

      expect(cubit.state.stage, PedalFirmwareStage.idle);
      expect(backend.flashCalls, 0);
    });

    test(
      'blocks the looper for the whole flash and releases it after',
      () async {
        final backend = _FakeBackend(pending: '0.4.0');
        final cubit = PedalFirmwareCubit(
          updates: UpdateRepository(backend: backend),
        );
        addTearDown(cubit.close);

        final done = cubit.run();
        await pumpEventQueue();

        // The gate must be up before the first byte is written, not after the
        // first progress line: the touch reset happens immediately, and that is
        // the moment the footswitches go dead.
        expect(cubit.state.stage, PedalFirmwareStage.flashing);
        expect(cubit.state.blocksLooper, isTrue);
        expect(cubit.state.version, '0.4.0');
        expect(cubit.state.progress, 0);

        backend.controller.add(0.5);
        await pumpEventQueue();
        expect(cubit.state.progress, 0.5);
        expect(cubit.state.blocksLooper, isTrue);

        await backend.controller.close();
        await done;

        expect(cubit.state.stage, PedalFirmwareStage.idle);
        expect(cubit.state.blocksLooper, isFalse);
      },
    );

    test('a failed flash is reported but not fatal', () async {
      final backend = _FakeBackend(
        pending: '0.4.0',
        flashError: Exception('avrdude failed'),
      );
      final cubit = PedalFirmwareCubit(
        updates: UpdateRepository(backend: backend),
      );
      addTearDown(cubit.close);

      await cubit.run();

      expect(cubit.state.stage, PedalFirmwareStage.failed);
      expect(cubit.state.error, contains('avrdude failed'));
      // Still blocking: the user is told, rather than dropped into a looper
      // whose pedal just stopped responding.
      expect(cubit.state.blocksLooper, isTrue);

      cubit.dismiss();

      expect(cubit.state.blocksLooper, isFalse);
    });

    test('a flash still running when the cubit closes emits nothing', () async {
      // The window is real: closing a window during the flash disposes the
      // provider while avrdude is mid-write.
      final backend = _FakeBackend(pending: '0.4.0');
      final cubit = PedalFirmwareCubit(
        updates: UpdateRepository(backend: backend),
      );

      final done = cubit.run();
      await pumpEventQueue();
      await cubit.close();

      backend.controller.add(0.7);
      await backend.controller.close();

      await expectLater(done, completes);
    });
  });
}
