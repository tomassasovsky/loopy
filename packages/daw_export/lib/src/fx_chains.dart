import 'dart:convert';
import 'dart:io';

import 'package:daw_export/src/manifest_json.dart';

/// Effect type codes matching `loopy_engine`'s `TrackEffectType`/native
/// `le_fx_type` — reproduced here as this package's own constants (no
/// `loopy_engine` import, own-input-model rule) purely to render a
/// human-readable name; the manifest's `type` field is the only thing read.
const Map<int, String> _kBuiltInEffectNames = {
  0: 'None',
  1: 'Drive',
  2: 'Filter',
  3: 'Delay',
  4: 'Tremolo',
  5: 'Octaver',
  6: 'Echo',
  7: 'Reverb',
};

/// The `type` code a chain entry carrying a `plugin` key uses — matches
/// `loopy_engine`'s `kPluginFxCode`.
const int _kPluginTypeCode = 8;

/// `PluginRef.format`'s codes (`loopy_engine`'s `PluginFormat`) — 0 = VST3,
/// 1 = CLAP, reproduced here for the same own-input-model reason.
const Map<int, String> _kPluginFormatNames = {0: 'VST3', 1: 'CLAP'};

/// Generates `fx-chains.txt`: a human-readable summary of every track/lane's
/// effect chain — chain order, effect names, normalized params, and (for a
/// hosted plugin entry) its identity (format + id + version) plus the
/// offline-render passthrough note (D-RENDER, part 8: a hosted plugin slot
/// always renders as dry passthrough in both the dry and wet offline
/// passes, never conditionally). `performance.json` remains the canonical
/// machine-readable record of this same data — this text file is a reading
/// aid, not a second source of truth (umbrella plan: no `.als` annotation
/// mirroring).
abstract final class FxChainsWriter {
  /// Reads `<captureDir>/performance.json` and renders its FX chains as
  /// text, or `null` if the manifest is missing/unreadable/corrupt (mirrors
  /// `DawManifestReader.read`'s graceful no-op convention).
  static String? render(String captureDir) {
    final manifestFile = File('$captureDir/performance.json');
    if (!manifestFile.existsSync()) return null;
    final Map<String, dynamic> manifest;
    try {
      manifest =
          jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
    } on FormatException {
      return null;
    }

    // effects only ever appears on an armSnapshot lane entry —
    // docs/design/performance-manifest-format.md: "A disarmSnapshot lane
    // entry never carries effects — chain changes made during the
    // performance are already in events.log, not re-snapshotted." No
    // arm/disarm reconciliation is needed (or meaningful) here, unlike
    // DawManifestReader's pcmRef merge, which genuinely does need one.
    final armTracks = tracksOf(manifest['armSnapshot']);

    final effectsByChannelLane = <int, Map<int, List<dynamic>>>{};
    for (final t in armTracks) {
      final channel = (t['channel'] as num?)?.toInt();
      if (channel == null) continue;
      final laneMap = effectsByChannelLane.putIfAbsent(channel, () => {});
      for (final lane in (t['lanes'] as List<dynamic>? ?? const [])) {
        final laneJson = lane as Map<String, dynamic>;
        final laneIndex = (laneJson['lane'] as num?)?.toInt();
        if (laneIndex == null) continue;
        final effects = laneJson['effects'] as List<dynamic>?;
        if (effects == null) continue;
        laneMap[laneIndex] = effects;
      }
    }

    if (effectsByChannelLane.isEmpty) return '';

    final buffer = StringBuffer();
    for (final channel in effectsByChannelLane.keys.toList()..sort()) {
      final lanes = effectsByChannelLane[channel]!;
      for (final lane in lanes.keys.toList()..sort()) {
        buffer.writeln('Track $channel / Lane $lane:');
        final effects = lanes[lane]!;
        if (effects.isEmpty) {
          buffer.writeln('  (no effects)');
        } else {
          for (var i = 0; i < effects.length; i++) {
            final rendered = _renderEffect(
              effects[i] as Map<String, dynamic>,
            );
            buffer.writeln('  ${i + 1}. $rendered');
          }
        }
      }
    }
    return buffer.toString();
  }

  static String _renderEffect(Map<String, dynamic> effect) {
    final type = (effect['type'] as num?)?.toInt() ?? 0;
    if (type == _kPluginTypeCode) {
      final plugin = effect['plugin'] as Map<String, dynamic>?;
      final format =
          _kPluginFormatNames[(plugin?['format'] as num?)?.toInt() ?? 0] ??
          'unknown format';
      final id = (plugin?['id'] as String?) ?? 'unknown id';
      final version = (plugin?['version'] as num?)?.toInt() ?? 0;
      return 'Plugin: $format $id ${_formatVersion(version)} '
          '[rendered as dry passthrough]';
    }
    final name = _kBuiltInEffectNames[type] ?? 'Unknown ($type)';
    final params =
        (effect['params'] as List<dynamic>?)
            ?.map((p) => (p as num).toDouble().toStringAsFixed(2))
            .join(', ') ??
        '';
    return '$name (params: $params)';
  }

  static String _formatVersion(int packed) {
    if (packed == 0) return 'vunknown';
    final major = (packed >> 16) & 0xFF;
    final minor = (packed >> 8) & 0xFF;
    final patch = packed & 0xFF;
    return 'v$major.$minor.$patch';
  }
}
