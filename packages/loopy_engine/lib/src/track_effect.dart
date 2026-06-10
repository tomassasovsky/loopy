/// The number of effect insert slots each track has, applied in order to the
/// track's mono output. Mirrors the native `LE_FX_SLOTS`.
const int kTrackEffectSlots = 3;

/// The number of normalized (`0..1`) parameters each effect slot exposes.
/// Mirrors the native `LE_FX_PARAMS`.
const int kTrackEffectParams = 3;

/// A built-in per-track effect type. The integer [code] matches the native
/// `le_fx_type` enum, and each type interprets its slot's [kTrackEffectParams]
/// normalized parameters differently (see [paramLabels]).
enum TrackEffectType {
  /// The slot is bypassed.
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

  /// Labels for this type's parameters, in slot-parameter order. The list
  /// length is the number of parameters the type actually uses (`<=`
  /// [kTrackEffectParams]); trailing unused parameters are omitted.
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
