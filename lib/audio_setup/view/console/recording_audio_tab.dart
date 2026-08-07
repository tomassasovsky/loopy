import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';

import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/quantize_cubit.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/theme/theme.dart';

/// Which of the tab's two openable rows is showing its list.
enum _OpenRow {
  /// Nothing is open — the tab's resting state.
  none,

  /// The maximum per-track loop length.
  maxLoop,

  /// The default loop length for new recordings.
  defaultLength,
}

/// The Recording tab: what pressing record does.
///
/// Two rows that open in place and three switches between them. Both open onto
/// **chip grids** — `Default (30 s)`, `2 min`, `Auto`, `×2` are all bare
/// tokens, and a token has nothing to put in a row's width.
class RecordingAudioTab extends StatefulWidget {
  /// Creates a [RecordingAudioTab].
  const RecordingAudioTab({super.key});

  @override
  State<RecordingAudioTab> createState() => _RecordingAudioTabState();
}

class _RecordingAudioTabState extends State<RecordingAudioTab> {
  _OpenRow _open = _OpenRow.none;

  /// The fixed default-length multiples, beside `Auto`. Three, because a
  /// fourth is a length you set on the track itself.
  static const _multiples = [1, 2, 3];

  void _toggle(_OpenRow row) =>
      setState(() => _open = _open == row ? _OpenRow.none : row);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final audio = context.watch<AudioSetupCubit>();
    final options = context.watch<RecordOptionsCubit>().state;
    final quantize = context.watch<QuantizeCubit>().state;
    final cap = audio.state.maxLoopMinutes;

    return KeyedSubtree(
      key: const Key('audio_recording_tab'),
      child: ConsoleFace(
        previewKey: const Key('audio_upcoming_group'),
        groups: [
          ConsoleGroup(
            caption: l10n.recordingGroupLabel,
            blocks: [
              ConsoleCard(
                children: [
                  ConsoleRow(
                    key: const Key('audio_max_loop_row'),
                    title: l10n.audioMaxLoopTitle,
                    subtitle: l10n.audioMaxLoopSubtitle,
                    value: _capLabel(l10n, cap),
                    expanded: _open == _OpenRow.maxLoop,
                    fill: _open == _OpenRow.maxLoop ? surface.control : null,
                    onTap: () => _toggle(_OpenRow.maxLoop),
                  ),
                  ConsoleChooser.grid(
                    key: const Key('audio_max_loop_chooser'),
                    open: _open == _OpenRow.maxLoop,
                    // A grid, not a row list: every option is a bare token, and
                    // a token has nothing to put in a row's width.
                    grid: ConsoleChipGrid<int>(
                      selected: {cap},
                      options: [
                        for (final minutes
                            in AudioSetupState.maxLoopMinuteOptions)
                          ConsoleSegment(
                            value: minutes,
                            label: _capLabel(l10n, minutes),
                            optionKey: Key('audio_max_loop_$minutes'),
                          ),
                      ],
                      onTap: (minutes) {
                        audio.setMaxLoopMinutes(minutes);
                        // A pick-one: the question is answered, so it shuts.
                        setState(() => _open = _OpenRow.none);
                      },
                    ),
                  ),
                  ConsoleRow(
                    key: const Key('audio_quantize_row'),
                    title: l10n.quantizeRecording,
                    subtitle: l10n.quantizeRecordingSubtitle,
                    trailing: ConsoleSwitch(
                      key: const Key('audio_quantize_switch'),
                      value: quantize,
                      semanticLabel: l10n.quantizeRecording,
                      onChanged: (on) => unawaited(
                        context.read<QuantizeCubit>().setEnabled(value: on),
                      ),
                    ),
                  ),
                  ConsoleRow(
                    key: const Key('audio_rec_dub_row'),
                    title: l10n.overdubOnSecondPressTitle,
                    subtitle: l10n.overdubOnSecondPressSubtitle,
                    trailing: ConsoleSwitch(
                      key: const Key('audio_rec_dub_switch'),
                      value: options.recDub,
                      semanticLabel: l10n.overdubOnSecondPressTitle,
                      onChanged: (on) => unawaited(
                        context.read<RecordOptionsCubit>().setRecDub(value: on),
                      ),
                    ),
                  ),
                  ConsoleRow(
                    key: const Key('audio_auto_record_row'),
                    title: l10n.soundActivatedRecordingTitle,
                    subtitle: l10n.soundActivatedRecordingSubtitle,
                    trailing: ConsoleSwitch(
                      key: const Key('audio_auto_record_switch'),
                      value: options.autoRecord,
                      semanticLabel: l10n.soundActivatedRecordingTitle,
                      onChanged: (on) => unawaited(
                        context.read<RecordOptionsCubit>().setAutoRecord(
                          value: on,
                        ),
                      ),
                    ),
                  ),
                  ConsoleRow(
                    key: const Key('audio_default_length_row'),
                    title: l10n.audioDefaultLoopLengthTitle,
                    subtitle: l10n.audioDefaultLoopLengthSubtitle,
                    value: _lengthLabel(l10n, options.defaultMultiple),
                    expanded: _open == _OpenRow.defaultLength,
                    fill: _open == _OpenRow.defaultLength
                        ? surface.control
                        : null,
                    showDivider: false,
                    onTap: () => _toggle(_OpenRow.defaultLength),
                  ),
                  ConsoleChooser.grid(
                    key: const Key('audio_default_length_chooser'),
                    open: _open == _OpenRow.defaultLength,
                    grid: ConsoleChipGrid<int>(
                      selected: {options.defaultMultiple},
                      options: [
                        ConsoleSegment(
                          value: 0,
                          label: l10n.auto,
                          optionKey: const Key('audio_default_length_0'),
                        ),
                        for (final multiple in _multiples)
                          ConsoleSegment(
                            value: multiple,
                            label: l10n.loopMultipleLabel(multiple),
                            optionKey: Key('audio_default_length_$multiple'),
                          ),
                      ],
                      onTap: (multiple) {
                        unawaited(
                          context.read<RecordOptionsCubit>().setDefaultMultiple(
                            multiple,
                          ),
                        );
                        // A pick-one: the question is answered, so the drawer
                        // shuts. A bitmask grid would stay open.
                        setState(() => _open = _OpenRow.none);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _capLabel(AppLocalizations l10n, int minutes) =>
      minutes <= 0 ? l10n.maxLoopDefault30s : l10n.maxLoopMinutes(minutes);

  String _lengthLabel(AppLocalizations l10n, int multiple) =>
      multiple <= 0 ? l10n.auto : l10n.loopMultipleLabel(multiple);
}
