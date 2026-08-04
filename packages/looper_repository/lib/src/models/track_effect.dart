import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/plugin_descriptor.dart';
import 'package:segno_engine/segno_engine.dart' as engine;

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
/// The chain is non-destructive and stage-addressed (FX v3) — the recording is
/// always dry and every active, [enabled] entry colors the signal in order.
/// The same model backs all four stages: a hardware input's live-monitor
/// chain, a lane's record-route chain, a track's stereo-bus chain, and the
/// Master insert.
sealed class TrackEffect extends Equatable {
  /// Const base constructor for the sealed subtypes.
  const TrackEffect();

  /// The native `le_fx_type` code for this entry.
  int get typeCode;

  /// Whether this entry is audible (R16). A disabled entry stays in the chain
  /// with its settings intact but renders bit-exact passthrough.
  bool get enabled;

  /// The entry's stable per-slot identity (A9): minted at the repository write
  /// boundary, unique within a session, never reused, preserved across edits /
  /// reorders / persist→restore. `null` only before the entry has crossed a
  /// repository write path. Identity, not sound: two entries that sound the
  /// same but carry different ids are different entries (bindings target ids).
  String? get slotId;
}

/// A built-in DSP effect: a [type] with its normalized [params].
class BuiltInEffect extends TrackEffect {
  /// Creates a [BuiltInEffect]. [params] defaults to the [type]'s musical
  /// defaults.
  BuiltInEffect({
    required this.type,
    List<double>? params,
    this.enabled = true,
    this.slotId,
  }) : params = List<double>.unmodifiable(params ?? type.defaultParams);

  /// The effect type.
  final TrackEffectType type;

  /// The normalized parameter values (length `kTrackEffectParams`).
  final List<double> params;

  @override
  final bool enabled;

  @override
  final String? slotId;

  @override
  int get typeCode => type.code;

  /// Returns a copy with the given fields replaced. [params] is copied.
  BuiltInEffect copyWith({
    TrackEffectType? type,
    List<double>? params,
    bool? enabled,
    String? slotId,
  }) => BuiltInEffect(
    type: type ?? this.type,
    params: params ?? this.params,
    enabled: enabled ?? this.enabled,
    slotId: slotId ?? this.slotId,
  );

  @override
  List<Object?> get props => [type, params, enabled, slotId];
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
    this.enabled = true,
    this.slotId,
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
  final bool enabled;

  @override
  final String? slotId;

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
    bool? enabled,
    String? slotId,
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
    enabled: enabled ?? this.enabled,
    slotId: slotId ?? this.slotId,
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
    enabled,
    slotId,
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
///
/// Named explicitly by the FX-v3 plan (R16): `enabled` and `slotId` MUST
/// thread through both arms — a field silently dropped here round-trips as its
/// default and the bug stays invisible until a stomp un-bypasses a chain.
engine.TrackEffect _trackEffectToEngine(TrackEffect effect) => switch (effect) {
  BuiltInEffect(
    :final type,
    :final params,
    :final enabled,
    :final slotId,
  ) =>
    engine.BuiltInEffect(
      type: trackEffectTypeToEngine(type),
      params: params,
      enabled: enabled,
      slotId: slotId,
    ),
  PluginEffect(
    :final ref,
    :final paramValues,
    :final state,
    :final name,
    :final enabled,
    :final slotId,
  ) =>
    engine.PluginEffect(
      ref: engine.PluginRef(
        format: pluginFormatToEngine(ref.format),
        id: ref.id,
        version: ref.version,
      ),
      paramValues: paramValues,
      state: state,
      name: name,
      enabled: enabled,
      slotId: slotId,
    ),
};

/// Maps an ordered domain chain to its engine counterpart, for callers that
/// must hand a chain to another engine-facing repository verbatim rather than
/// persist it (`performance_repository`'s `PerformanceChains`, which embeds
/// the engine models as canonical JSON in the arm snapshot).
///
/// The one public boundary mapper: every other domain↔engine conversion stays
/// private behind [encodeTrackEffects] / [decodeTrackEffects]. Callers never
/// need to name the engine types — and must not re-derive this mapping
/// themselves, or the domain and engine models would silently drift.
List<engine.TrackEffect> trackEffectsToEngine(List<TrackEffect> effects) => [
  for (final e in effects) _trackEffectToEngine(e),
];

/// Maps an engine [TrackEffect] to its domain mirror (boundary; internal).
///
/// Named explicitly by the FX-v3 plan (R16) — `enabled` and `slotId` MUST
/// thread through both arms; see [_trackEffectToEngine].
TrackEffect _trackEffectFromEngine(engine.TrackEffect effect) =>
    switch (effect) {
      engine.BuiltInEffect(
        :final type,
        :final params,
        :final enabled,
        :final slotId,
      ) =>
        BuiltInEffect(
          type: TrackEffectType.fromCode(type.code),
          params: params,
          enabled: enabled,
          slotId: slotId,
        ),
      engine.PluginEffect(
        :final ref,
        :final paramValues,
        :final state,
        :final name,
        :final enabled,
        :final slotId,
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
          enabled: enabled,
          slotId: slotId,
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
/// FNV-1a folding the native engine uses in `le_engine_lane_fx_fingerprint` /
/// `le_engine_monitor_fx_fingerprint`, so the repository's cache hash can be
/// compared to the engine's published-chain hash for divergence detection
/// (F6). Four-stage generic: the same fold keys every stage's chain (input,
/// loop, track, master), whether or not the engine publishes a native twin.
///
/// Fold order (D-FPEMPTY, pinned in lockstep with the C
/// `le_fx_chain_fingerprint`): the [chainEnabled] bit first, but only for a
/// NON-empty chain — an empty chain still yields the FNV-1a offset basis (a
/// chain-disabled empty chain and an enabled empty chain are both dry). Then
/// each entry folds its type code, then its real [TrackEffect.enabled] bit,
/// then (built-ins only) its `kTrackEffectParams` parameter float-bits
/// (padding a short param list with the type's defaults, matching the tail the
/// engine seeds on a type set). A plugin entry contributes its type + enabled
/// bit only — the engine's `a_fx_param` holds no plugin params (they live in
/// the plugin host).
///
/// [TrackEffect.slotId] deliberately does NOT fold: the fingerprint is sound
/// identity, slot ids are entry identity (A9) — folding them would break the
/// wet cache's fingerprint-keyed hits on toggle pairs and identical loads.
int fxChainFingerprint(List<TrackEffect> chain, {bool chainEnabled = true}) {
  var h = engine.FxFingerprint.offset;
  final n = chain.length > engine.kTrackEffectMax
      ? engine.kTrackEffectMax
      : chain.length;
  if (n > 0) {
    h = engine.FxFingerprint.mixU32(h, chainEnabled ? 1 : 0);
  }
  for (var i = 0; i < n; i++) {
    final fx = chain[i];
    h = engine.FxFingerprint.mixU32(h, fx.typeCode);
    h = engine.FxFingerprint.mixU32(h, fx.enabled ? 1 : 0);
    if (fx is! BuiltInEffect) continue; // plugin: type + enabled bit only
    final defaults = fx.type.defaultParams;
    for (var p = 0; p < engine.kTrackEffectParams; p++) {
      final value = p < fx.params.length ? fx.params[p] : defaults[p];
      h = engine.FxFingerprint.mixU32(h, engine.FxFingerprint.floatBits(value));
    }
  }
  return h;
}
