import 'package:daw_export/src/daw_effect.dart';
import 'package:meta/meta.dart';

/// Why [resolveDeviceChain] fell back for a channel, rather than resolving a
/// device chain — surfaced to the app's export-flow feedback (part 11) with
/// a distinct, specific reason per case (umbrella D-CHAIN-FALLBACK).
enum DeviceChainFallbackReason {
  /// The channel's captured lanes don't all carry the same effects chain
  /// (same effects, same params, same order) — an Ableton track has exactly
  /// one device chain, so there is no single honest chain to emit
  /// (umbrella D-LANE-CHAIN).
  mixedLaneChains,

  /// The (identical, shared) chain contains a third-party hosted plugin
  /// entry (`type: kPluginFxCode`) — a pre-existing, separate export gap
  /// this feature does not attempt to close.
  thirdPartyPlugin,

  /// The (identical, shared) chain contains an effect `type` this feature
  /// doesn't recognize as a built-in — a forward-compat guard for an effect
  /// type added after this plan, if any.
  unrepresentedEffectType,
}

/// The outcome of [resolveDeviceChain]: exactly one of [chain] /
/// [fallbackReason] is non-null.
///
/// [chain] is never null when resolution succeeds — including for a channel
/// with no effects on any lane at all, which resolves to an *empty* chain
/// (not a fallback: there is nothing to explain, [DeviceChainResolution.
/// chain] is `const []`) per `daw_project.dart`'s
/// `DawTrack.deviceChainFallbackReason` doc.
@immutable
class DeviceChainResolution {
  /// A successfully resolved chain (possibly empty).
  const DeviceChainResolution.resolved(this.chain) : fallbackReason = null;

  /// A fallback — no chain could be honestly resolved.
  const DeviceChainResolution.fallback(DeviceChainFallbackReason reason)
    : chain = null,
      fallbackReason = reason;

  /// The resolved chain, or `null` if resolution fell back.
  final List<DawEffect>? chain;

  /// Why resolution fell back, or `null` if it succeeded.
  final DeviceChainFallbackReason? fallbackReason;
}

/// Resolves a channel's captured lanes' raw `effects` JSON (each lane's own
/// `armSnapshot` `lanes[].effects` array — see
/// `docs/design/performance-manifest-format.md`) into either a single
/// representable device chain or a reason it couldn't be (umbrella
/// D-LANE-CHAIN / D-CHAIN-FALLBACK). A pure function, independently
/// unit-testable from manifest parsing (`manifest_reader.dart` is the sole
/// caller against real capture data).
///
/// [laneEffects] is one entry per captured lane belonging to the channel,
/// each itself the lane's raw `effects` array (already extracted from the
/// manifest's JSON) — an empty list for a lane with no `effects` key (no
/// chain engaged). An empty [laneEffects] (a channel with no captured lanes
/// at all) resolves to an empty chain, same as every lane individually
/// having no effects.
DeviceChainResolution resolveDeviceChain(
  List<List<Map<String, dynamic>>> laneEffects,
) {
  if (laneEffects.isEmpty) {
    return const DeviceChainResolution.resolved(<DawEffect>[]);
  }

  final shared = laneEffects.first;
  for (final lane in laneEffects.skip(1)) {
    if (!_effectsEqual(shared, lane)) {
      return const DeviceChainResolution.fallback(
        DeviceChainFallbackReason.mixedLaneChains,
      );
    }
  }

  // Every lane agrees — now check whether the one shared chain is honestly
  // representable at all. Order matters: a chain containing BOTH a
  // third-party plugin and an unrecognized type reports whichever comes
  // first in the chain, since both are equally "can't represent this,"
  // there is no principled reason to prefer one report over the other when
  // they co-occur.
  for (final entry in shared) {
    final type = (entry['type'] as num?)?.toInt() ?? 0;
    if (type == kPluginFxCode) {
      return const DeviceChainResolution.fallback(
        DeviceChainFallbackReason.thirdPartyPlugin,
      );
    }
    if (type < kMinBuiltInEffectType || type > kMaxBuiltInEffectType) {
      return const DeviceChainResolution.fallback(
        DeviceChainFallbackReason.unrepresentedEffectType,
      );
    }
  }

  return DeviceChainResolution.resolved([
    for (final entry in shared) DawEffect.fromJson(entry),
  ]);
}

/// Whether two lanes' raw effects arrays are identical — same length, same
/// entries, same order. Order-sensitive and value-sensitive on purpose: two
/// chains with the same effects in a different order, or the same effects
/// with different param values, are NOT the same chain (the near-miss cases
/// the umbrella's own risk register calls out explicitly).
bool _effectsEqual(
  List<Map<String, dynamic>> a,
  List<Map<String, dynamic>> b,
) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!_jsonEquals(a[i], b[i])) return false;
  }
  return true;
}

/// Deep structural equality over decoded JSON values (`Map`/`List`/
/// primitives) — a full-entry comparison rather than only `type`+`params`
/// so a `plugin` sub-map (or any other field) also participates, avoiding a
/// false "identical" verdict for two different third-party plugin entries
/// that happen to share a `type`. No `collection` package dependency added
/// for this: the recursion is a handful of lines and this package otherwise
/// only depends on `meta`.
bool _jsonEquals(dynamic a, dynamic b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!_jsonEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b;
  return a == b;
}
