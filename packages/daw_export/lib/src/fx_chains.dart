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

/// Trailing note appended whenever a Track or Master section was written, so
/// nobody reads a bus chain here and assumes it is in the audio (R20).
const String _kBusStageNote =
    'Note: Track (bus) and Master chains are recorded in the manifest only. '
    'They are not\nrendered into any stem and are not emitted as devices in '
    'the .als — only the per-lane\nLoop chains above are.';

/// Generates `fx-chains.txt`: a human-readable summary of every FX stage a
/// capture recorded — chain order, effect names, normalized params, per-slot
/// and per-chain bypass, and (for a hosted plugin entry) its identity
/// (format + id + version) plus the offline-render passthrough note
/// (D-RENDER, part 8: a hosted plugin slot always renders as dry passthrough
/// in both the dry and wet offline passes, never conditionally).
/// `performance.json` remains the canonical machine-readable record of this
/// same data — this text file is a reading aid, not a second source of truth
/// (umbrella plan: no `.als` annotation mirroring).
///
/// FX v3 (R20) widened what there is to summarize. Of the capture's four
/// stages this file reports **three**: the per-lane **Loop** sections first,
/// then each channel's **Track** bus chain, then the **Master** insert. Only
/// the Loop stage is rendered into audio (`perf_render`'s wet pass) or into a
/// `.als` device chain (`manifest_reader.dart`); the two bus stages are
/// manifest-only and are never baked into a stem, which is exactly why
/// summarizing them here matters — otherwise they would be invisible to
/// everyone reading an export. A trailing note says so in the file itself, so
/// the text is not mistaken for a description of what the stems contain.
///
/// The **Input** stage (`monitors[]`) is deliberately NOT summarized: a
/// monitor chain is heard live and never recorded, so it describes no audio
/// the capture contains — unlike the bus stages, which color the mix the
/// stems came from. Read it from `performance.json` directly if you need it.
abstract final class FxChainsWriter {
  /// Reads `<captureDir>/performance.json` and renders its FX chains as
  /// text, or `null` if the manifest is missing/unreadable/corrupt (mirrors
  /// `DawManifestReader.read`'s graceful no-op convention).
  ///
  /// Returns the empty string for a capture with nothing to report — no
  /// chain on any stage. Parsing is presence-keyed: a legacy (pre-FX-v3)
  /// manifest simply has no bus-stage fields and no bypass flags, so it
  /// renders the per-lane sections it always did, unchanged.
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
    // performance are already in events.log, not re-snapshotted." The same
    // holds for chainEnabled, and for every bus-stage field below: the arm
    // snapshot is the only stage-bearing snapshot. No arm/disarm
    // reconciliation is needed (or meaningful) here, unlike
    // DawManifestReader's pcmRef merge, which genuinely does need one.
    final armSnapshot = manifest['armSnapshot'];
    final armTracks = tracksOf(armSnapshot);

    final lanesByChannel = <int, Map<int, Map<String, dynamic>>>{};
    for (final t in armTracks) {
      final channel = (t['channel'] as num?)?.toInt();
      if (channel == null) continue;
      final laneMap = lanesByChannel.putIfAbsent(channel, () => {});
      for (final lane in (t['lanes'] as List<dynamic>? ?? const [])) {
        final laneJson = lane as Map<String, dynamic>;
        final laneIndex = (laneJson['lane'] as num?)?.toInt();
        if (laneIndex == null) continue;
        // A lane with no `effects` key at all has nothing to report and is
        // omitted entirely — distinct from `effects: []`, which is a real
        // "this lane's chain is empty" statement and renders as such.
        if (laneJson['effects'] is! List) continue;
        laneMap[laneIndex] = laneJson;
      }
    }

    final trackChains = trackChainsOf(armSnapshot);
    final masterEffects = masterEffectsOf(armSnapshot);
    // The Master insert has no record of its own to be present or absent, so
    // "is there a Master section" is the presence of either field: entries,
    // or a bypass flag written (only ever written when false).
    final hasMasterSection =
        masterEffects.isNotEmpty ||
        (armSnapshot is Map<String, dynamic> &&
            armSnapshot.containsKey('masterChainEnabled'));

    final buffer = StringBuffer();
    for (final channel in lanesByChannel.keys.toList()..sort()) {
      final lanes = lanesByChannel[channel]!;
      for (final lane in lanes.keys.toList()..sort()) {
        final laneJson = lanes[lane]!;
        _writeSection(
          buffer,
          heading: 'Track $channel / Lane $lane',
          chainEnabled: chainEnabledOf(laneJson),
          effects: effectsOf(laneJson),
        );
      }
    }

    // Tracked rather than inferred from `trackChains.isNotEmpty`: an entry
    // with no `channel` is skipped, so a malformed `trackChains` can be
    // non-empty and still write no section — and a trailing note disclaiming
    // sections that aren't there would be its own small lie.
    var wroteBusSection = false;
    for (final chain in trackChains) {
      final channel = (chain['channel'] as num?)?.toInt();
      if (channel == null) continue;
      _writeSection(
        buffer,
        heading: 'Track $channel / Bus',
        chainEnabled: chainEnabledOf(chain),
        effects: effectsOf(chain),
      );
      wroteBusSection = true;
    }

    if (hasMasterSection) {
      _writeSection(
        buffer,
        heading: 'Master',
        chainEnabled: chainEnabledOf(
          armSnapshot as Map<String, dynamic>,
          key: 'masterChainEnabled',
        ),
        effects: masterEffects,
      );
    }

    if (buffer.isEmpty) return '';
    if (wroteBusSection || hasMasterSection) {
      buffer
        ..writeln()
        ..writeln(_kBusStageNote);
    }
    return buffer.toString();
  }

  /// Writes one stage section: a heading (suffixed when the whole chain is
  /// bypassed), then its entries in order, or an explicit `(no effects)`.
  static void _writeSection(
    StringBuffer buffer, {
    required String heading,
    required bool chainEnabled,
    required List<Map<String, dynamic>> effects,
  }) {
    buffer.writeln('$heading${chainEnabled ? '' : ' [chain bypassed]'}:');
    if (effects.isEmpty) {
      buffer.writeln('  (no effects)');
      return;
    }
    for (var i = 0; i < effects.length; i++) {
      buffer.writeln('  ${i + 1}. ${_renderEffect(effects[i])}');
    }
  }

  static String _renderEffect(Map<String, dynamic> effect) {
    final suffix = effectEnabledOf(effect) ? '' : ' [bypassed]';
    return '${_renderEffectBody(effect)}$suffix';
  }

  static String _renderEffectBody(Map<String, dynamic> effect) {
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
