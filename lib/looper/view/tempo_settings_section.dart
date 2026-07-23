import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/cubit/tempo_cubit.dart';
import 'package:loopy/setup/setup_surface.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;

/// The click's own gain-stage ceiling — matches the engine's `LE_MAX_GAIN`
/// (2.0, +6.02 dB headroom above unity), the same ceiling every other volume
/// control in the app (lane/monitor) uses.
const double _kMaxClickGain = 2;

/// The looper feature's own tempo settings surface (index plan's UI
/// conventions: tempo/click/quantize/count-in controls live here, not in
/// `audio_setup`, which stays device/routing-oriented): BPM + tap tempo, the
/// 17 Sheeran-verified time signatures, loop↔grid sync, musical
/// quantization granularity, click mode/output/volume, and count-in
/// measures.
///
/// Every live value below (current BPM/source, time signature, click mode,
/// …) is read from [LooperBloc]'s [TransportState] rather than
/// [TempoCubit]'s own cached state — A4b already live-projects every one of
/// these fields onto the transport on each snapshot poll. Reading the
/// transport means a controller/pedal-driven change (tap tempo, the
/// metronome toggle, a loop-derived tempo) shows up immediately with no
/// second cache to keep in sync; [TempoCubit] is used only to mutate and
/// persist.
class TempoSettingsSection extends StatelessWidget {
  /// Creates a [TempoSettingsSection].
  const TempoSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final looperState = context.watch<LooperBloc>().state;
    final transport = looperState.transport;
    final outputChannelCount = looperState.status.outputChannels > 0
        ? looperState.status.outputChannels
        : 2;
    final cubit = context.read<TempoCubit>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.tempoSettingsIntro, style: setupBody),
        const SizedBox(height: 28),
        SetupGroupLabel(l10n.tempoGroupLabel),
        const SizedBox(height: 12),
        _BpmControl(
          bpm: transport.tempoBpm,
          onSubmit: (bpm) => unawaited(cubit.setTempo(bpm)),
          onTap: cubit.tapTempo,
        ),
        const SizedBox(height: 16),
        Text(l10n.timeSignatureLabel, style: setupBody),
        const SizedBox(height: 12),
        _TimeSignaturePicker(
          tsNum: transport.tsNum,
          tsDen: transport.tsDen,
          onSelected: (sigNum, sigDen) =>
              unawaited(cubit.setTimeSignature(sigNum, sigDen)),
        ),
        const SizedBox(height: 12),
        SetupToggleRow(
          toggleKey: const Key('tempoSettings_sync_switch'),
          title: l10n.syncTempoTitle,
          subtitle: l10n.syncTempoSubtitle,
          value: transport.syncTempo,
          onChanged: (on) => unawaited(cubit.setSyncTempo(value: on)),
        ),
        const SizedBox(height: 28),
        SetupGroupLabel(l10n.quantizeGroupLabel),
        const SizedBox(height: 12),
        Text(l10n.quantizeDivIntro, style: setupBody),
        const SizedBox(height: 12),
        _QuantizeDivisionPicker(
          selected: transport.quantizeDiv,
          onSelected: (div) => unawaited(cubit.setQuantizeDiv(div)),
        ),
        const SizedBox(height: 28),
        SetupGroupLabel(l10n.clickGroupLabel),
        const SizedBox(height: 12),
        Text(l10n.clickModeIntro, style: setupBody),
        const SizedBox(height: 12),
        _ClickSettingsGroup(
          mode: transport.clickMode,
          outputMask: transport.clickMask,
          volume: transport.clickVolume,
          outputChannelCount: outputChannelCount,
          onModeSelected: (mode) => unawaited(cubit.setClickMode(mode)),
          onOutputChanged: (mask) => unawaited(cubit.setClickOutput(mask)),
          onVolumeChanged: (volume) => unawaited(cubit.setClickVolume(volume)),
        ),
        const SizedBox(height: 28),
        SetupGroupLabel(l10n.countInGroupLabel),
        const SizedBox(height: 12),
        Text(l10n.countInIntro, style: setupBody),
        const SizedBox(height: 12),
        _CountInPicker(
          bars: transport.countInBars,
          onSelected: (bars) => unawaited(cubit.setCountInBars(bars)),
        ),
      ],
    );
  }
}

/// BPM numeric entry (apply on submit) + a tap-tempo button. Mirrors
/// `audio_setup`'s `_RecordOffsetField` pattern: the field reflects the live
/// [bpm] while unfocused, and stops tracking it while the user is typing.
class _BpmControl extends StatefulWidget {
  const _BpmControl({
    required this.bpm,
    required this.onSubmit,
    required this.onTap,
  });

  /// The current effective tempo (`0` = never set).
  final double bpm;

  /// Called with the new BPM when the field is submitted/applied.
  final ValueChanged<double> onSubmit;

  /// Called when the tap-tempo button is pressed.
  final VoidCallback onTap;

  @override
  State<_BpmControl> createState() => _BpmControlState();
}

class _BpmControlState extends State<_BpmControl> {
  late final TextEditingController _controller = TextEditingController(
    text: _format(widget.bpm),
  );
  final FocusNode _focus = FocusNode();

  static String _format(double bpm) => bpm > 0 ? bpm.toStringAsFixed(1) : '';

  @override
  void didUpdateWidget(_BpmControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.bpm != oldWidget.bpm && !_focus.hasFocus) {
      _controller.text = _format(widget.bpm);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _apply() {
    final value = double.tryParse(_controller.text.trim());
    if (value != null && value > 0) widget.onSubmit(value);
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            key: const Key('tempoSettings_bpm_field'),
            controller: _controller,
            focusNode: _focus,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
            ),
            decoration: InputDecoration(
              labelText: l10n.bpmFieldLabel,
              helperText: widget.bpm > 0
                  ? l10n.currentTempoLabel(widget.bpm.toStringAsFixed(1))
                  : l10n.tempoNotSetLabel,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _apply(),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton(
          key: const Key('tempoSettings_bpm_apply'),
          onPressed: _apply,
          child: Text(l10n.applyLabel),
        ),
        const SizedBox(width: 12),
        Tooltip(
          message: l10n.tapTempoTooltip,
          child: OutlinedButton(
            key: const Key('tempoSettings_tap_button'),
            onPressed: widget.onTap,
            child: Text(l10n.tapTempoButton),
          ),
        ),
      ],
    );
  }
}

/// A constrained picker for the 17 Sheeran-verified time signatures
/// ([kValidTimeSignatures]): a note-value (denominator) toggle, then a wrap
/// of numerator chips for the chosen denominator's valid range.
class _TimeSignaturePicker extends StatelessWidget {
  const _TimeSignaturePicker({
    required this.tsNum,
    required this.tsDen,
    required this.onSelected,
  });

  final int tsNum;
  final int tsDen;
  final void Function(int sigNum, int sigDen) onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final numerators = [
      for (final ts in kValidTimeSignatures)
        if (ts.$2 == tsDen) ts.$1,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetupOptionRow<int>(
          selected: tsDen,
          onSelected: (newDen) {
            // Switching denominator keeps the numerator only if it's still
            // valid for the new denominator's range; otherwise falls back to
            // the smallest valid numerator, so the result is always one of
            // the 17 valid signatures.
            final stillValid = kValidTimeSignatures.contains((tsNum, newDen));
            final newNum = stillValid
                ? tsNum
                : kValidTimeSignatures.firstWhere((ts) => ts.$2 == newDen).$1;
            onSelected(newNum, newDen);
          },
          options: [
            SetupOption(
              value: 4,
              label: l10n.timeSignatureQuarterNote,
              optionKey: const Key('tempoSettings_tsDen_4'),
            ),
            SetupOption(
              value: 8,
              label: l10n.timeSignatureEighthNote,
              optionKey: const Key('tempoSettings_tsDen_8'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final sigNum in numerators)
              _SignatureChip(
                key: Key('tempoSettings_ts_${sigNum}_$tsDen'),
                label: l10n.timeSignatureOption(sigNum, tsDen),
                selected: sigNum == tsNum,
                onTap: () => onSelected(sigNum, tsDen),
              ),
          ],
        ),
      ],
    );
  }
}

/// A single selectable time-signature chip (mirrors `setup_surface.dart`'s
/// private `_ChannelChip` styling for a single-select, non-bitmask choice).
class _SignatureChip extends StatelessWidget {
  const _SignatureChip({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return FocusableTapTarget(
      onTap: onTap,
      selected: selected,
      borderRadius: 10,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? surface.cardHigh : surface.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? surface.accent : surface.line,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? surface.accent : surface.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// The musical quantization granularity selector: off / 1 bar / 1/2 / 1/4 /
/// 1/8 / 1/16 — the arming grid A3 consumes (distinct from the audio-setup
/// tab's loop-top-only quantize toggle).
class _QuantizeDivisionPicker extends StatelessWidget {
  const _QuantizeDivisionPicker({
    required this.selected,
    required this.onSelected,
  });

  final GridDivision selected;
  final ValueChanged<GridDivision> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final labels = {
      GridDivision.off: l10n.quantizeDivOffLabel,
      GridDivision.bar: l10n.quantizeDivBarLabel,
      GridDivision.half: l10n.quantizeDivHalfLabel,
      GridDivision.quarter: l10n.quantizeDivQuarterLabel,
      GridDivision.eighth: l10n.quantizeDivEighthLabel,
      GridDivision.sixteenth: l10n.quantizeDivSixteenthLabel,
    };
    return SetupOptionRow<GridDivision>(
      selected: selected,
      onSelected: onSelected,
      options: [
        for (final div in GridDivision.values)
          SetupOption(
            value: div,
            label: labels[div]!,
            optionKey: Key('tempoSettings_quantizeDiv_${div.name}'),
          ),
      ],
    );
  }
}

/// The click mode selector (off / recording / first-take / always) plus its
/// output routing and volume — grouped since output/volume are inert
/// without an audible mode.
class _ClickSettingsGroup extends StatelessWidget {
  const _ClickSettingsGroup({
    required this.mode,
    required this.outputMask,
    required this.volume,
    required this.outputChannelCount,
    required this.onModeSelected,
    required this.onOutputChanged,
    required this.onVolumeChanged,
  });

  final ClickMode mode;
  final int outputMask;
  final double volume;
  final int outputChannelCount;
  final ValueChanged<ClickMode> onModeSelected;
  final ValueChanged<int> onOutputChanged;
  final ValueChanged<double> onVolumeChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final labels = {
      ClickMode.off: l10n.clickModeOffLabel,
      ClickMode.rec: l10n.clickModeRecLabel,
      ClickMode.recFirst: l10n.clickModeRecFirstLabel,
      ClickMode.playRec: l10n.clickModePlayRecLabel,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetupOptionRow<ClickMode>(
          selected: mode,
          onSelected: onModeSelected,
          options: [
            for (final m in ClickMode.values)
              SetupOption(
                value: m,
                label: labels[m]!,
                optionKey: Key('tempoSettings_clickMode_${m.name}'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text(l10n.clickOutputLabel, style: setupBody),
        const SizedBox(height: 12),
        SetupChannelChips(
          channelCount: outputChannelCount,
          mask: outputMask,
          keyPrefix: 'tempoSettings_clickOutput',
          onChanged: onOutputChanged,
        ),
        const SizedBox(height: 16),
        _ClickVolumeSlider(volume: volume, onChanged: onVolumeChanged),
      ],
    );
  }
}

/// The click's own volume slider (`0..LE_MAX_GAIN`).
class _ClickVolumeSlider extends StatelessWidget {
  const _ClickVolumeSlider({required this.volume, required this.onChanged});

  final double volume;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final clamped = volume.clamp(0.0, _kMaxClickGain);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.clickVolumeLabel,
                style: TextStyle(color: surface.textPrimary, fontSize: 13),
              ),
              SliderTheme(
                data: setupSliderTheme,
                child: Slider(
                  key: const Key('tempoSettings_clickVolume_slider'),
                  value: clamped,
                  max: _kMaxClickGain,
                  onChanged: onChanged,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 48,
          child: Text(
            '${(clamped * 100).round()}%',
            textAlign: TextAlign.right,
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// The count-in length picker: off / 1 / 2 / 4 measures.
class _CountInPicker extends StatelessWidget {
  const _CountInPicker({required this.bars, required this.onSelected});

  final int bars;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SetupOptionRow<int>(
      selected: bars,
      onSelected: onSelected,
      options: [
        SetupOption(
          value: 0,
          label: l10n.countInOffLabel,
          optionKey: const Key('tempoSettings_countIn_0'),
        ),
        SetupOption(
          value: 1,
          label: l10n.countInBarsLabel1,
          optionKey: const Key('tempoSettings_countIn_1'),
        ),
        SetupOption(
          value: 2,
          label: l10n.countInBarsLabel2,
          optionKey: const Key('tempoSettings_countIn_2'),
        ),
        SetupOption(
          value: 4,
          label: l10n.countInBarsLabel4,
          optionKey: const Key('tempoSettings_countIn_4'),
        ),
      ],
    );
  }
}
