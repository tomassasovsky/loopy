import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/looper.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late SettingsRepository settings;
  late LooperRepository repository;

  setUpAll(() {
    registerFallbackValue(GridDivision.off);
    registerFallbackValue(ClickMode.off);
  });

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
    for (final stub in <void Function()>[
      () => when(() => repository.setTempo(any())).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setTimeSignature(any(), any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setSyncTempo(on: any(named: 'on')),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setQuantizeDiv(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickMode(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickOutput(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickVolume(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setCountIn(any()),
      ).thenReturn(EngineResult.ok),
      () => when(repository.tapTempo).thenReturn(EngineResult.ok),
    ]) {
      stub();
    }
  });

  group('TempoCubit', () {
    test('defaults to the tempo-free grid-off state', () {
      final cubit = TempoCubit(repository: repository, settings: settings);
      expect(cubit.state, const TempoSettings());
    });

    blocTest<TempoCubit, TempoSettings>(
      'load restores the persisted settings and applies every one of them '
      'to the repository',
      setUp: () async {
        await settings.saveTempoBpm(140);
        await settings.saveTimeSignature(7, 8);
        await settings.saveSyncTempo(value: false);
        await settings.saveQuantizeDiv(GridDivision.quarter.code);
        await settings.saveClickMode(ClickMode.playRec.code);
        await settings.saveClickOutputMask(0x3);
        await settings.saveClickVolume(0.5);
        await settings.saveCountInBars(2);
      },
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.load(),
      expect: () => [
        const TempoSettings(
          bpm: 140,
          tsNum: 7,
          tsDen: 8,
          syncTempo: false,
          quantizeDiv: GridDivision.quarter,
          clickMode: ClickMode.playRec,
          clickOutputMask: 0x3,
          clickVolume: 0.5,
          countInBars: 2,
        ),
      ],
      verify: (_) {
        verify(() => repository.setTempo(140)).called(1);
        verify(() => repository.setTimeSignature(7, 8)).called(1);
        verify(() => repository.setSyncTempo(on: false)).called(1);
        verify(
          () => repository.setQuantizeDiv(GridDivision.quarter),
        ).called(1);
        verify(() => repository.setClickMode(ClickMode.playRec)).called(1);
        verify(() => repository.setClickOutput(0x3)).called(1);
        verify(() => repository.setClickVolume(0.5)).called(1);
        verify(() => repository.setCountIn(2)).called(1);
      },
    );

    blocTest<TempoCubit, TempoSettings>(
      'load with an unset (0) tempo does not push it to the engine',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.load(),
      verify: (_) => verifyNever(() => repository.setTempo(any())),
    );

    blocTest<TempoCubit, TempoSettings>(
      'load is single-flight — a second call restores nothing new',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) async {
        await cubit.load();
        await cubit.load();
      },
      verify: (_) => verify(
        () => repository.setTimeSignature(any(), any()),
      ).called(1),
    );

    blocTest<TempoCubit, TempoSettings>(
      'setTempo emits, persists, and applies the new value',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setTempo(96),
      expect: () => [const TempoSettings(bpm: 96)],
      verify: (_) async {
        expect(await settings.loadTempoBpm(), 96);
        verify(() => repository.setTempo(96)).called(1);
      },
    );

    blocTest<TempoCubit, TempoSettings>(
      'setTempo to the same value as the cache still calls the repository '
      '(no stale-cache-based early return)',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setTempo(0),
      verify: (_) => verify(() => repository.setTempo(0)).called(1),
    );

    blocTest<TempoCubit, TempoSettings>(
      'a setter still calls the repository when its target value matches '
      "the cubit's cache but a bypass writer moved the LIVE state away from "
      'it in between (regression: pedal-toggle no-op bug)',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) async {
        // The cache now holds ClickMode.rec.
        await cubit.setClickMode(ClickMode.rec);
        clearInteractions(repository);
        // A bypass writer (e.g. LooperBloc._toggleMetronome, a pedal press)
        // moves the LIVE engine's click mode directly through the
        // repository — the real pedal path never touches this cubit, so
        // its cache still (wrongly) reads `rec`.
        repository.setClickMode(ClickMode.off);
        // The user opens Settings — which reads the LIVE TransportState,
        // not this stale cache (see TempoSettingsSection's class doc) —
        // sees "Off" and taps "Recording" to restore it. That target value
        // (`rec`) matches the cubit's stale cache exactly, so the old
        // guard (`newValue != state.field`) would have silently skipped
        // the repository call here.
        await cubit.setClickMode(ClickMode.rec);
      },
      verify: (_) =>
          verify(() => repository.setClickMode(ClickMode.rec)).called(1),
    );

    blocTest<TempoCubit, TempoSettings>(
      'setTimeSignature emits, persists, and applies the new signature',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setTimeSignature(5, 8),
      expect: () => [const TempoSettings(tsNum: 5, tsDen: 8)],
      verify: (_) async {
        expect(await settings.loadTimeSignature(), (5, 8));
        verify(() => repository.setTimeSignature(5, 8)).called(1);
      },
    );

    blocTest<TempoCubit, TempoSettings>(
      'setSyncTempo emits, persists, and applies the new value',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setSyncTempo(value: false),
      expect: () => [const TempoSettings(syncTempo: false)],
      verify: (_) async {
        expect(await settings.loadSyncTempo(), isFalse);
        verify(() => repository.setSyncTempo(on: false)).called(1);
      },
    );

    blocTest<TempoCubit, TempoSettings>(
      'setQuantizeDiv emits, persists, and applies the new granularity',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setQuantizeDiv(GridDivision.bar),
      expect: () => [const TempoSettings(quantizeDiv: GridDivision.bar)],
      verify: (_) async {
        expect(await settings.loadQuantizeDiv(), GridDivision.bar.code);
        verify(() => repository.setQuantizeDiv(GridDivision.bar)).called(1);
      },
    );

    blocTest<TempoCubit, TempoSettings>(
      'setClickMode emits, persists, and applies the new mode',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setClickMode(ClickMode.rec),
      expect: () => [const TempoSettings(clickMode: ClickMode.rec)],
      verify: (_) async {
        expect(await settings.loadClickMode(), ClickMode.rec.code);
        verify(() => repository.setClickMode(ClickMode.rec)).called(1);
      },
    );

    blocTest<TempoCubit, TempoSettings>(
      'setClickOutput emits, persists, and applies the new mask',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setClickOutput(0x1),
      expect: () => [const TempoSettings(clickOutputMask: 0x1)],
      verify: (_) async {
        expect(await settings.loadClickOutputMask(), 0x1);
        verify(() => repository.setClickOutput(0x1)).called(1);
      },
    );

    blocTest<TempoCubit, TempoSettings>(
      'setClickVolume emits, persists, and applies the new volume',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setClickVolume(0.75),
      expect: () => [const TempoSettings(clickVolume: 0.75)],
      verify: (_) async {
        expect(await settings.loadClickVolume(), 0.75);
        verify(() => repository.setClickVolume(0.75)).called(1);
      },
    );

    blocTest<TempoCubit, TempoSettings>(
      'setCountInBars emits, persists, and applies the new count-in',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setCountInBars(2),
      expect: () => [const TempoSettings(countInBars: 2)],
      verify: (_) async {
        expect(await settings.loadCountInBars(), 2);
        verify(() => repository.setCountIn(2)).called(1);
      },
    );

    blocTest<TempoCubit, TempoSettings>(
      'setCountInBars clamps a negative value to 0',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setCountInBars(-3),
      verify: (_) async {
        expect(await settings.loadCountInBars(), 0);
        verify(() => repository.setCountIn(0)).called(1);
      },
    );

    test('tapTempo forwards to the repository and is never persisted', () {
      final cubit = TempoCubit(repository: repository, settings: settings);

      final result = cubit.tapTempo();

      expect(result, EngineResult.ok);
      verify(repository.tapTempo).called(1);
    });
  });

  test(
    'kValidTimeSignatures has exactly the 17 Sheeran-verified signatures',
    () {
      expect(kValidTimeSignatures, hasLength(17));
      expect(
        kValidTimeSignatures.where((ts) => ts.$2 == 4).map((ts) => ts.$1),
        [2, 3, 4, 5, 6, 7],
      );
      expect(
        kValidTimeSignatures.where((ts) => ts.$2 == 8).map((ts) => ts.$1),
        [5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
      );
    },
  );
}
