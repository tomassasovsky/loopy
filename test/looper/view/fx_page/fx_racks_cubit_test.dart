import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/cubit/fx_racks_cubit.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements LooperRepository {}

class _FakeEffects extends Fake implements List<TrackEffect> {}

void main() {
  setUpAll(() {
    registerFallbackValue(<TrackEffect>[]);
    registerFallbackValue(LiveSignalMode.off);
    registerFallbackValue(_FakeEffects());
  });

  group('FxRacksCubit PrePost LiveSignal', () {
    late _MockRepo repo;
    late FxRacksCubit cubit;

    setUp(() {
      repo = _MockRepo();
      when(
        () => repo.setLiveSignalFocus(channel: any(named: 'channel')),
      ).thenReturn(EngineResult.ok);
      when(
        () => repo.setTrackPreEffects(
          channel: any(named: 'channel'),
          effects: any(named: 'effects'),
        ),
      ).thenReturn(EngineResult.ok);
      when(
        () => repo.setTrackPostEffects(
          channel: any(named: 'channel'),
          effects: any(named: 'effects'),
        ),
      ).thenReturn(EngineResult.ok);
      when(
        () => repo.setTrackLiveSignal(
          channel: any(named: 'channel'),
          mode: any(named: 'mode'),
        ),
      ).thenReturn(EngineResult.ok);
      cubit = FxRacksCubit(repository: repo);
    });

    tearDown(() => cubit.close());

    test('happy path Pre delay + Post reverb + Live Signal Auto', () {
      final delay = BuiltInEffect(type: TrackEffectType.delay);
      final reverb = BuiltInEffect(type: TrackEffectType.reverb);

      cubit
        ..selectTrack(0)
        ..setTrackStage(FxStage.pre)
        ..setTrackEffects([delay])
        ..setTrackStage(FxStage.post)
        ..setTrackEffects([reverb])
        ..setLiveSignal(LiveSignalMode.auto);

      verify(() => repo.setLiveSignalFocus(channel: 0)).called(greaterThan(0));
      verify(
        () => repo.setTrackPreEffects(channel: 0, effects: [delay]),
      ).called(1);
      verify(
        () => repo.setTrackPostEffects(channel: 0, effects: [reverb]),
      ).called(1);
      verify(
        () => repo.setTrackLiveSignal(
          channel: 0,
          mode: LiveSignalMode.auto,
        ),
      ).called(1);
    });
  });
}
