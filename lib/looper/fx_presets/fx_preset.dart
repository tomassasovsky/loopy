import 'package:looper_repository/looper_repository.dart';

/// One built-in effect entry inside an [FxPreset].
class FxPresetEffect {
  /// Creates an [FxPresetEffect].
  const FxPresetEffect({required this.type, this.params = const []});

  /// Builds from a JSON map.
  factory FxPresetEffect.fromJson(Map<String, dynamic> json) => FxPresetEffect(
    type: json['type'] as String? ?? 'drive',
    params: [
      for (final p in (json['params'] as List<dynamic>? ?? const []))
        (p as num).toDouble(),
    ],
  );

  /// Built-in effect type name (`delay`, `reverb`, …).
  final String type;

  /// Normalized params (`0..1`).
  final List<double> params;

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => {'type': type, 'params': params};
}

/// A factory or user FX rack preset (built-ins only).
class FxPreset {
  /// Creates an [FxPreset].
  const FxPreset({
    required this.id,
    required this.name,
    required this.category,
    required this.effects,
    this.suggestedStage = 'post',
  });

  /// Builds from a JSON map.
  factory FxPreset.fromJson(Map<String, dynamic> json) => FxPreset(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    category: json['category'] as String? ?? '',
    suggestedStage: json['suggestedStage'] as String? ?? 'post',
    effects: [
      for (final e in (json['effects'] as List<dynamic>? ?? const []))
        FxPresetEffect.fromJson(e as Map<String, dynamic>),
    ],
  );

  /// Stable id.
  final String id;

  /// Display name.
  final String name;

  /// Category (Vocal, Guitar, Dub, …).
  final String category;

  /// Suggested Pre/Post stage (`pre` / `post`).
  final String suggestedStage;

  /// Ordered built-in effects.
  final List<FxPresetEffect> effects;

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'category': category,
    'suggestedStage': suggestedStage,
    'effects': [for (final e in effects) e.toJson()],
  };

  /// Converts to domain [TrackEffect] list (clamped to [kTrackEffectMax]).
  List<TrackEffect> toEffects() {
    final out = <TrackEffect>[];
    for (final entry in effects) {
      if (out.length >= kTrackEffectMax) break;
      final type = _typeFromName(entry.type);
      if (type == null) continue;
      final params = List<double>.filled(kTrackEffectParams, 0.5);
      for (var i = 0; i < entry.params.length && i < params.length; i++) {
        params[i] = entry.params[i].clamp(0.0, 1.0);
      }
      out.add(BuiltInEffect(type: type, params: params));
    }
    return out;
  }

  static TrackEffectType? _typeFromName(String name) {
    for (final t in TrackEffectType.values) {
      if (t.name == name) return t;
    }
    return null;
  }
}
