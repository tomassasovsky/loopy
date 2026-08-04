import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/common/fx_chain_persistence.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// The ONE Track-stage chain-envelope writer, shared by `LooperBloc` (the
/// on-screen FX dock and keyboard) and `ControlCubit` (the pedal's FX-mode
/// stomps) because a cubit may never call a bloc. Both call sites are covered
/// by their own suites; these pin the contract itself, so a signature or
/// null-guard change cannot pass while both callers still look fine.
void main() {
  group('persistTrackFxChain', () {
    late _MockLooperRepository looper;
    late SettingsRepository settings;

    setUp(() {
      looper = _MockLooperRepository();
      settings = SettingsRepository(store: FakeKeyValueStore());
      when(() => looper.trackChainEnabled(any())).thenReturn(true);
      when(() => looper.trackEffects(any())).thenReturn(const <TrackEffect>[]);
    });

    test('writes the chain-enabled flag and entries as one envelope', () async {
      when(() => looper.trackChainEnabled(2)).thenReturn(false);
      when(
        () => looper.trackEffects(2),
      ).thenReturn([BuiltInEffect(type: TrackEffectType.drive)]);

      persistTrackFxChain(settings: settings, looper: looper, channel: 2);

      final encoded = await settings.loadTrackFxChain(2);
      expect(encoded, isNotNull);
      final envelope = decodeFxChain(encoded);
      expect(envelope.chainEnabled, isFalse);
      expect(envelope.entries, hasLength(1));
    });

    test('round-trips an ENGAGED chain too (the flag is written either way, '
        'so a re-enable is not stored as "never touched")', () async {
      persistTrackFxChain(settings: settings, looper: looper, channel: 0);

      final envelope = decodeFxChain(await settings.loadTrackFxChain(0));
      expect(envelope.chainEnabled, isTrue);
      expect(envelope.entries, isEmpty);
    });

    test(
      'is a no-op when settings is null (the bloc dependency is optional)',
      () async {
        persistTrackFxChain(settings: null, looper: looper, channel: 0);

        // No throw, and nothing read off the repository either — the guard
        // returns before composing the envelope.
        verifyNever(() => looper.trackChainEnabled(any()));
        verifyNever(() => looper.trackEffects(any()));
      },
    );

    test(
      'writes per channel, never bleeding one track chain into another',
      () async {
        when(() => looper.trackChainEnabled(1)).thenReturn(false);

        persistTrackFxChain(settings: settings, looper: looper, channel: 1);

        expect(
          decodeFxChain(await settings.loadTrackFxChain(1)).chainEnabled,
          isFalse,
        );
        expect(await settings.loadTrackFxChain(0), isNull);
      },
    );
  });
}
