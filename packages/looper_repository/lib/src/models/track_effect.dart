import 'package:equatable/equatable.dart';
import 'package:loopy_engine/loopy_engine.dart' as engine;

/// How a parameter's `0..1` value is read out in the UI, in its own units, when
/// the bare number isn't meaningful on its own. Domain mirror of the engine's
/// readout kinds; the UI maps each to a localized string ([none] shows none).
enum ParamReadout {
  /// No unit readout — the slider alone is enough.
  none,

  /// A pitch interval (e.g. "Unison", "+7 st", "-1 oct").
  pitchShift,

  /// The octaver algorithm mode (phase vocoder / PSOLA).
  octaverMode,
}

/// How one effect parameter should be presented in the UI.
///
/// The value itself is always a normalized `0..1` double (see [TrackEffect]);
/// this only describes the control. [divisions], when set, snaps the slider to
/// that many discrete steps. [readout] selects a human-readable unit readout
/// shown live beside the slider.
class TrackEffectParam extends Equatable {
  /// Creates a parameter descriptor.
  const TrackEffectParam(
    this.label, {
    this.divisions,
    this.readout = ParamReadout.none,
  });

  /// A short name for the control.
  final String label;

  /// The number of discrete steps the control snaps to, or `null` for a
  /// continuous control.
  final int? divisions;

  /// How the value should be read out in its own units, or [ParamReadout.none].
  final ParamReadout readout;

  @override
  List<Object?> get props => [label, divisions, readout];
}

/// A built-in effect type, the domain mirror of the engine's `le_fx_type`.
///
/// The integer [code] matches the native enum; the per-type parameter
/// descriptors and musical defaults are sourced from the engine so the two can
/// never drift (a single source of truth for the musical metadata), while the
/// type the presentation layer names stays a repository-owned domain type.
enum TrackEffectType {
  /// The entry is bypassed.
  none(0),

  /// Soft-clipping overdrive.
  drive(1),

  /// Resonant low-pass filter.
  filter(2),

  /// Feedback delay.
  delay(3),

  /// Sine-LFO amplitude modulation.
  tremolo(4),

  /// Pitch-shift octaver.
  octaver(5),

  /// Tape-style echo with damped, smearing repeats.
  echo(6),

  /// Schroeder/Freeverb room reverb.
  reverb(7);

  const TrackEffectType(this.code);

  /// The native `le_fx_type` integer.
  final int code;

  /// Maps a native `le_fx_type` integer back to a [TrackEffectType]; unknown
  /// values fall back to [TrackEffectType.none].
  static TrackEffectType fromCode(int code) =>
      values.firstWhere((t) => t.code == code, orElse: () => none);

  /// The engine type this maps to, for sourcing metadata + boundary mapping.
  engine.TrackEffectType get _engine => engine.TrackEffectType.fromCode(code);

  /// A short human-readable name for menus.
  String get label => _engine.label;

  /// This type's parameters, in order (length `<=` `kTrackEffectParams`).
  List<TrackEffectParam> get params => [
    for (final p in _engine.params)
      TrackEffectParam(
        p.label,
        divisions: p.divisions,
        readout: _readoutFromEngine(p.readout),
      ),
  ];

  /// Labels for this type's parameters, in order. A convenience over [params].
  List<String> get paramLabels => _engine.paramLabels;

  /// The musical default for each of the `kTrackEffectParams` parameters when
  /// the type is freshly engaged.
  List<double> get defaultParams => _engine.defaultParams;
}

/// One entry in an effects chain: a [type] with its [params] (normalized
/// `0..1`, length `kTrackEffectParams`).
///
/// The chain is non-destructive and stageless — the recording is always dry and
/// every active entry colors playback in order. The same model backs a lane's
/// record-route chain and a hardware input's live-monitor chain.
class TrackEffect extends Equatable {
  /// Creates a [TrackEffect]. [params] defaults to the [type]'s musical
  /// defaults.
  TrackEffect({required this.type, List<double>? params})
    : params = List<double>.unmodifiable(params ?? type.defaultParams);

  /// The effect type.
  final TrackEffectType type;

  /// The normalized parameter values (length `kTrackEffectParams`).
  final List<double> params;

  /// Returns a copy with the given fields replaced. [params] is copied.
  TrackEffect copyWith({TrackEffectType? type, List<double>? params}) =>
      TrackEffect(type: type ?? this.type, params: params ?? this.params);

  @override
  List<Object?> get props => [type, params];
}

/// Maps an engine readout kind to its domain mirror.
ParamReadout _readoutFromEngine(engine.ParamReadout readout) =>
    switch (readout) {
      engine.ParamReadout.none => ParamReadout.none,
      engine.ParamReadout.pitchShift => ParamReadout.pitchShift,
      engine.ParamReadout.octaverMode => ParamReadout.octaverMode,
    };

/// Maps a domain [TrackEffectType] to the engine enum at the boundary.
engine.TrackEffectType trackEffectTypeToEngine(TrackEffectType type) =>
    engine.TrackEffectType.fromCode(type.code);

/// Encodes an ordered effects chain to a JSON string for persistence.
///
/// Delegates to the engine's wire-format serializer so the persisted format
/// stays the single source of truth (no domain/engine drift).
String encodeTrackEffects(List<TrackEffect> effects) =>
    engine.encodeTrackEffects([
      for (final e in effects)
        engine.TrackEffect(
          type: trackEffectTypeToEngine(e.type),
          params: e.params,
        ),
    ]);

/// Decodes a chain produced by [encodeTrackEffects]; malformed input yields an
/// empty chain. Delegates to the engine serializer, then maps to domain types.
List<TrackEffect> decodeTrackEffects(String? encoded) => [
  for (final e in engine.decodeTrackEffects(encoded))
    TrackEffect(type: TrackEffectType.fromCode(e.type.code), params: e.params),
];
