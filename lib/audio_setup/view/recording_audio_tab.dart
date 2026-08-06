import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/quantize_cubit.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/theme/theme.dart';

/// The Recording tab of the console's Audio domain, drawn to
/// `AUDIO / audio-recording` and `settings-maxloop`: what pressing record
/// does, and how much room it is given.
class RecordingAudioTab extends StatefulWidget {
  /// Creates a [RecordingAudioTab].
  const RecordingAudioTab({super.key});

  @override
  State<RecordingAudioTab> createState() => _RecordingAudioTabState();
}

class _RecordingAudioTabState extends State<RecordingAudioTab> {
  /// Whether the max-loop row is open. The mockups open this one in place
  /// rather than in a dialog, because its options are a memory decision the
  /// subtitle above them explains.
  bool _maxLoopOpen = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final audio = context.watch<AudioSetupCubit>();
    final record = context.watch<RecordOptionsCubit>();
    final quantize = context.watch<QuantizeCubit>();

    return KeyedSubtree(
      key: const Key('recording_audio_tab'),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConsoleGroupLabel(l10n.audioRecordingGroup),
            const SizedBox(height: 10),
            ConsoleCard(
              children: [
                ConsoleRow(
                  key: const Key('audio_maxloop_row'),
                  title: l10n.audioMaxLoopTitle,
                  subtitle: l10n.audioMaxLoopSubtitle,
                  value: _maxLoopLabel(l10n, audio.state.maxLoopMinutes),
                  expanded: _maxLoopOpen,
                  onTap: () => setState(() => _maxLoopOpen = !_maxLoopOpen),
                ),
                ConsoleExpansion(
                  expanded: _maxLoopOpen,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                    child: ConsoleCard(
                      color: context.surface.background,
                      children: [
                        for (final minutes
                            in AudioSetupState.maxLoopMinuteOptions)
                          ConsoleRow(
                            key: Key('audio_maxloop_$minutes'),
                            divider:
                                minutes !=
                                AudioSetupState.maxLoopMinuteOptions.last,
                            title: _maxLoopLabel(l10n, minutes),
                            showDisclosure: false,
                            leading: _Check(
                              selected: minutes == audio.state.maxLoopMinutes,
                            ),
                            onTap: () => audio.setMaxLoopMinutes(minutes),
                          ),
                      ],
                    ),
                  ),
                ),
                ConsoleRow(
                  key: const Key('audio_quantize_row'),
                  title: l10n.quantizeRecording,
                  subtitle: l10n.audioQuantizeSubtitle,
                  trailing: ConsoleSwitch(
                    key: const Key('audio_quantize_switch'),
                    value: quantize.state,
                    semanticLabel: l10n.quantizeRecording,
                    onChanged: (on) =>
                        unawaited(quantize.setEnabled(value: on)),
                  ),
                ),
                ConsoleRow(
                  key: const Key('audio_recdub_row'),
                  title: l10n.overdubOnSecondPressTitle,
                  subtitle: l10n.overdubOnSecondPressSubtitle,
                  trailing: ConsoleSwitch(
                    key: const Key('audio_recdub_switch'),
                    value: record.state.recDub,
                    semanticLabel: l10n.overdubOnSecondPressTitle,
                    onChanged: (on) =>
                        unawaited(record.setRecDub(value: on)),
                  ),
                ),
                ConsoleRow(
                  key: const Key('audio_autorecord_row'),
                  title: l10n.soundActivatedRecordingTitle,
                  subtitle: l10n.soundActivatedRecordingSubtitle,
                  trailing: ConsoleSwitch(
                    key: const Key('audio_autorecord_switch'),
                    value: record.state.autoRecord,
                    semanticLabel: l10n.soundActivatedRecordingTitle,
                    onChanged: (on) =>
                        unawaited(record.setAutoRecord(value: on)),
                  ),
                ),
                ConsoleRow(
                  key: const Key('audio_defaultlength_row'),
                  divider: false,
                  title: l10n.audioDefaultLengthTitle,
                  subtitle: l10n.audioDefaultLengthSubtitle,
                  value: _multipleLabel(l10n, record.state.defaultMultiple),
                  onTap: () => unawaited(_pickMultiple(context, record)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickMultiple(
    BuildContext context,
    RecordOptionsCubit record,
  ) async {
    final l10n = context.l10n;
    final chosen = await showConsoleChipDialog<int>(
      context,
      title: l10n.audioDefaultLengthTitle,
      explanation: l10n.audioDefaultLengthSubtitle,
      selected: record.state.defaultMultiple,
      options: [
        for (final multiple in const [0, 1, 2, 3])
          ConsoleSegment(
            value: multiple,
            label: _multipleLabel(l10n, multiple),
          ),
      ],
    );
    if (chosen == null) return;
    await record.setDefaultMultiple(chosen);
  }

  static String _maxLoopLabel(AppLocalizations l10n, int minutes) =>
      minutes == 0 ? l10n.maxLoopDefault30s : l10n.maxLoopMinutes(minutes);

  static String _multipleLabel(AppLocalizations l10n, int multiple) =>
      multiple == 0 ? l10n.auto : l10n.loopMultipleLabel(multiple);
}

/// The mockups' check gutter, at their 40px inset.
class _Check extends StatelessWidget {
  const _Check({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 33,
    child: Align(
      alignment: Alignment.centerRight,
      child: selected
          ? Icon(Icons.check, size: 18, color: context.surface.accent)
          : const SizedBox.shrink(),
    ),
  );
}
