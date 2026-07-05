import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/view/signal_graph/signal_style.dart';
import 'package:loopy/theme/surface_theme.dart';

/// The FX inspector's **single control type** — a labeled horizontal slider
/// with a live numeric readout. No knob, no arc glow, no blurred pointer, no
/// gradient: a plain, legible slider that reads the same whether it drives a
/// built-in DSP parameter ([FxParamControl]) or a hosted-plugin parameter
/// ([FxPluginParamControl]). Both adapters normalise their value to the
/// slider's `0..1` and feed this one primitive.
class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.controlKey,
    required this.label,
    required this.readout,
    required this.value,
    required this.onChanged,
    this.divisions,
  });

  final Key controlKey;
  final String label;
  final String readout;

  /// The slider position, `0..1`.
  final double value;

  /// The number of discrete steps, or null for a continuous slider.
  final int? divisions;

  /// Called with the new `0..1` position as the slider moves.
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: signalLabel(color: surface.textSecondary, size: 12),
              ),
            ),
            const SizedBox(width: 8),
            // The value stays mono — it is a genuine numeric readout.
            Text(
              readout,
              style: signalMono(color: surface.textPrimary, size: 11.5),
            ),
          ],
        ),
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 3,
            activeTrackColor: surface.accent,
            inactiveTrackColor: surface.line,
            thumbColor: surface.accent,
            overlayColor: surface.accent.withValues(alpha: 0.14),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 15),
            trackShape: const RoundedRectSliderTrackShape(),
          ),
          child: Slider(
            key: controlKey,
            value: value.clamp(0.0, 1.0),
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

/// A built-in effect parameter rendered as the editor's single control type.
/// The value is already normalised (`0..1`); the readout is the parameter's own
/// unit (percent, a pitch interval, or the octaver mode).
class FxParamControl extends StatelessWidget {
  /// Creates an [FxParamControl] for parameter [param] of [fx].
  const FxParamControl({
    required this.controlKey,
    required this.fx,
    required this.param,
    required this.onChanged,
    super.key,
  });

  /// A stable key on the slider surface (for tests).
  final Key controlKey;

  /// The built-in effect whose parameter this edits.
  final BuiltInEffect fx;

  /// The parameter index within [fx].
  final int param;

  /// Called with the new normalized (`0..1`) value.
  final ValueChanged<double> onChanged;

  String _readout(AppLocalizations l10n, TrackEffectParam spec, double v) {
    final c = v.clamp(0.0, 1.0);
    return switch (spec.readout) {
      ParamReadout.none => '${(c * 100).round()}%',
      ParamReadout.pitchShift => l10n.formatLocalizedPitchShift(c),
      ParamReadout.octaverMode => l10n.octaverModeLabel(c),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final spec = fx.type.params[param];
    final value = param < fx.params.length ? fx.params[param] : 0.0;
    // A mode reads as two stops even when the engine leaves divisions unset, so
    // it snaps cleanly instead of drifting across a continuous track.
    final divisions =
        spec.divisions ?? (spec.readout == ParamReadout.octaverMode ? 1 : null);
    return _LabeledSlider(
      controlKey: controlKey,
      label: l10n.effectParamLabel(spec.label),
      readout: _readout(l10n, spec, value),
      value: value,
      divisions: divisions,
      onChanged: onChanged,
    );
  }
}

/// A hosted-plugin parameter rendered as the editor's single control type. The
/// plugin reports the value in its own plain `[min, max]` range; the slider
/// works in `0..1`, so we normalise in and de-normalise out, and read out the
/// live plain value — in the plugin's own words ([onFormatValue]) when
/// available, else a bare number (with its unit) or a named step.
class FxPluginParamControl extends StatelessWidget {
  /// Creates an [FxPluginParamControl] for plugin parameter [spec].
  const FxPluginParamControl({
    required this.controlKey,
    required this.spec,
    required this.value,
    required this.onChanged,
    this.onFormatValue,
    super.key,
  });

  /// A stable key on the slider surface (for tests).
  final Key controlKey;

  /// The plugin parameter's metadata.
  final PluginParamInfo spec;

  /// The current plain value (in `[spec.min, spec.max]`).
  final double value;

  /// Called with the new plain value as the slider moves.
  final ValueChanged<double> onChanged;

  /// The plugin's own readout for a plain value, or null for a numeric one.
  final String? Function(int paramId, double value)? onFormatValue;

  double get _span => spec.max - spec.min;

  double _normalize(double plain) =>
      _span == 0 ? 0.0 : ((plain - spec.min) / _span).clamp(0.0, 1.0);

  double _denormalize(double norm) => spec.min + norm * _span;

  String _readout() {
    final fromPlugin = onFormatValue?.call(spec.id, value);
    if (fromPlugin != null && fromPlugin.isNotEmpty) return fromPlugin;
    // A stepped param reads out its plugin-supplied step name when present.
    if (spec.stepCount > 0 && spec.valueTexts.length == spec.stepCount + 1) {
      final step = (_normalize(value) * spec.stepCount).round();
      return spec.valueTexts[step.clamp(0, spec.stepCount)];
    }
    final text = spec.stepCount > 0
        ? value.round().toString()
        : value.toStringAsFixed(2);
    return spec.unit.isEmpty ? text : '$text ${spec.unit}';
  }

  @override
  Widget build(BuildContext context) {
    return _LabeledSlider(
      controlKey: controlKey,
      label: spec.name,
      readout: _readout(),
      value: _normalize(value),
      divisions: spec.stepCount > 0 ? spec.stepCount : null,
      onChanged: (norm) => onChanged(_denormalize(norm)),
    );
  }
}
