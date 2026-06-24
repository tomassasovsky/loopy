import 'dart:convert';

import 'package:loopy_engine/src/plugin_descriptor.dart';
import 'package:meta/meta.dart';

/// The native `le_fx_type` code for a hosted plugin entry (`LE_FX_PLUGIN`).
/// A chain entry carrying this code plus a `plugin` key is a [PluginEffect];
/// every other code is a [BuiltInEffect].
const int kPluginFxCode = 8;

/// The maximum number of effects a single track's chain can hold. The cap
/// exists only so the audio thread reads a fixed-size, allocation-free array —
/// it is far beyond musical need, not a CPU limit. Mirrors the native
/// `LE_FX_MAX`.
const int kTrackEffectMax = 8;

/// The number of normalized (`0..1`) parameters each effect exposes. Mirrors
/// the native `LE_FX_PARAMS`.
const int kTrackEffectParams = 4;

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
  tremolo(4, 'Tremolo'),

  /// Pitch-shift octaver — shifts up or down, by octaves or smaller intervals.
  octaver(5, 'Octaver'),

  /// Tape-style echo with damped, smearing repeats.
  echo(6, 'Echo'),

  /// Schroeder/Freeverb room reverb — a dense, smooth decaying tail. Spreads a
  /// mono source into a stereo tail across the first two channels of its output
  /// route, so it is best placed last in a chain.
  reverb(7, 'Reverb');

  const TrackEffectType(this.code, this.label);

  /// The native `le_fx_type` integer.
  final int code;

  /// A short human-readable name for menus.
  final String label;

  /// Maps a native `le_fx_type` integer back to a [TrackEffectType]; unknown
  /// values fall back to [TrackEffectType.none].
  static TrackEffectType fromCode(int code) =>
      values.firstWhere((t) => t.code == code, orElse: () => none);

  /// This type's parameters, in order. The list length is the number of
  /// parameters the type actually uses (`<=` [kTrackEffectParams]); trailing
  /// unused parameters are omitted. Each entry also carries how it should be
  /// presented (see [TrackEffectParam]) — most are plain continuous controls,
  /// but musical parameters like the octaver's pitch snap to discrete values
  /// and read out in their own units.
  List<TrackEffectParam> get params => switch (this) {
    TrackEffectType.none => const [],
    TrackEffectType.drive => const [
      TrackEffectParam('Drive'),
      TrackEffectParam('Level'),
    ],
    TrackEffectType.filter => const [
      TrackEffectParam('Cutoff'),
      TrackEffectParam('Resonance'),
    ],
    TrackEffectType.delay => const [
      TrackEffectParam('Time'),
      TrackEffectParam('Feedback'),
      TrackEffectParam('Mix'),
    ],
    TrackEffectType.tremolo => const [
      TrackEffectParam('Rate'),
      TrackEffectParam('Depth'),
    ],
    // Shift snaps to whole semitones across the engine's +-2 octave range, with
    // a centre detent at unison, and reads out as a pitch interval. Mode is a
    // two-state toggle (phase vocoder / PSOLA) — stored but inert until the
    // formant-preserving rewrite reads it.
    TrackEffectType.octaver => const [
      TrackEffectParam(
        'Shift',
        divisions: 48,
        readout: ParamReadout.pitchShift,
      ),
      TrackEffectParam('Tone'),
      TrackEffectParam('Mix'),
      TrackEffectParam('Mode', divisions: 1, readout: ParamReadout.octaverMode),
    ],
    TrackEffectType.echo => const [
      TrackEffectParam('Time'),
      TrackEffectParam('Feedback'),
      TrackEffectParam('Mix'),
    ],
    TrackEffectType.reverb => const [
      TrackEffectParam('Size'),
      TrackEffectParam('Damping'),
      TrackEffectParam('Mix'),
    ],
  };

  /// Labels for this type's parameters, in order. A convenience over [params].
  List<String> get paramLabels => [for (final p in params) p.label];

  /// The musical default for each of the [kTrackEffectParams] parameters when
  /// the type is freshly engaged. Mirrors the engine's `le_fx_default_params`
  /// so the UI sliders match what the engine seeds.
  List<double> get defaultParams => switch (this) {
    TrackEffectType.none => const [0, 0, 0, 0],
    TrackEffectType.drive => const [0.5, 0.8, 0, 0],
    TrackEffectType.filter => const [0.5, 0.2, 0, 0],
    TrackEffectType.delay => const [0.35, 0.35, 0.35, 0],
    TrackEffectType.tremolo => const [0.3, 0.7, 0, 0],
    // p3 = mode: 0 selects the phase vocoder (inert until parts 3-4).
    TrackEffectType.octaver => const [0.25, 0.5, 0.5, 0],
    TrackEffectType.echo => const [0.45, 0.5, 0.35, 0],
    TrackEffectType.reverb => const [0.5, 0.5, 0.35, 0],
  };
}

/// How a parameter's `0..1` value is read out in the UI, in its own units, when
/// the bare number isn't meaningful on its own. The UI maps each kind to a
/// localized string; [none] shows no readout.
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
/// that many discrete steps so a musical parameter lands on exact values rather
/// than floating between them. [readout] selects a human-readable unit readout
/// (e.g. a pitch interval) shown live beside the slider.
@immutable
class TrackEffectParam {
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
}

/// The identity of a hosted plugin in a chain entry: its [format], stable [id]
/// (VST3 TUID / CLAP descriptor id), and packed [version] (for drift
/// detection). This is enough to re-resolve and re-load the plugin from a
/// persisted chain; the variable parameter values and the opaque state blob
/// land in later parts.
@immutable
final class PluginRef {
  /// Creates a [PluginRef].
  const PluginRef({
    required this.format,
    required this.id,
    this.version = 0,
  });

  /// Rebuilds a [PluginRef] from its [toJson] map.
  factory PluginRef.fromJson(Map<String, dynamic> json) => PluginRef(
    format: PluginFormat.fromCode((json['format'] as num?)?.toInt() ?? 0),
    id: (json['id'] as String?) ?? '',
    version: (json['version'] as num?)?.toInt() ?? 0,
  );

  /// The plugin format.
  final PluginFormat format;

  /// The stable plugin id (VST3 TUID hex / CLAP descriptor id).
  final String id;

  /// Packed version `major << 16 | minor << 8 | patch`, or `0` if unknown.
  final int version;

  /// A JSON-friendly map for persistence.
  Map<String, dynamic> toJson() => {
    'format': format.code,
    'id': id,
    'version': version,
  };

  @override
  bool operator ==(Object other) =>
      other is PluginRef &&
      other.format == format &&
      other.id == id &&
      other.version == version;

  @override
  int get hashCode => Object.hash(format, id, version);
}

/// One entry in an effects chain — a sealed hierarchy of either a built-in DSP
/// effect ([BuiltInEffect]) or a hosted VST3/CLAP plugin ([PluginEffect]).
///
/// The chain is non-destructive and stageless — the recording is always dry and
/// every active entry colors playback in order. The same model backs a lane's
/// record-route chain and a hardware input's live-monitor chain.
sealed class TrackEffect {
  /// Const base constructor for the sealed subtypes.
  const TrackEffect();

  /// Rebuilds a [TrackEffect] from a persisted entry, dual-decoding by shape: a
  /// `LE_FX_PLUGIN` ([kPluginFxCode]) entry carrying a `plugin` key is a
  /// [PluginEffect]; everything else is a [BuiltInEffect]. There is no envelope
  /// — a pre-plugin chain (an array of bare `{type, params}` entries) decodes
  /// unchanged. A plugin entry is NEVER silently dropped to `none`.
  factory TrackEffect.fromJson(Map<String, dynamic> json) {
    final code = (json['type'] as num?)?.toInt() ?? 0;
    if (code == kPluginFxCode && json['plugin'] is Map<String, dynamic>) {
      return PluginEffect.fromJson(json);
    }
    return BuiltInEffect.fromJson(json);
  }

  /// The native `le_fx_type` code for this entry.
  int get typeCode;

  /// A JSON-friendly map for persistence (codes, not enum names).
  Map<String, dynamic> toJson();
}

/// A built-in DSP effect: a [type] with its normalized [params].
@immutable
final class BuiltInEffect extends TrackEffect {
  /// Creates a [BuiltInEffect]. [params] defaults to the [type]'s musical
  /// defaults.
  BuiltInEffect({required this.type, List<double>? params})
    : params = List<double>.unmodifiable(params ?? type.defaultParams);

  /// Rebuilds a [BuiltInEffect] from [toJson] output; unknown codes fall back
  /// to safe defaults. A legacy `stage` key (from the removed pre/post model)
  /// is ignored, so older persisted chains still decode.
  ///
  /// The decoded `params` are normalized to [kTrackEffectParams]: a list saved
  /// by a narrower build is padded with the type's own `defaultParams` (so a
  /// future non-zero default round-trips, and the octaver's new `mode` lands on
  /// phase vocoder), and an over-long list is truncated.
  factory BuiltInEffect.fromJson(Map<String, dynamic> json) {
    final type = TrackEffectType.fromCode((json['type'] as num?)?.toInt() ?? 0);
    final rawParams = json['params'];
    if (rawParams is! List) return BuiltInEffect(type: type);
    final decoded = [for (final v in rawParams) (v as num).toDouble()];
    final defaults = type.defaultParams;
    return BuiltInEffect(
      type: type,
      params: [
        for (var i = 0; i < kTrackEffectParams; i++)
          i < decoded.length ? decoded[i] : defaults[i],
      ],
    );
  }

  /// The effect type.
  final TrackEffectType type;

  /// The normalized parameter values (length [kTrackEffectParams]).
  final List<double> params;

  @override
  int get typeCode => type.code;

  /// Returns a copy with the given fields replaced. [params] is copied.
  BuiltInEffect copyWith({TrackEffectType? type, List<double>? params}) =>
      BuiltInEffect(type: type ?? this.type, params: params ?? this.params);

  @override
  Map<String, dynamic> toJson() => {'type': type.code, 'params': params};

  @override
  bool operator ==(Object other) =>
      other is BuiltInEffect &&
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

/// A hosted VST3/CLAP plugin in a chain entry, identified by its [ref].
///
/// This part carries the plugin identity only; the variable parameter values
/// and the opaque state blob are added in later parts. An unresolved plugin
/// (its `ref` no longer matches an installed plugin) is still a [PluginEffect]
/// — never silently dropped — so its identity survives a reload.
@immutable
final class PluginEffect extends TrackEffect {
  /// Creates a [PluginEffect] for [ref].
  const PluginEffect({required this.ref});

  /// Rebuilds a [PluginEffect] from a persisted `{type, plugin}` entry.
  factory PluginEffect.fromJson(Map<String, dynamic> json) => PluginEffect(
    ref: PluginRef.fromJson(json['plugin'] as Map<String, dynamic>),
  );

  /// The hosted plugin's identity.
  final PluginRef ref;

  @override
  int get typeCode => kPluginFxCode;

  /// Returns a copy with [ref] replaced.
  PluginEffect copyWith({PluginRef? ref}) => PluginEffect(ref: ref ?? this.ref);

  @override
  Map<String, dynamic> toJson() => {
    'type': kPluginFxCode,
    'plugin': ref.toJson(),
  };

  @override
  bool operator ==(Object other) => other is PluginEffect && other.ref == ref;

  @override
  int get hashCode => ref.hashCode;
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
