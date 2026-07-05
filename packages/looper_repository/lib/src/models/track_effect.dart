import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/plugin_descriptor.dart';
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

/// The identity of a hosted plugin in a chain entry. Domain mirror of the
/// engine's `PluginRef`: format + stable id + packed version.
class PluginRef extends Equatable {
  /// Creates a [PluginRef].
  const PluginRef({required this.format, required this.id, this.version = 0});

  /// The plugin format.
  final PluginFormat format;

  /// The stable plugin id (VST3 TUID hex / CLAP descriptor id).
  final String id;

  /// Packed version `major << 16 | minor << 8 | patch`, or `0` if unknown.
  final int version;

  @override
  List<Object?> get props => [format, id, version];
}

/// One entry in an effects chain — a sealed hierarchy of either a built-in DSP
/// effect ([BuiltInEffect]) or a hosted plugin ([PluginEffect]). Domain mirror
/// of the engine's sealed `TrackEffect`.
///
/// The chain is non-destructive and stageless — the recording is always dry and
/// every active entry colors playback in order. The same model backs a lane's
/// record-route chain and a hardware input's live-monitor chain.
sealed class TrackEffect extends Equatable {
  /// Const base constructor for the sealed subtypes.
  const TrackEffect();

  /// The native `le_fx_type` code for this entry.
  int get typeCode;
}

/// A built-in DSP effect: a [type] with its normalized [params].
class BuiltInEffect extends TrackEffect {
  /// Creates a [BuiltInEffect]. [params] defaults to the [type]'s musical
  /// defaults.
  BuiltInEffect({required this.type, List<double>? params})
    : params = List<double>.unmodifiable(params ?? type.defaultParams);

  /// The effect type.
  final TrackEffectType type;

  /// The normalized parameter values (length `kTrackEffectParams`).
  final List<double> params;

  @override
  int get typeCode => type.code;

  /// Returns a copy with the given fields replaced. [params] is copied.
  BuiltInEffect copyWith({TrackEffectType? type, List<double>? params}) =>
      BuiltInEffect(type: type ?? this.type, params: params ?? this.params);

  @override
  List<Object?> get props => [type, params];
}

/// A hosted VST3/CLAP plugin in a chain entry, identified by its [ref]. Carries
/// the user-tweaked [paramValues] (persisted) and the live [params] metadata
/// enumerated from the loaded plugin (transient). The opaque state blob lands
/// in a later part.
class PluginEffect extends TrackEffect {
  /// Creates a [PluginEffect] for [ref], optionally seeded with persisted
  /// [paramValues] and live [params] metadata.
  const PluginEffect({
    required this.ref,
    this.paramValues = const {},
    this.params = const [],
    this.name = '',
    this.state = '',
    this.unavailable = false,
    this.unsupported = false,
    this.versionChanged = false,
    this.loading = false,
  });

  /// The hosted plugin's identity.
  final PluginRef ref;

  /// Persisted plain parameter values keyed by parameter id. Only params the
  /// user has changed are stored; an absent id falls back to the plugin's
  /// default.
  final Map<int, double> paramValues;

  /// The plugin's opaque state, base64-encoded (persisted; D-P1). Empty when
  /// the plugin has no state. The repository decodes it to bytes to restore.
  final String state;

  /// Live parameter metadata enumerated from the loaded plugin, in plugin
  /// order. Transient — never persisted.
  final List<PluginParamInfo> params;

  /// The plugin's user-visible display name, resolved from the scan catalog
  /// when loaded. Transient (never persisted — re-resolved from [ref]); empty
  /// when unresolved, in which case the UI falls back to the stable id.
  final String name;

  /// Whether the plugin failed to resolve/load on the running engine
  /// (uninstalled / moved / incompatible — umbrella D-MISS). Transient. A
  /// placeholder card surfaces it, preserving [ref] + [state] for relink; the
  /// entry is never silently dropped.
  final bool unavailable;

  /// Whether the failure is because the plugin is installed but **rejected** —
  /// an instrument / multi-bus / wrong-channel plugin that isn't a supported
  /// stereo effect (D-BUS), as opposed to simply missing. Transient; only
  /// meaningful when [unavailable]. Distinguishes the placeholder's message.
  final bool unsupported;

  /// Whether the installed plugin's version differs from the saved [ref]'s
  /// (same id, different version — D-MISS). Transient; the plugin still loaded,
  /// but the card notes the drift.
  final bool versionChanged;

  /// Whether the plugin is still resolving: it hasn't loaded yet because a
  /// plugin scan is in progress (typically a cold boot, F5), so it is expected
  /// to bind once the scan lands. Transient. Distinct from [unavailable] — a
  /// loading entry renders a "loading…" state (no relink), never the
  /// "unavailable" placeholder, so a still-scanning plugin doesn't read as a
  /// genuine failure.
  final bool loading;

  @override
  int get typeCode => engine.kPluginFxCode;

  /// Returns a copy with the given fields replaced.
  PluginEffect copyWith({
    PluginRef? ref,
    Map<int, double>? paramValues,
    List<PluginParamInfo>? params,
    String? name,
    String? state,
    bool? unavailable,
    bool? unsupported,
    bool? versionChanged,
    bool? loading,
  }) => PluginEffect(
    ref: ref ?? this.ref,
    paramValues: paramValues ?? this.paramValues,
    params: params ?? this.params,
    name: name ?? this.name,
    state: state ?? this.state,
    unavailable: unavailable ?? this.unavailable,
    unsupported: unsupported ?? this.unsupported,
    versionChanged: versionChanged ?? this.versionChanged,
    loading: loading ?? this.loading,
  );

  @override
  List<Object?> get props => [
    ref,
    paramValues,
    params,
    name,
    state,
    unavailable,
    unsupported,
    versionChanged,
    loading,
  ];
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

/// Maps a domain [TrackEffect] to its engine counterpart (boundary; internal).
engine.TrackEffect _trackEffectToEngine(TrackEffect effect) => switch (effect) {
  BuiltInEffect(:final type, :final params) => engine.BuiltInEffect(
    type: trackEffectTypeToEngine(type),
    params: params,
  ),
  PluginEffect(:final ref, :final paramValues, :final state, :final name) =>
    engine.PluginEffect(
      ref: engine.PluginRef(
        format: pluginFormatToEngine(ref.format),
        id: ref.id,
        version: ref.version,
      ),
      paramValues: paramValues,
      state: state,
      name: name,
    ),
};

/// Maps an engine [TrackEffect] to its domain mirror (boundary; internal).
TrackEffect _trackEffectFromEngine(engine.TrackEffect effect) =>
    switch (effect) {
      engine.BuiltInEffect(:final type, :final params) => BuiltInEffect(
        type: TrackEffectType.fromCode(type.code),
        params: params,
      ),
      engine.PluginEffect(
        :final ref,
        :final paramValues,
        :final state,
        :final name,
      ) =>
        PluginEffect(
          ref: PluginRef(
            format: pluginFormatFromEngine(ref.format),
            id: ref.id,
            version: ref.version,
          ),
          paramValues: paramValues,
          state: state,
          name: name,
        ),
    };

/// Encodes an ordered effects chain to a JSON string for persistence.
///
/// Delegates to the engine's wire-format serializer so the persisted format
/// stays the single source of truth (no domain/engine drift).
String encodeTrackEffects(List<TrackEffect> effects) =>
    engine.encodeTrackEffects([
      for (final e in effects) _trackEffectToEngine(e),
    ]);

/// Decodes a chain produced by [encodeTrackEffects]; malformed input yields an
/// empty chain. Delegates to the engine serializer, then maps to domain types.
List<TrackEffect> decodeTrackEffects(String? encoded) => [
  for (final e in engine.decodeTrackEffects(encoded)) _trackEffectFromEngine(e),
];

/// An order-sensitive 64-bit fingerprint of [chain], computed with the SAME
/// FNV-1a folding the native engine uses in `le_engine_lane_fx_fingerprint`, so
/// the repository's cache hash can be compared to the engine's published-chain
/// hash for divergence detection (F6).
///
/// Each entry folds in its type code; a built-in additionally folds its
/// `kTrackEffectParams` parameter float-bits (padding a short param list with
/// the type's defaults, matching the tail the engine seeds on a type set). A
/// plugin entry contributes its type only — the engine's `a_fx_param` holds no
/// plugin params (they live in the plugin host). An empty chain yields the
/// FNV-1a offset basis.
int trackChainFingerprint(List<TrackEffect> chain) {
  var h = engine.FxFingerprint.offset;
  final n = chain.length > engine.kTrackEffectMax
      ? engine.kTrackEffectMax
      : chain.length;
  for (var i = 0; i < n; i++) {
    final fx = chain[i];
    h = engine.FxFingerprint.mixU32(h, fx.typeCode);
    if (fx is! BuiltInEffect) continue; // plugin: type only
    final defaults = fx.type.defaultParams;
    for (var p = 0; p < engine.kTrackEffectParams; p++) {
      final value = p < fx.params.length ? fx.params[p] : defaults[p];
      h = engine.FxFingerprint.mixU32(h, engine.FxFingerprint.floatBits(value));
    }
  }
  return h;
}
