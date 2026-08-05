import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/signal_graph/signal_style.dart';
import 'package:segno/theme/theme.dart';

/// The full-width editor for one plugin parameter, raised from the bottom edge
/// over a scrim when a tile is tapped (`DS / 06 FX parameter — spec`).
///
/// The tile grid is the overview; this is the same design at the other zoom
/// level. Its whole reason for existing is **travel**: a 78px tile gave a knob
/// ~36px to cover a parameter's full range, and the rejected alternatives
/// (vertical faders at 44px, mini bars at 76px) lost on that same axis. The
/// track here spans the panel, so a drag resolves the range far more finely
/// than any in-grid control could.
///
/// The extra tap is affordable *here specifically* because this is a looper
/// with a foot pedal: live mid-take control belongs to the pedal, so the
/// screen's job is setup and overview rather than performance.
class FxParamEditSheet extends StatefulWidget {
  /// Creates an [FxParamEditSheet].
  const FxParamEditSheet({
    required this.spec,
    required this.value,
    required this.source,
    required this.onChanged,
    this.formatValue,
    super.key,
  });

  /// The parameter being edited.
  final PluginParamInfo spec;

  /// The plain value the sheet opens with. Cancel restores exactly this.
  final double value;

  /// Breadcrumb under the name — "Dirty rhythm · track 3 · lane A · VST3".
  final String source;

  /// Called as the value moves, and with the opening value again on cancel, so
  /// the audio follows the drag live rather than jumping on commit.
  final ValueChanged<double> onChanged;

  /// The plugin's own rendering of a plain value, or null for a numeric one.
  final String? Function(double value)? formatValue;

  /// Opens the sheet for [spec] and resolves once it closes.
  ///
  /// Returns the committed plain value, or null if the edit was cancelled —
  /// the caller does not need it to restore, since [onChanged] has already been
  /// called with the opening value by then.
  static Future<double?> show(
    BuildContext context, {
    required PluginParamInfo spec,
    required double value,
    required String source,
    required ValueChanged<double> onChanged,
    String? Function(double value)? formatValue,
  }) {
    return showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: context.surface.scrim,
      builder: (_) => FxParamEditSheet(
        spec: spec,
        value: value,
        source: source,
        onChanged: onChanged,
        formatValue: formatValue,
      ),
    );
  }

  @override
  State<FxParamEditSheet> createState() => _FxParamEditSheetState();
}

class _FxParamEditSheetState extends State<FxParamEditSheet> {
  /// The value the sheet opened with — what Cancel restores.
  late final double _opening = widget.value;
  late double _value = widget.value;

  double get _span => widget.spec.max - widget.spec.min;

  double get _fraction =>
      _span == 0 ? 0 : ((_value - widget.spec.min) / _span).clamp(0.0, 1.0);

  /// The plain value at `0..1` position [fraction], snapped to the parameter's
  /// steps when it has them — a stepped parameter must not land between its
  /// own steps just because a finger did.
  double _plainAt(double fraction) {
    final clamped = fraction.clamp(0.0, 1.0);
    if (widget.spec.stepCount > 0) {
      final step = (clamped * widget.spec.stepCount).round();
      return widget.spec.min + _span * step / widget.spec.stepCount;
    }
    return widget.spec.min + _span * clamped;
  }

  void _setFromFraction(double fraction) {
    final next = _plainAt(fraction);
    if (next == _value) return;
    setState(() => _value = next);
    widget.onChanged(next);
  }

  void _cancel() {
    widget.onChanged(_opening);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final fromPlugin = widget.formatValue?.call(_value);
    final hasText = fromPlugin != null && fromPlugin.isNotEmpty;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(17)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.spec.name,
                key: const Key('fxParamSheet_name'),
                style: signalLabel(
                  color: surface.textPrimary,
                  size: 20,
                  weight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.source,
                style: signalLabel(color: surface.textMuted, size: 14),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    hasText
                        ? fromPlugin
                        : _value.toStringAsFixed(
                            widget.spec.stepCount > 0 ? 0 : 2,
                          ),
                    key: const Key('fxParamSheet_value'),
                    style: signalMono(color: surface.textPrimary, size: 34),
                  ),
                  if (!hasText && widget.spec.unit.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      widget.spec.unit,
                      style: signalMono(color: surface.textMuted, size: 16),
                    ),
                  ],
                  const Spacer(),
                  TextButton(
                    key: const Key('fxParamSheet_reset'),
                    onPressed: () => _setFromFraction(
                      _span == 0
                          ? 0
                          : (widget.spec.def - widget.spec.min) / _span,
                    ),
                    child: Text(l10n.fxParamResetLabel),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _FxParamTrack(
                key: const Key('fxParamSheet_track'),
                fraction: _fraction,
                onMoved: _setFromFraction,
                semanticLabel: widget.spec.name,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const Key('fxParamSheet_cancel'),
                    onPressed: _cancel,
                    child: Text(l10n.cancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('fxParamSheet_set'),
                    onPressed: () => Navigator.of(context).pop(_value),
                    child: Text(l10n.fxParamSetLabel),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The 64px drag track. A press anywhere on it moves the value there — the
/// whole bar is the handle, which is the point of the sheet.
class _FxParamTrack extends StatelessWidget {
  const _FxParamTrack({
    required this.fraction,
    required this.onMoved,
    required this.semanticLabel,
    super.key,
  });

  final double fraction;
  final ValueChanged<double> onMoved;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return LayoutBuilder(
      builder: (context, constraints) {
        void moveTo(Offset local) => onMoved(
          local.dx / constraints.maxWidth.clamp(1.0, double.infinity),
        );

        return Semantics(
          slider: true,
          label: semanticLabel,
          value: '${(fraction * 100).round()}%',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => moveTo(d.localPosition),
            onHorizontalDragUpdate: (d) => moveTo(d.localPosition),
            child: SizedBox(
              height: 64,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: surface.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: fraction.clamp(0.0, 1.0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: surface.accentSurface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
