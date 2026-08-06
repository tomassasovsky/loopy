import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// The Status tab of the console's Audio domain, drawn to
/// `AUDIO / audio-status` and `settings-nolatency`: what the engine reports,
/// and the one action on this face — re-running the latency measurement.
///
/// Read-only rows, deliberately: everything here is what the rig IS doing.
/// The settings that decide it live on the Device tab, and a figure you can
/// edit in two places is a figure that disagrees with itself.
class StatusAudioTab extends StatelessWidget {
  /// Creates a [StatusAudioTab].
  const StatusAudioTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final state = context.watch<AudioSetupCubit>().state;
    final status = state.engineStatus;
    final measuring = status.latencyState == LatencyState.measuring;

    return KeyedSubtree(
      key: const Key('status_audio_tab'),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConsoleGroupLabel(l10n.audioStatusGroup),
            const SizedBox(height: 10),
            ConsoleCard(
              children: [
                ConsoleRow(
                  key: const Key('audio_status_device'),
                  title: l10n.deviceLabel,
                  value: status.deviceName.isEmpty
                      ? l10n.emDash
                      : status.deviceName,
                  showDisclosure: false,
                ),
                ConsoleRow(
                  key: const Key('audio_status_rate'),
                  title: l10n.sampleRateLabel,
                  value: status.sampleRate > 0
                      ? l10n.sampleRateHz(status.sampleRate)
                      : l10n.emDash,
                  showDisclosure: false,
                ),
                ConsoleRow(
                  key: const Key('audio_status_buffer'),
                  title: l10n.bufferLabel,
                  value: status.bufferFrames > 0
                      ? l10n.bufferFrames(status.bufferFrames)
                      : l10n.emDash,
                  showDisclosure: false,
                ),
                ConsoleRow(
                  key: const Key('audio_status_latency'),
                  title: l10n.roundTripLatencyLabel,
                  value: _latency(l10n, status),
                  // A timed-out measurement is not a number in a muted tone:
                  // it is the reason the offset below may be wrong.
                  valueColor: status.latencyState == LatencyState.timeout
                      ? surface.warning
                      : null,
                  showDisclosure: false,
                ),
                ConsoleRow(
                  key: const Key('audio_status_offset'),
                  divider: false,
                  title: l10n.recordOffsetLabel,
                  value: l10n.bufferFrames(status.recordOffsetFrames),
                  showDisclosure: false,
                ),
              ],
            ),
            const SizedBox(height: 14),
            ConsoleCard(
              children: [
                ConsoleRow(
                  key: const Key('audio_status_measure'),
                  divider: false,
                  title: measuring
                      ? l10n.measuringEllipsis
                      : l10n.measureRoundTripLatency,
                  subtitle: l10n.measureLatencySubtitle,
                  // Tapping again while it runs would restart the measurement
                  // it is reporting.
                  onTap: measuring
                      ? null
                      : context.read<AudioSetupCubit>().measureLatency,
                ),
              ],
            ),
            if (_loopbackNote(l10n, state) case final String note) ...[
              const SizedBox(height: 14),
              Text(
                note,
                key: const Key('audio_status_loopback_note'),
                style: TextStyle(color: surface.textMuted, fontSize: 14),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _latency(AppLocalizations l10n, EngineStatus status) =>
      switch (status.latencyState) {
        LatencyState.measuring => l10n.measuringEllipsis,
        LatencyState.done => l10n.latencyMs(
          status.measuredLatencyMs.toStringAsFixed(2),
        ),
        LatencyState.timeout => l10n.noSignalDetected,
        LatencyState.idle => l10n.notMeasured,
      };

  /// What the loopback path means for the figure above, or null when there is
  /// no loopback to explain.
  ///
  /// Same sentence the setup page shows — `l10n.loopbackNote` owns the wording
  /// and the auto-routable/kind distinction, so the two surfaces cannot come
  /// to different conclusions about the same rig.
  static String? _loopbackNote(AppLocalizations l10n, AudioSetupState state) =>
      state.loopback.available ? l10n.loopbackNote(state.loopback) : null;
}
