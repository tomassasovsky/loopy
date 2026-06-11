import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
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
    super.key,
  });

  /// The graph's selector namespace, e.g. `laneGraph` or `monitorGraph`.
  final String keyPrefix;

  /// The effect being edited.
  final TrackEffect fx;

  /// The editor's accent colour.
  final Color accentColor;

  /// Edit callbacks.
  final ValueChanged<TrackEffectType> onSetType;
  final void Function(int param, double value) onSetParam;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
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
                        DropdownMenuItem(value: type, child: Text(type.label)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: Key('${keyPrefix}_fxRemove'),
                iconSize: 18,
                color: surface.textSecondary,
                tooltip: 'Remove effect',
                icon: const Icon(Icons.delete_outline),
                onPressed: onRemove,
              ),
            ],
          ),
          for (var p = 0; p < fx.type.paramLabels.length; p++)
            SizedBox(
              height: 38,
              child: Row(
                children: [
                  SizedBox(
                    width: 64,
                    child: Text(
                      fx.type.paramLabels[p],
                      style: TextStyle(
                        color: surface.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SliderTheme(
                      data: sliderTheme,
                      child: Slider(
                        key: Key('${keyPrefix}_fxParam$p'),
                        value: fx.params[p].clamp(0.0, 1.0),
                        onChanged: (v) => onSetParam(p, v),
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
