import 'package:flutter/foundation.dart';

/// A published update descriptor, as served per channel at
/// `…/updates/appliance/<channel>/manifest.json` (and the desktop appcasts map
/// onto the same fields). The signature on the bundle itself is the security
/// boundary; this manifest only advertises what is available.
@immutable
class UpdateManifest {
  /// Creates an [UpdateManifest].
  const UpdateManifest({
    required this.version,
    required this.bundle,
    this.sha256 = '',
    this.channel = '',
    this.size = 0,
    this.notes = '',
  });

  /// Parses a manifest from its JSON form, tolerant of string/number drift in
  /// the numeric fields (a hand-edited manifest may quote them). Returns `null`
  /// if the required [version] or [bundle] fields are missing or unusable.
  static UpdateManifest? fromJson(Map<String, dynamic> json) {
    final version = _asInt(json['version']);
    final bundle = json['bundle'];
    if (version == null || bundle is! String || bundle.isEmpty) return null;
    return UpdateManifest(
      version: version,
      bundle: bundle,
      sha256: json['sha256'] is String ? json['sha256'] as String : '',
      channel: json['channel'] is String ? json['channel'] as String : '',
      size: _asInt(json['size']) ?? 0,
      notes: json['notes'] is String ? json['notes'] as String : '',
    );
  }

  /// Monotonic build number. A newer update has a strictly greater [version].
  final int version;

  /// The bundle file name, resolved relative to the manifest's own directory.
  final String bundle;

  /// Lowercase-hex sha256 of [bundle] (defence in depth; empty => unchecked).
  final String sha256;

  /// The channel this manifest belongs to (`experimental` / `production`).
  final String channel;

  /// Bundle size in bytes (`0` => unknown), for a download-size affordance.
  final int size;

  /// Human-readable release notes shown in the update UI (may be empty).
  final String notes;

  /// Accepts an [int], or a [String]/[num] that cleanly reads as one.
  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UpdateManifest &&
          runtimeType == other.runtimeType &&
          version == other.version &&
          bundle == other.bundle &&
          sha256 == other.sha256 &&
          channel == other.channel &&
          size == other.size &&
          notes == other.notes;

  @override
  int get hashCode =>
      Object.hash(version, bundle, sha256, channel, size, notes);

  @override
  String toString() =>
      'UpdateManifest(version: $version, bundle: $bundle, channel: $channel, '
      'size: $size)';
}
