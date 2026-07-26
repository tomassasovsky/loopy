import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/fx_presets/fx_preset.dart';

void main() {
  group('FxRack preset FxPreset', () {
    test('factory rack toEffects round-trips types + params', () {
      const preset = FxPreset(
        id: 't',
        name: 'Test',
        category: 'Vocal',
        suggestedStage: 'pre',
        effects: [
          FxPresetEffect(type: 'delay', params: [0.25, 0.5, 0.75]),
          FxPresetEffect(type: 'reverb', params: [0.1, 0.2, 0.3]),
        ],
      );
      final effects = preset.toEffects();
      expect(effects, hasLength(2));
      expect((effects[0] as BuiltInEffect).type, TrackEffectType.delay);
      expect((effects[0] as BuiltInEffect).params[0], 0.25);
      expect((effects[1] as BuiltInEffect).type, TrackEffectType.reverb);
    });

    test('user preset JSON round-trips', () {
      const preset = FxPreset(
        id: 'user_1',
        name: 'Mine',
        category: 'User',
        effects: [
          FxPresetEffect(type: 'drive', params: [0.6]),
        ],
      );
      final again = FxPreset.fromJson(preset.toJson());
      expect(again.id, 'user_1');
      expect(again.effects.single.type, 'drive');
      expect(again.toEffects().single, isA<BuiltInEffect>());
    });
  });
}
