import 'package:flutter/foundation.dart';

/// An opaque handle to a plugin loaded into a lane / monitor FX chain slot.
///
/// Returned by `AudioEngine.setLanePlugin` / `setMonitorPlugin`, it is a token
/// the caller holds to address that slot in later operations (parameters,
/// editor window — added in later slices). It carries no public surface here.
abstract interface class PluginSlotHandle {}

/// The format a hosted plugin was discovered in. Mirrors the native
/// `le_plugin_format` enum.
enum PluginFormat {
  /// Steinberg VST3.
  vst3,

  /// CLAP (CLever Audio Plugin).
  clap;

  /// Maps a native `le_plugin_format` integer to a [PluginFormat]. Unknown
  /// values fall back to [PluginFormat.vst3].
  static PluginFormat fromCode(int code) => switch (code) {
    0 => PluginFormat.vst3,
    1 => PluginFormat.clap,
    _ => PluginFormat.vst3,
  };

  /// The native `le_plugin_format` integer for this format.
  int get code => switch (this) {
    PluginFormat.vst3 => 0,
    PluginFormat.clap => 1,
  };
}

/// One plugin class discovered by `AudioEngine.scan*`.
///
/// The pure-Dart projection of the native `le_plugin_desc` struct. A descriptor
/// whose [id] is empty is a *failed* entry — a candidate file that could not be
/// loaded or described — surfaced so a single broken plugin does not erase the
/// rest of the scan (see [isAvailable]).
@immutable
class PluginDescriptor {
  /// Creates a [PluginDescriptor].
  const PluginDescriptor({
    required this.id,
    required this.name,
    required this.vendor,
    required this.path,
    required this.format,
    required this.version,
  });

  /// The stable plugin identity — a VST3 TUID (32 hex chars) or a CLAP
  /// descriptor id. Empty for a failed-to-scan entry.
  final String id;

  /// The user-visible plugin name (the offending file's name for a failed
  /// entry).
  final String name;

  /// The plugin vendor, or an empty string when unknown.
  final String vendor;

  /// The `.vst3` bundle / `.clap` file the class was found in.
  final String path;

  /// The plugin format.
  final PluginFormat format;

  /// Packed version `major << 16 | minor << 8 | patch`, or `0` when unknown.
  final int version;

  /// Whether this descriptor is a real, loadable plugin rather than a
  /// failed-to-scan placeholder.
  bool get isAvailable => id.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PluginDescriptor &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          vendor == other.vendor &&
          path == other.path &&
          format == other.format &&
          version == other.version;

  @override
  int get hashCode => Object.hash(id, name, vendor, path, format, version);

  @override
  String toString() =>
      'PluginDescriptor(${format.name}, id: $id, name: $name, path: $path)';
}

/// A snapshot of an in-progress (or finished) plugin scan, from
/// `AudioEngine.scanPoll`.
@immutable
class PluginScanProgress {
  /// Creates a [PluginScanProgress].
  const PluginScanProgress({
    required this.done,
    required this.found,
    required this.scanned,
    required this.total,
  });

  /// A finished scan that found nothing.
  static const PluginScanProgress empty = PluginScanProgress(
    done: true,
    found: 0,
    scanned: 0,
    total: 0,
  );

  /// Whether the scan thread has finished (or was cancelled).
  final bool done;

  /// The number of descriptors currently retrievable (includes failed entries).
  final int found;

  /// Candidate files processed so far.
  final int scanned;

  /// Candidate files discovered.
  final int total;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PluginScanProgress &&
          runtimeType == other.runtimeType &&
          done == other.done &&
          found == other.found &&
          scanned == other.scanned &&
          total == other.total;

  @override
  int get hashCode => Object.hash(done, found, scanned, total);

  @override
  String toString() =>
      'PluginScanProgress(done: $done, found: $found, '
      'scanned: $scanned, total: $total)';
}
