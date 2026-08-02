import 'package:flutter/foundation.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:update_repository/src/pedal_firmware_manifest.dart';

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
    this.pedalFirmware,
  });

  /// Parses a manifest from its JSON form, tolerant of size-field string/number
  /// drift (a hand-edited manifest may quote it). Returns `null` if [version]
  /// isn't a parseable semver string or [bundle] is missing/empty.
  static UpdateManifest? fromJson(Map<String, dynamic> json) {
    final rawVersion = json['version'];
    if (rawVersion is! String) return null;
    Version version;
    try {
      version = Version.parse(rawVersion.trim());
    } on FormatException {
      return null;
    }
    final bundle = json['bundle'];
    if (bundle is! String || bundle.isEmpty) return null;
    return UpdateManifest(
      version: version,
      bundle: bundle,
      sha256: json['sha256'] is String ? json['sha256'] as String : '',
      channel: json['channel'] is String ? json['channel'] as String : '',
      size: _asInt(json['size']) ?? 0,
      notes: json['notes'] is String ? json['notes'] as String : '',
      pedalFirmware: switch (json['pedalFirmware']) {
        final Map<String, dynamic> block => PedalFirmwareManifest.fromJson(
          block,
        ),
        _ => null,
      },
    );
  }

  /// Semantic version. A newer update has a strictly greater [version], per
  /// semver precedence (so an unsuffixed `1.2.0` outranks its own
  /// `1.2.0-experimental.7` prerelease).
  final Version version;

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

  /// The pedal firmware published with this release, or `null` when this
  /// release ships none (every manifest before the firmware artifact existed,
  /// and any release whose firmware block failed to parse).
  ///
  /// Optional by construction: the OS update must stay installable on a
  /// manifest with no firmware block, so nothing here may become required.
  final PedalFirmwareManifest? pedalFirmware;

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
          notes == other.notes &&
          pedalFirmware == other.pedalFirmware;

  @override
  int get hashCode =>
      Object.hash(version, bundle, sha256, channel, size, notes, pedalFirmware);

  @override
  String toString() =>
      'UpdateManifest(version: $version, bundle: $bundle, channel: $channel, '
      'size: $size)';
}
