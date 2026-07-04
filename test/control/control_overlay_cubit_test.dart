import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/looper/model/looper_mode.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_key_value_store.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  group('ControlOverlayCubit', () {
    late _MockLooperRepository looper;
    late StreamController<LooperState> looperStates;
    late ControlOverlay overlay;
    late ControlIntents intents;

    setUp(() {
      looper = _MockLooperRepository();
      looperStates = StreamController<LooperState>.broadcast(sync: true);
      when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
      overlay = ControlOverlay(looper: looper);
      intents = ControlIntents(
        looper: looper,
        overlay: overlay,
        settings: SettingsRepository(store: FakeKeyValueStore()),
      );
    });

    tearDown(() async {
      await overlay.dispose();
      await looperStates.close();
    });

    test('starts at the store state and mirrors every change', () async {
      overlay.selectTrack(5); // pre-existing state is picked up...
      final cubit = ControlOverlayCubit(overlay: overlay, intents: intents);
      expect(cubit.state.cursor, 5);

      overlay.applyMode(LooperMode.play, parkedResume: const {0});
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.mode, LooperMode.play);
      expect(cubit.state.parkedResume, {0});
      await cubit.close();
    });

    test('close stops mirroring without touching the store', () async {
      final cubit = ControlOverlayCubit(overlay: overlay, intents: intents);
      await cubit.close();
      overlay.selectTrack(3);
      expect(cubit.state.cursor, 0); // mirror frozen
      expect(overlay.state.cursor, 3); // store unaffected
    });
  });
}
