import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/setup/setup_surface.dart';

/// The inline editor for one effect: a type dropdown and a slider per
/// parameter, plus a remove button. Purely presentational — edits are
/// callbacks.
///
/// [accentColor] tints the border, dropdown, and slider so each graph keeps its
/// own accent (the lane editor is neutral, the monitor editor is wet-blue).
class EffectParamsEditor extends StatelessWidget {
  /// Creates an effect editor.
  const EffectParamsEditor({
    required this.editorKey,
    required this.typeKey,
    required this.removeKey,
    required this.paramKey,
    required this.fx,
    required this.accentColor,
    required this.onSetType,
    required this.onSetParam,
    required this.onRemove,
    super.key,
  });

  /// Keys for the editor body and its controls (caller-supplied).
  final Key editorKey;
  final Key typeKey;
  final Key removeKey;

  /// Builds the key for parameter slider `p`.
  final Key Function(int p) paramKey;

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
    final sliderTheme = SliderThemeData(
      trackHeight: 3,
      activeTrackColor: accentColor,
      inactiveTrackColor: SetupSurfaceColors.line,
      thumbColor: accentColor,
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
    );
    return Container(
      key: editorKey,
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      decoration: BoxDecoration(
        color: SetupSurfaceColors.cardHi,
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
                  key: typeKey,
                  isExpanded: true,
                  isDense: true,
                  value: fx.type,
                  dropdownColor: SetupSurfaceColors.cardHi,
                  style: const TextStyle(
                    color: SetupSurfaceColors.t1,
                    fontSize: 14,
                  ),
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
                key: removeKey,
                iconSize: 18,
                color: SetupSurfaceColors.t2,
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
                      style: const TextStyle(
                        color: SetupSurfaceColors.t2,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SliderTheme(
                      data: sliderTheme,
                      child: Slider(
                        key: paramKey(p),
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
