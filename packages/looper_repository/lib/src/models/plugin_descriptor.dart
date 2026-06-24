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

/// One hosted-plugin parameter's metadata, unified across VST3 and CLAP into
/// plain-valued fields. Domain mirror of the engine's `PluginParamInfo`.
class PluginParamInfo extends Equatable {
  /// Creates a [PluginParamInfo].
  const PluginParamInfo({
    required this.id,
    required this.name,
    required this.unit,
    required this.min,
    required this.max,
    required this.def,
    required this.stepCount,
    required this.flags,
    this.valueTexts = const [],
  });

  /// The stable parameter id (VST3 ParamID / CLAP clap_id).
  final int id;

  /// The user-visible parameter name.
  final String name;

  /// The parameter's unit (e.g. `dB`), or an empty string.
  final String unit;

  /// The minimum plain value.
  final double min;

  /// The maximum plain value.
  final double max;

  /// The default plain value.
  final double def;

  /// Number of discrete steps: `0` is continuous, `>0` is stepped.
  final int stepCount;

  /// The raw `le_plugin_param_flags` bitmask (see the `is*` getters).
  final int flags;

  /// Whether the host may automate / set this parameter.
  bool get isAutomatable => flags & 0x01 != 0;

  /// Whether the parameter is read-only.
  bool get isReadOnly => flags & 0x02 != 0;

  /// Whether the parameter is the plugin's bypass control.
  bool get isBypass => flags & 0x04 != 0;

  /// Whether the parameter is hidden from the user.
  bool get isHidden => flags & 0x08 != 0;

  /// Whether the parameter snaps to discrete steps.
  bool get isStepped => flags & 0x10 != 0;

  /// Whether this parameter should be shown as an in-app knob: automatable and
  /// not hidden.
  bool get isUserVisible => isAutomatable && !isHidden;

  /// Whether this is an on/off (two-state) parameter — rendered as a switch.
  bool get isToggle => stepCount == 1;

  /// Whether this is a small discrete enumeration the UI can present as a
  /// dropdown of named steps (rather than a knob), i.e. it has more than two
  /// steps and the plugin gave us a label for each. A toggle ([isToggle]) is
  /// handled separately as a switch.
  bool get isEnum => stepCount >= 2 && valueTexts.length == stepCount + 1;

  /// The plugin's own display label for each discrete step, in step order
  /// (`stepCount + 1` entries) — e.g. `['Lowpass', 'Highpass', 'Bandpass']`.
  /// Empty for a continuous param or when the plugin offers no text. The
  /// repository enriches this at load time (the native `get_info` doesn't carry
  /// it), so the UI can render a switch / dropdown instead of a bare knob.
  final List<String> valueTexts;

  /// Returns a copy with [valueTexts] replaced — the repository's enrichment
  /// seam over the otherwise native-sourced fields.
  PluginParamInfo withValueTexts(List<String> valueTexts) => PluginParamInfo(
    id: id,
    name: name,
    unit: unit,
    min: min,
    max: max,
    def: def,
    stepCount: stepCount,
    flags: flags,
    valueTexts: valueTexts,
  );

  // [valueTexts] is in props so a param whose labels enumerate after load
  // compares unequal and the card re-renders into a dropdown/switch. Labels are
  // deterministic per plugin+step, so this never fires spuriously across
  // rebuilds.
  @override
  List<Object?> get props => [
    id,
    name,
    unit,
    min,
    max,
    def,
    stepCount,
    flags,
    valueTexts,
  ];
}

// --- Boundary mappers (package-internal; not exported from the barrel). ---

/// Maps an engine `PluginParamInfo` to its domain mirror.
PluginParamInfo pluginParamInfoFromEngine(engine.PluginParamInfo p) =>
    PluginParamInfo(
      id: p.id,
      name: p.name,
      unit: p.unit,
      min: p.min,
      max: p.max,
      def: p.def,
      stepCount: p.stepCount,
      flags: p.flags,
    );

/// Maps an engine `PluginFormat` to its domain mirror.
PluginFormat pluginFormatFromEngine(engine.PluginFormat format) =>
    switch (format) {
      engine.PluginFormat.vst3 => PluginFormat.vst3,
      engine.PluginFormat.clap => PluginFormat.clap,
    };

/// Maps a domain [PluginFormat] to the engine enum at the boundary.
engine.PluginFormat pluginFormatToEngine(PluginFormat format) =>
    switch (format) {
      PluginFormat.vst3 => engine.PluginFormat.vst3,
      PluginFormat.clap => engine.PluginFormat.clap,
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
