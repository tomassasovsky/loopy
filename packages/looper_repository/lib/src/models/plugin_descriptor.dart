import 'package:equatable/equatable.dart';
import 'package:loopy_engine/loopy_engine.dart' as engine;

/// The format a hosted plugin was discovered in. Domain mirror of the engine's
/// `PluginFormat`.
enum PluginFormat {
  /// Steinberg VST3.
  vst3,

  /// CLAP (CLever Audio Plugin).
  clap,
}

/// A plugin class discovered by the [engine]-backed scan. Domain mirror of the
/// engine's `PluginDescriptor`.
///
/// A descriptor whose [id] is empty is a *failed* entry — a candidate file that
/// could not be loaded or described — kept so a single broken plugin does not
/// erase the rest of the scan (see [isAvailable]).
class PluginDescriptor extends Equatable {
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

  /// The version as a `major.minor.patch` string (e.g. `1.2.0`).
  String get versionLabel =>
      '${(version >> 16) & 0xff}.${(version >> 8) & 0xff}.${version & 0xff}';

  @override
  List<Object?> get props => [id, name, vendor, path, format, version];
}

// --- Boundary mappers (package-internal; not exported from the barrel). ---

/// Maps an engine `PluginFormat` to its domain mirror.
PluginFormat pluginFormatFromEngine(engine.PluginFormat format) =>
    switch (format) {
      engine.PluginFormat.vst3 => PluginFormat.vst3,
      engine.PluginFormat.clap => PluginFormat.clap,
    };

/// Maps an engine `PluginDescriptor` to its domain mirror.
PluginDescriptor pluginDescriptorFromEngine(engine.PluginDescriptor d) =>
    PluginDescriptor(
      id: d.id,
      name: d.name,
      vendor: d.vendor,
      path: d.path,
      format: pluginFormatFromEngine(d.format),
      version: d.version,
    );
