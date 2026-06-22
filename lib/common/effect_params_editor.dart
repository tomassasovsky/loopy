import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/surface_theme.dart';

/// The inline editor for one effect: a type dropdown and a slider per
/// parameter, plus a remove button. Purely presentational — edits are
/// callbacks.
///
/// [accentColor] tints the border, dropdown, and slider so each graph keeps its
/// own accent (the lane editor is neutral, the monitor editor is wet-blue).
/// Keys derive from [keyPrefix] (`laneGraph` / `monitorGraph`).
class EffectParamsEditor extends StatelessWidget {
  /// Creates an effect editor.
  const EffectParamsEditor({
    required this.keyPrefix,
    required this.fx,
    required this.accentColor,
    required this.onSetType,
    required this.onSetParam,
    required this.onRemove,
    this.addedLatencyMs = 0,
    super.key,
  });

  /// The graph's selector namespace, e.g. `laneGraph` or `monitorGraph`.
  final String keyPrefix;

  /// The effect being edited.
  final TrackEffect fx;

  /// The engine's reported added latency in milliseconds (from the snapshot).
  /// Used only to display the phase-vocoder monitoring-lag hint; `0` suppresses
  /// it (e.g. the engine is stopped or no octaver is engaged).
  final double addedLatencyMs;

  /// Whether [fx] is an octaver currently in phase-vocoder mode — the
  /// high-latency algorithm the hint steers performers away from for live
  /// monitoring. The mode parameter is found by its [ParamReadout] so it stays
  /// correct if the parameter order ever changes; `< 0.5` is the phase vocoder,
  /// `>= 0.5` PSOLA.
  bool get _isPhaseVocoderOctaver {
    if (fx.type != TrackEffectType.octaver) return false;
    final params = fx.type.params;
    for (var p = 0; p < params.length && p < fx.params.length; p++) {
      if (params[p].readout == ParamReadout.octaverMode) {
        return fx.params[p] < 0.5;
      }
    }
    return false;
  }

  /// The editor's accent colour.
  final Color accentColor;

  /// Edit callbacks.
  final ValueChanged<TrackEffectType> onSetType;
  final void Function(int param, double value) onSetParam;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final sliderTheme = SliderThemeData(
      trackHeight: 3,
      activeTrackColor: accentColor,
      inactiveTrackColor: surface.line,
      thumbColor: accentColor,
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
    );
    return Container(
      key: Key('${keyPrefix}_fxEditor'),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      decoration: BoxDecoration(
        color: surface.cardHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accentColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  label: l10n.a11yEffectType,
                  container: true,
                  child: DropdownButton<TrackEffectType>(
                    key: Key('${keyPrefix}_fxType'),
                    isExpanded: true,
                    isDense: true,
                    value: fx.type,
                    dropdownColor: surface.cardHigh,
                    style: TextStyle(color: surface.textPrimary, fontSize: 14),
                    onChanged: (type) {
                      if (type != null && type != TrackEffectType.none) {
                        onSetType(type);
                      }
                    },
                    items: [
                      for (final type in TrackEffectType.values)
                        if (type != TrackEffectType.none)
                          DropdownMenuItem(
                            value: type,
                            child: Text(l10n.effectTypeLabel(type)),
                          ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: Key('${keyPrefix}_fxRemove'),
                iconSize: 18,
                color: surface.textSecondary,
                tooltip: l10n.removeEffectTooltip,
                icon: const Icon(Icons.delete_outline),
                onPressed: onRemove,
              ),
            ],
          ),
          for (var p = 0; p < fx.type.params.length; p++)
            _ParamRow(
              keyPrefix: keyPrefix,
              index: p,
              spec: fx.type.params[p],
              value: fx.params[p],
              sliderTheme: sliderTheme,
              onChanged: (v) => onSetParam(p, v),
            ),
          // Two independent gates: [_isPhaseVocoderOctaver] is the per-editor
          // check that *this* effect is the high-latency mode, while
          // [addedLatencyMs] (> 0) is the engine-wide report that an octaver is
          // actually engaged and adding lag. Both must hold, so the hint never
          // shows for a PSOLA octaver or while the engine reports no latency.
          if (_isPhaseVocoderOctaver && addedLatencyMs > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 14,
                    color: surface.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      key: Key('${keyPrefix}_octaverLatencyHint'),
                      l10n.octaverLatencyHint(
                        addedLatencyMs.toStringAsFixed(0),
                      ),
                      style: TextStyle(
                        color: surface.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One labelled parameter control. A continuous slider by default; when the
/// [spec] declares discrete steps the slider snaps to them, and when it
/// declares a [ParamReadout] the value's unit reading is shown both while
/// dragging and in a trailing readout (so a musical parameter like pitch reads
/// in its own units).
class _ParamRow extends StatelessWidget {
  const _ParamRow({
    required this.keyPrefix,
    required this.index,
    required this.spec,
    required this.value,
    required this.sliderTheme,
    required this.onChanged,
  });

  final String keyPrefix;
  final int index;
  final TrackEffectParam spec;
  final double value;
  final SliderThemeData sliderTheme;
  final ValueChanged<double> onChanged;

  String? _readout(AppLocalizations l10n, double clamped) =>
      switch (spec.readout) {
        ParamReadout.none => null,
        ParamReadout.pitchShift => l10n.formatLocalizedPitchShift(clamped),
        ParamReadout.octaverMode => l10n.octaverModeLabel(clamped),
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final clamped = value.clamp(0.0, 1.0);
    final readout = _readout(l10n, clamped);
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              l10n.effectParamLabel(spec.label),
              style: TextStyle(color: surface.textSecondary, fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SliderTheme(
              data: sliderTheme,
              child: Semantics(
                label: l10n.effectParamLabel(spec.label),
                child: Slider(
                  key: Key('${keyPrefix}_fxParam$index'),
                  value: clamped,
                  divisions: spec.divisions,
                  label: readout,
                  onChanged: onChanged,
                ),
              ),
            ),
          ),
          if (readout != null) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 56,
              child: Text(
                readout,
                textAlign: TextAlign.end,
                style: TextStyle(color: surface.textPrimary, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
