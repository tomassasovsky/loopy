import 'package:meta/meta.dart';

/// A first-party Loopy VST3 plugin's identity for `.als` device-chain
/// emission — deliberately **not** a reuse of `loopy_engine`'s third-party
/// `PluginRef` (this package has no dependency on `loopy_engine`, and none
/// of the `unavailable`/`unsupported`/`versionChanged` D-MISS machinery a
/// third-party plugin needs applies to Loopy's own, permanently-stable-GUID
/// plugins — umbrella Data Model).
@immutable
class LoopyVst3Ref {
  /// Creates a [LoopyVst3Ref].
  const LoopyVst3Ref({
    required this.classId,
    required this.subcategory,
    required this.paramCount,
    this.vendor = 'Loopy',
    this.version = 0x010000,
  });

  /// The plugin's permanent class GUID, as 32 uppercase hex characters (no
  /// dashes) — the processor class id minted once in the plugin's own part
  /// (`packages/loopy_engine/vst3/*/ids.h`'s `kProcessorUID`, umbrella
  /// D-GUID) and never changed again. This is the identity Ableton
  /// persists in a `.als`'s device XML to re-resolve the plugin on load —
  /// this constant and the C++ `ids.h` it was transcribed from must never
  /// drift apart.
  final String classId;

  /// The plugin's VST3 processor subcategory (e.g. `Fx|Delay`), matching
  /// its `factory.cpp`'s `DEF_VST3_CLASS` call exactly — informational only
  /// (device XML emission doesn't currently need it), carried here so a
  /// future consumer doesn't have to re-derive it from the C++ source.
  final String subcategory;

  /// How many of a `DawEffect`'s (up to `kTrackEffectParams` = 4, always
  /// padded to that width in the persisted manifest) `params` this plugin's
  /// controller actually registers as a real `RangeParameter`/
  /// `StringListParameter` — matching each plugin's `controller.cpp`
  /// exactly (Drive/Filter/Tremolo: 2; Delay/Echo/Reverb: 3; Octaver: 4).
  /// `als_builder.dart`'s `_deviceChainXml` emits only the first
  /// [paramCount] values, never the full always-4-wide padded array — the
  /// trailing padding entries don't correspond to any real parameter the
  /// plugin registers, so emitting them would write `ParameterId` values
  /// Ableton (or the plugin itself) has no meaning for.
  final int paramCount;

  /// The plugin vendor string every Loopy plugin's factory registers —
  /// fixed, never varies per effect.
  final String vendor;

  /// Packed `major << 16 | minor << 8 | patch` — informational only (every
  /// shipped plugin is `1.0.0` today; `kLoopyDelayVersion`-style constants
  /// in each plugin's `factory.cpp` are the source of truth if this ever
  /// needs to track a real per-plugin version).
  final int version;
}

// `TrackEffectType`/native `le_fx_type` codes for the seven built-in
// effects — reproduced here as this package's own constants (no
// `loopy_engine` import, matching the same own-input-model rule
// `fx_chains.dart`'s `_kBuiltInEffectNames` already follows) purely to key
// [loopyVst3Plugins].

/// The `le_fx_type` code for "Loopy Drive".
const int kFxDrive = 1;

/// The `le_fx_type` code for "Loopy Filter".
const int kFxFilter = 2;

/// The `le_fx_type` code for "Loopy Delay".
const int kFxDelay = 3;

/// The `le_fx_type` code for "Loopy Tremolo".
const int kFxTremolo = 4;

/// The `le_fx_type` code for "Loopy Octaver".
const int kFxOctaver = 5;

/// The `le_fx_type` code for "Loopy Echo".
const int kFxEcho = 6;

/// The `le_fx_type` code for "Loopy Reverb".
const int kFxReverb = 7;

/// One [LoopyVst3Ref] per built-in effect type, keyed by its `LE_FX_*` code
/// — hardcoded constants, not runtime-discovered, since `daw_export` is a
/// pure Dart package with no engine dependency (umbrella Data Model). Class
/// GUIDs transcribed from each plugin's `ids.h` (parts 2, 3, 5, 6, 7, 8, 9);
/// subcategories and `paramCount`s transcribed from each plugin's
/// `factory.cpp`/`controller.cpp`.
///
/// This part has no *code* dependency on `packages/loopy_engine/vst3/` (this
/// is a hardcoded-constants file, not an import), but the umbrella's own
/// dependency note is still a real *merge-order* one: this PR should not
/// merge before parts 5-9's PRs do, since Echo/Drive/Filter/Tremolo/
/// Octaver's `ids.h` files (this data's actual source of truth) exist only
/// on those still-open branches at the time this file was written, not in
/// this branch's own history (it was branched directly off `master`, which
/// only has Delay/Reverb, parts 2-3). All seven GUIDs below were
/// independently verified byte-for-byte against each plugin's real `ids.h`
/// before being transcribed here.
const Map<int, LoopyVst3Ref> loopyVst3Plugins = {
  kFxDelay: LoopyVst3Ref(
    classId: '153409ABA7B2437F83B5A2A6C60EF9B6',
    subcategory: 'Fx|Delay',
    paramCount: 3, // Time, Feedback, Mix
  ),
  kFxReverb: LoopyVst3Ref(
    classId: 'C9C65FCDD0774D838C10B84599FD94C4',
    subcategory: 'Fx|Reverb',
    paramCount: 3, // Size, Damping, Mix
  ),
  kFxEcho: LoopyVst3Ref(
    // Echo is a delay-family effect (matches Ableton's own categorization
    // convention), so its subcategory is "Fx|Delay" too — same as Delay,
    // not a typo (see packages/loopy_engine/vst3/echo/factory.cpp).
    classId: 'D771158E80027D4E96FA4568E993192E',
    subcategory: 'Fx|Delay',
    paramCount: 3, // Time, Feedback, Mix
  ),
  kFxDrive: LoopyVst3Ref(
    classId: '4B97C4B2DF150FA1ADF39F6E82E97A25',
    subcategory: 'Fx|Distortion',
    paramCount: 2, // Drive, Level
  ),
  kFxFilter: LoopyVst3Ref(
    classId: 'EDD27869F5C0667F479A338781C80262',
    subcategory: 'Fx|Filter',
    paramCount: 2, // Cutoff, Resonance
  ),
  kFxTremolo: LoopyVst3Ref(
    classId: '2D8D41873BDF80210FE2470FA5D39AA0',
    subcategory: 'Fx|Modulation',
    paramCount: 2, // Rate, Depth
  ),
  kFxOctaver: LoopyVst3Ref(
    classId: '3D52244783390B6415C6CB7A508CE993',
    subcategory: 'Fx|Pitch Shift',
    paramCount: 4, // Shift, Tone, Mix, Mode
  ),
};
