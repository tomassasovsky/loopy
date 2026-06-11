import 'dart:convert';

import 'package:meta/meta.dart';

/// The maximum number of effects a single track's chain can hold. The cap
/// exists only so the audio thread reads a fixed-size, allocation-free array —
/// it is far beyond musical need, not a CPU limit. Mirrors the native
/// `LE_FX_MAX`.
const int kTrackEffectMax = 8;

/// The number of normalized (`0..1`) parameters each effect exposes. Mirrors
/// the native `LE_FX_PARAMS`.
const int kTrackEffectParams = 3;

/// A built-in effect type. The integer [code] matches the native
/// `le_fx_type` enum, and each type interprets its [kTrackEffectParams]
/// normalized parameters differently (see [paramLabels]).
enum TrackEffectType {
  /// The entry is bypassed.
  none(0, 'None'),

  /// Soft-clipping overdrive.
  drive(1, 'Drive'),

  /// Resonant low-pass filter.
  filter(2, 'Filter'),

  /// Feedback delay.
  delay(3, 'Delay'),

  /// Sine-LFO amplitude modulation.
  tremolo(4, 'Tremolo');

  const TrackEffectType(this.code, this.label);

  /// The native `le_fx_type` integer.
  final int code;

  /// A short human-readable name for menus.
  final String label;

  /// Maps a native `le_fx_type` integer back to a [TrackEffectType]; unknown
  /// values fall back to [TrackEffectType.none].
  static TrackEffectType fromCode(int code) =>
      values.firstWhere((t) => t.code == code, orElse: () => none);

  /// Labels for this type's parameters, in order. The list length is the number
  /// of parameters the type actually uses (`<=` [kTrackEffectParams]); trailing
  /// unused parameters are omitted.
  List<String> get paramLabels => switch (this) {
    TrackEffectType.none => const [],
    TrackEffectType.drive => const ['Drive', 'Level'],
    TrackEffectType.filter => const ['Cutoff', 'Resonance'],
    TrackEffectType.delay => const ['Time', 'Feedback', 'Mix'],
    TrackEffectType.tremolo => const ['Rate', 'Depth'],
  };

  /// The musical default for each of the [kTrackEffectParams] parameters when
  /// the type is freshly engaged. Mirrors the engine's `le_fx_default_params`
  /// so the UI sliders match what the engine seeds.
  List<double> get defaultParams => switch (this) {
    TrackEffectType.none => const [0, 0, 0],
    TrackEffectType.drive => const [0.5, 0.8, 0],
    TrackEffectType.filter => const [0.5, 0.2, 0],
    TrackEffectType.delay => const [0.35, 0.35, 0.35],
    TrackEffectType.tremolo => const [0.3, 0.7, 0],
  };
}

/// One entry in an effects chain: a [type] with its [params] (normalized
/// `0..1`, length [kTrackEffectParams]).
///
/// The chain is non-destructive and stageless — the recording is always dry and
/// every active entry colors playback in order. The same model backs a lane's
/// record-route chain and a hardware input's live-monitor chain.
@immutable
class TrackEffect {
  /// Creates a [TrackEffect]. [params] defaults to the [type]'s musical
  /// defaults.
  TrackEffect({required this.type, List<double>? params})
    : params = List<double>.unmodifiable(params ?? type.defaultParams);

  /// Rebuilds a [TrackEffect] from [toJson] output; unknown codes fall back to
  /// safe defaults. A legacy `stage` key (from the removed pre/post model) is
  /// ignored, so older persisted chains still decode.
  factory TrackEffect.fromJson(Map<String, dynamic> json) {
    final rawParams = json['params'];
    final params = rawParams is List
        ? [for (final v in rawParams) (v as num).toDouble()]
        : null;
    return TrackEffect(
      type: TrackEffectType.fromCode((json['type'] as num?)?.toInt() ?? 0),
      params: params,
    );
  }

  /// The effect type.
  final TrackEffectType type;

  /// The normalized parameter values (length [kTrackEffectParams]).
  final List<double> params;

  /// Returns a copy with the given fields replaced. [params] is copied.
  TrackEffect copyWith({TrackEffectType? type, List<double>? params}) =>
      TrackEffect(type: type ?? this.type, params: params ?? this.params);

  /// A JSON-friendly map for persistence (codes, not enum names).
  Map<String, dynamic> toJson() => {'type': type.code, 'params': params};

  @override
  bool operator ==(Object other) =>
      other is TrackEffect &&
      other.type == type &&
      _listEquals(other.params, params);

  @override
  int get hashCode => Object.hash(type, Object.hashAll(params));

  static bool _listEquals(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Encodes an ordered effects chain to a JSON string for persistence.
String encodeTrackEffects(List<TrackEffect> effects) =>
    jsonEncode([for (final e in effects) e.toJson()]);

/// Decodes a chain produced by [encodeTrackEffects]; malformed input yields an
/// empty chain.
List<TrackEffect> decodeTrackEffects(String? encoded) {
  if (encoded == null || encoded.isEmpty) return const [];
  try {
    final raw = jsonDecode(encoded);
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map<String, dynamic>) TrackEffect.fromJson(item),
    ];
  } on FormatException {
    return const [];
  }
}
