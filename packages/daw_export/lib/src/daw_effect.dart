import 'package:meta/meta.dart';

/// The `type` code a chain entry carrying a `plugin` key uses — matches
/// `loopy_engine`'s `kPluginFxCode`. A `DawEffect` can never represent an
/// entry with this code (see `resolveDeviceChain` in
/// `device_chain_resolver.dart`, which is where a `type: 8` entry is
/// classified and turned into a fallback, never a `DawEffect`).
const int kPluginFxCode = 8;

/// The lowest valid `LE_FX_*` built-in effect type code a `DawEffect` can
/// represent — `LE_FX_DRIVE`, matching `loopy_engine`'s
/// `loopy_engine_api.h`. `0` (`LE_FX_NONE`) is below this range and is not
/// a built-in effect this feature can emit a device for.
const int kMinBuiltInEffectType = 1;

/// The highest valid `LE_FX_*` built-in effect type code a `DawEffect` can
/// represent — `LE_FX_REVERB`, matching `loopy_engine`'s
/// `loopy_engine_api.h`. Any code above this other than [kPluginFxCode] is
/// not a built-in effect this feature can emit a device for.
const int kMaxBuiltInEffectType = 7;

/// One built-in effect entry in a resolved device chain: a `LE_FX_*` [type]
/// code and its normalized (`0..1`) [params], parsed independently from the
/// manifest's `TrackEffect.toJson()` shape
/// (`docs/design/performance-manifest-format.md`) — no import of
/// `loopy_engine`/`looper_repository`, matching this package's existing
/// own-input-model rule (`manifest_reader.dart`'s own doc comment).
///
/// Only ever constructed for an entry already known to be representable —
/// `resolveDeviceChain` (`device_chain_resolver.dart`) is the sole caller of
/// [DawEffect.fromJson], and it only calls it after confirming an entry's
/// `type` is a built-in code, never [kPluginFxCode] or an unrecognized one.
@immutable
class DawEffect {
  /// Creates a [DawEffect].
  const DawEffect({required this.type, required this.params});

  /// Rebuilds a [DawEffect] from one manifest `effects[]` entry
  /// (`{type, params}`) — the caller must have already confirmed `type` is
  /// a representable built-in code.
  factory DawEffect.fromJson(Map<String, dynamic> json) {
    final type = (json['type'] as num?)?.toInt() ?? 0;
    final rawParams = json['params'] as List<dynamic>?;
    final params = rawParams == null
        ? const <double>[]
        : List<double>.unmodifiable([
            for (final p in rawParams) (p as num).toDouble(),
          ]);
    return DawEffect(type: type, params: params);
  }

  /// The native `le_fx_type` code (`kMinBuiltInEffectType`..
  /// `kMaxBuiltInEffectType`).
  final int type;

  /// The effect's normalized (`0..1`) parameter values, in engine order.
  final List<double> params;

  @override
  bool operator ==(Object other) =>
      other is DawEffect &&
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
