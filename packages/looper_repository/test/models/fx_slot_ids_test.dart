import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

void main() {
  group('SlotIds', () {
    test('mints unique ids within a session', () {
      final minted = {for (var i = 0; i < 1000; i++) SlotIds.mint()};
      expect(minted, hasLength(1000));
    });

    test('a new session prefix never reuses a prior session id', () {
      final before = {for (var i = 0; i < 100; i++) SlotIds.mint()};
      SlotIds.resetForTesting(); // a "new session"
      final after = {for (var i = 0; i < 100; i++) SlotIds.mint()};
      expect(before.intersection(after), isEmpty);
    });
  });

  group('withMintedSlotIds', () {
    test('mints only for id-less entries, preserving existing ids', () {
      final chain = [
        BuiltInEffect(type: TrackEffectType.drive, slotId: 'keep-me'),
        BuiltInEffect(type: TrackEffectType.delay),
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.clap, id: 'p'),
        ),
      ];

      final minted = withMintedSlotIds(chain);

      expect(minted[0].slotId, 'keep-me');
      expect(minted[1].slotId, isNotNull);
      expect(minted[2].slotId, isNotNull);
      expect(minted[1].slotId, isNot(minted[2].slotId));
      // Everything else is untouched.
      expect((minted[1] as BuiltInEffect).type, TrackEffectType.delay);
      expect((minted[2] as PluginEffect).ref.id, 'p');
    });

    test('is a no-op on a fully-minted chain (mint exactly once)', () {
      final once = withMintedSlotIds([
        BuiltInEffect(type: TrackEffectType.drive),
      ]);
      final twice = withMintedSlotIds(once);
      expect(twice, once);
    });
  });

  group('withFreshSlotIds', () {
    test('replaces every id — inheritance copies are new identities (A9)', () {
      final source = withMintedSlotIds([
        BuiltInEffect(type: TrackEffectType.drive),
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.clap, id: 'p'),
        ),
      ]);

      final copy = withFreshSlotIds(source);

      for (var i = 0; i < source.length; i++) {
        expect(copy[i].slotId, isNotNull);
        expect(copy[i].slotId, isNot(source[i].slotId));
      }
    });
  });
}
