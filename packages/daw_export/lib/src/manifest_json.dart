/// Tiny JSON-shape helpers for reading a decoded `performance.json` map: this
/// package's one vocabulary for "what shape is the manifest", so the three
/// files that parse it toward genuinely different outputs —
/// `manifest_reader.dart` (track/clip layout), `fx_chains.dart` (an FX-chain
/// summary) and `device_chain_resolver.dart` (a resolved device chain) —
/// cannot drift apart on it.
///
/// [tracksOf], [chainEnabledOf] and [effectEnabledOf] each have callers in more
/// than one of those files. [trackChainsOf] and [masterEffectsOf] currently
/// have exactly one caller between them (`fx_chains.dart`, the only surface
/// that reports the bus stages) and live here anyway, deliberately: this file
/// is where the FX v3 four-stage shape
/// (`docs/design/performance-manifest-format.md`) is written down once for the
/// package — Input (`monitors[]`), Loop (`tracks[].lanes[]`), Track
/// ([trackChainsOf]) and Master ([masterEffectsOf]) — and hiding two of the
/// four inside one caller is exactly the drift this file exists to prevent.
library;

/// Returns `snapshot['tracks']` as a typed list, or an empty list if
/// `snapshot` isn't a `Map` or has no (or a non-list) `tracks` field —
/// tolerant of a missing/malformed `armSnapshot`/`disarmSnapshot` rather
/// than throwing.
List<Map<String, dynamic>> tracksOf(dynamic snapshot) =>
    _mapListAt(snapshot, 'tracks');

/// Returns `snapshot['trackChains']` — the FX v3 **Track** stage, one bus
/// chain per channel — as a typed list, or an empty list when the field is
/// absent or malformed.
///
/// An empty result covers two cases the reader deliberately does not
/// distinguish: a current snapshot whose rig simply has no bus FX (the writer
/// omits the field entirely), and a **legacy** pre-FX-v3 snapshot that never
/// captured the stage at all. Both mean "no Track-stage chain to report," so
/// there is no version `switch` here — the parse is presence-keyed field by
/// field, matching `docs/design/performance-manifest-format.md`'s own stated
/// read-side rule and the session manifest's migration style. The
/// `fxStagesVersion` marker exists for a writer/replayer that must tell an
/// omitted default from an unknowable legacy value; a summary reader has no
/// such need.
List<Map<String, dynamic>> trackChainsOf(dynamic snapshot) =>
    _mapListAt(snapshot, 'trackChains');

/// Returns `snapshot['masterEffects']` — the FX v3 **Master** insert's
/// entries, in order — as a typed list, or an empty list when the field is
/// absent or malformed (same presence-keyed rule as [trackChainsOf]).
List<Map<String, dynamic>> masterEffectsOf(dynamic snapshot) =>
    _mapListAt(snapshot, 'masterEffects');

/// Returns a chain record's `effects` entries — a `lanes[]` entry's, a
/// `trackChains[]` entry's, or a `monitors[]` entry's — as a typed list, or an
/// empty list when the field is absent or malformed.
///
/// Callers that need to tell "no `effects` key at all" from an explicitly
/// empty chain must check the raw key themselves; this reports both as empty.
List<Map<String, dynamic>> effectsOf(Map<String, dynamic> json) =>
    _mapListAt(json, 'effects');

/// Whether a chain record is engaged as a whole (R15's per-chain bypass
/// flag).
///
/// [json] is whichever map carries the flag under [key]: a `lanes[]` entry or
/// a `trackChains[]` entry (`chainEnabled`, the default), or the `armSnapshot`
/// itself for the Master insert (`masterChainEnabled`). The writer emits every
/// one of these **only when `false`**, so an absent flag means engaged — which
/// is also the right answer for a legacy snapshot, where nothing could be
/// bypassed in the first place.
/// A non-bool value reads as engaged rather than throwing, for the same
/// reason [_mapListAt] skips a non-map element: the two public readers promise
/// a graceful `null` on a corrupt manifest, and their `catch` covers
/// `jsonDecode`'s `FormatException`, not a `TypeError` raised here.
bool chainEnabledOf(
  Map<String, dynamic> json, {
  String key = 'chainEnabled',
}) {
  final value = json[key];
  return value is! bool || value;
}

/// Whether a single FX entry is audible — its own per-slot bypass bit.
///
/// Absent means audible, matching the writer's omit-when-default rule; a
/// disabled slot renders bit-exact passthrough (R16).
bool effectEnabledOf(Map<String, dynamic> effect) => effect['enabled'] != false;

/// Returns `json[key]` as a list of typed JSON maps, or an empty list when it
/// is absent or not a list.
///
/// A non-map ELEMENT is skipped rather than cast: `FxChainsWriter.render` and
/// `DawManifestReader.read` both promise a graceful `null` on a corrupt
/// manifest, and a `TypeError` thrown from here would escape that promise
/// entirely — their `try`/`catch` covers `jsonDecode`'s `FormatException`, not
/// a bad cast. A manifest with `"trackChains": [1, 2]` is malformed either way;
/// reporting no bus chains beats taking down an export that has already
/// written its `.als`.
List<Map<String, dynamic>> _mapListAt(dynamic json, String key) {
  if (json is! Map<String, dynamic>) return const [];
  final value = json[key];
  if (value is! List) return const [];
  return [
    for (final v in value)
      if (v is Map<String, dynamic>) v,
  ];
}
