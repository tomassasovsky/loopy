import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/view/signal_graph/signal_style.dart';
import 'package:segno/theme/theme.dart';

/// Geometry of the FX parameter grid, from `DS / 06 FX parameter — spec`.
///
/// Every parameter kind — continuous, switch, enum, read-only — wears the same
/// skeleton, so a dense strip reads as one grid rather than a row of unlike
/// controls. The tile is an **overview**, never the live surface: it commits
/// nothing on touch, it opens the editor sheet. Mid-take control belongs to the
/// foot pedal, so no drag on this screen can change audio by accident.
abstract final class FxParamTileMetrics {
  /// Tile width. 78 on a [gutter] of 7 fills a 1738px panel at 20 columns.
  static const double width = 78;

  /// Space between tiles, horizontally and between rows.
  static const double gutter = 7;

  /// The value box — the only part that differs between kinds.
  static const double boxHeight = 36;

  /// The value-position readout under the box. A readout, not a handle.
  static const double indicatorHeight = 3;

  /// Name + box + indicator, with the two 5px gaps between them.
  static const double height = 59;

  static const double _gap = 5;
  static const double _boxRadius = 7;
}

/// The shared name / control / indicator skeleton every parameter cell wears.
///
/// Nothing here states in words what the control already shows — a switch's
/// position is its value, and the indicator carries an enum's step.
class _FxParamCell extends StatelessWidget {
  const _FxParamCell({
    required this.name,
    required this.control,
    required this.fill,
  });

  /// The parameter's name. Ellipsizes at roughly ten characters; the full name
  /// is in the sheet header, which is where you are when you need to read it.
  final String name;

  /// The 36px control body.
  final Widget control;

  /// Indicator fill in `0..1`, or null for a cell with no position to report.
  final double? fill;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return SizedBox(
      width: FxParamTileMetrics.width,
      height: FxParamTileMetrics.height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            // Uppercased for the same reason the DS specimens are, and the
            // rotary caption was before it: at mono 9 in 78px this is a legend,
            // and caps keep a dense grid's names scanning as one row.
            name.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: signalMono(color: surface.textSecondary, size: 9),
          ),
          const SizedBox(height: FxParamTileMetrics._gap),
          SizedBox(height: FxParamTileMetrics.boxHeight, child: control),
          const SizedBox(height: FxParamTileMetrics._gap),
          _FxParamIndicator(fill: fill),
        ],
      ),
    );
  }
}

/// The 3px value-position bar under a cell.
class _FxParamIndicator extends StatelessWidget {
  const _FxParamIndicator({required this.fill});

  final double? fill;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return SizedBox(
      height: FxParamTileMetrics.indicatorHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: surface.borderStrong,
          borderRadius: BorderRadius.circular(999),
        ),
        child: fill == null
            ? null
            : FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: fill!.clamp(0.0, 1.0),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: surface.accent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
      ),
    );
  }
}

/// The boxed value readout shared by the continuous tile and the enum cell.
class _FxParamBox extends StatelessWidget {
  const _FxParamBox({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.surface.cardHigh,
        borderRadius: BorderRadius.circular(FxParamTileMetrics._boxRadius),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

/// A continuous or many-stepped plugin parameter: name, its value in the
/// plugin's own words, and a position indicator. Tapping opens the editor
/// sheet — [onTap] is null for a read-only parameter, which reports a value but
/// takes none (meters land here).
class FxParamTile extends StatelessWidget {
  /// Creates an [FxParamTile].
  const FxParamTile({
    required this.spec,
    required this.value,
    required this.valueText,
    required this.onTap,
    super.key,
  });

  /// The parameter this tile reports.
  final PluginParamInfo spec;

  /// The current plain value, in `[spec.min, spec.max]`.
  final double value;

  /// The plugin's own rendering of [value] ("-6.0 dB"), or null when it offers
  /// none — the tile then falls back to the number plus [PluginParamInfo.unit].
  final String? valueText;

  /// Opens the editor sheet. Null for a read-only parameter.
  final VoidCallback? onTap;

  /// [value] as a `0..1` position within the parameter's range.
  double get _fraction {
    final span = spec.max - spec.min;
    if (span == 0) return 0;
    return ((value - spec.min) / span).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    // The plugin hands value and unit over as one preformatted string, so they
    // live together in the box. Splitting them would mean parsing the plugin's
    // own formatting apart. Only the fallback path has a separate unit.
    final fromPlugin = valueText != null && valueText!.isNotEmpty;
    final text = fromPlugin
        ? valueText!
        : (spec.stepCount > 0
              ? value.round().toString()
              : value.toStringAsFixed(2));

    final cell = _FxParamCell(
      name: spec.name,
      fill: _fraction,
      control: _FxParamBox(
        children: [
          Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: signalMono(color: surface.textPrimary, size: 10),
          ),
          if (!fromPlugin && spec.unit.isNotEmpty)
            Text(
              spec.unit,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: signalMono(color: surface.textTertiary, size: 9),
            ),
        ],
      ),
    );

    if (onTap == null) return Semantics(readOnly: true, child: cell);
    return Semantics(
      button: true,
      label: spec.name,
      value: text,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(FxParamTileMetrics._boxRadius),
        child: cell,
      ),
    );
  }
}

/// A two-state plugin parameter (`stepCount == 1`). The switch's position is
/// its value, so the cell carries no caption — the DS drops the redundant line
/// the old control had.
class FxParamSwitchCell extends StatelessWidget {
  /// Creates an [FxParamSwitchCell].
  const FxParamSwitchCell({
    required this.spec,
    required this.value,
    required this.onChanged,
    super.key,
  });

  /// The parameter this cell drives.
  final PluginParamInfo spec;

  /// The current plain value.
  final double value;

  /// Called with the new plain value — [PluginParamInfo.max] or `min`.
  final ValueChanged<double> onChanged;

  /// A plain value reads as on from the midpoint up.
  bool get _on => value >= (spec.min + spec.max) / 2;

  @override
  Widget build(BuildContext context) {
    return _FxParamCell(
      name: spec.name,
      fill: _on ? 1 : 0,
      control: Center(
        child: Semantics(
          label: spec.name,
          child: Switch(
            value: _on,
            onChanged: (on) => onChanged(on ? spec.max : spec.min),
          ),
        ),
      ),
    );
  }
}

/// A small named-step parameter (`2 <= stepCount <= 24`) as a menu of the
/// plugin's own step labels. The indicator carries the step, so the cell shows
/// no separate caption.
class FxParamEnumCell extends StatelessWidget {
  /// Creates an [FxParamEnumCell].
  const FxParamEnumCell({
    required this.spec,
    required this.value,
    required this.onChanged,
    super.key,
  });

  /// The parameter this cell drives.
  final PluginParamInfo spec;

  /// The current plain value.
  final double value;

  /// Called with the plain value of the chosen step.
  final ValueChanged<double> onChanged;

  /// The step index nearest [value], in `0..spec.stepCount`.
  int get _step {
    final span = spec.max - spec.min;
    if (span == 0) return 0;
    final norm = ((value - spec.min) / span).clamp(0.0, 1.0);
    return (norm * spec.stepCount).round();
  }

  double _plainFor(int step) =>
      spec.min + (spec.max - spec.min) * step / spec.stepCount;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final step = _step;
    final label = step < spec.valueTexts.length
        ? spec.valueTexts[step]
        : step.toString();

    return _FxParamCell(
      name: spec.name,
      fill: spec.stepCount == 0 ? 0 : step / spec.stepCount,
      control: PopupMenuButton<int>(
        tooltip: spec.name,
        padding: EdgeInsets.zero,
        initialValue: step,
        onSelected: (s) => onChanged(_plainFor(s)),
        itemBuilder: (context) => [
          for (var s = 0; s <= spec.stepCount; s++)
            PopupMenuItem<int>(
              value: s,
              child: Text(
                s < spec.valueTexts.length ? spec.valueTexts[s] : '$s',
                style: signalMono(color: surface.textPrimary),
              ),
            ),
        ],
        child: _FxParamBox(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: signalMono(color: surface.textPrimary, size: 9),
                  ),
                ),
                const SizedBox(width: 2),
                Text(
                  '▾',
                  style: signalMono(color: surface.textMuted, size: 9),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
