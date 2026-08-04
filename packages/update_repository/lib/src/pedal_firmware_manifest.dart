import 'package:flutter/foundation.dart';
import 'package:pub_semver/pub_semver.dart';

/// The pedal-firmware artifact published alongside an appliance bundle, as the
/// optional `pedalFirmware` block of a channel manifest.
///
/// Nested in the same manifest rather than served from its own URL: the whole
/// premise is that app and firmware move together, so one fetch and one place
/// to look beats two cadences that can disagree.
///
/// The `.hex` targets a USB-attached MCU flashed with avrdude, so it is a
/// *sibling* of the RAUC bundle, never a payload inside it — RAUC bundles are
/// OS A/B slot images and know nothing about the pedal.
@immutable
class PedalFirmwareManifest {
  /// Creates a [PedalFirmwareManifest].
  const PedalFirmwareManifest({
    required this.version,
    required this.hex,
    this.protocolVersion = 0,
    this.sha256 = '',
  });

  /// Parses the `pedalFirmware` block, or returns `null` when it is missing or
  /// unusable ([version] not parseable semver, or [hex] missing/empty).
  ///
  /// Returning `null` rather than throwing is deliberate: a malformed or
  /// future-shaped firmware block must never block the OS update that shares
  /// the manifest. The appliance simply proceeds without a firmware step.
  static PedalFirmwareManifest? fromJson(Map<String, dynamic> json) {
    final rawVersion = json['version'];
    if (rawVersion is! String) return null;
    Version version;
    try {
      version = Version.parse(rawVersion.trim());
    } on FormatException {
      return null;
    }
    final hex = json['hex'];
    if (hex is! String || hex.isEmpty) return null;
    return PedalFirmwareManifest(
      version: version,
      hex: hex,
      protocolVersion: _asInt(json['protocolVersion']) ?? 0,
      sha256: json['sha256'] is String ? json['sha256'] as String : '',
    );
  }

  /// Semantic version of the firmware build. Shares the repo-root `VERSION`
  /// with the app: "ships with the app" means one release version covers both.
  final Version version;

  /// The `.hex` file name, resolved relative to the manifest's own directory
  /// (same rule as the bundle).
  final String hex;

  /// The pedal wire-protocol version this firmware speaks (`0` => unknown).
  ///
  /// Distinct from [version]: the release version answers "is there something
  /// newer to flash", while this answers "what may segno encode at once it is
  /// flashed" — the knob `PedalRepository.firmwareProtocolVersion` gates.
  final int protocolVersion;

  /// Lowercase-hex sha256 of [hex] (defence in depth; empty => unchecked).
  ///
  /// Unlike the RAUC bundle, which carries its own X.509 signature verified
  /// against the baked-in keyring, a `.hex` has no signature of its own — so
  /// for the firmware this checksum is the only integrity check before a write
  /// that can leave the pedal unusable.
  final String sha256;

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
      other is PedalFirmwareManifest &&
          runtimeType == other.runtimeType &&
          version == other.version &&
          hex == other.hex &&
          protocolVersion == other.protocolVersion &&
          sha256 == other.sha256;

  @override
  int get hashCode => Object.hash(version, hex, protocolVersion, sha256);

  @override
  String toString() =>
      'PedalFirmwareManifest(version: $version, hex: $hex, '
      'protocolVersion: $protocolVersion)';
}
