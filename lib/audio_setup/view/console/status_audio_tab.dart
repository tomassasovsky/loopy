import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/audio_setup/view/console/audio_face.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';

/// The Status tab: what the rig is actually doing right now.
///
/// **Read-only, every row of it.** The settings that decide these figures live
/// on Device, and a figure editable in two places is a figure that disagrees
/// with itself — so the rows take no tap and draw no disclosure marker.
///
/// The one action is re-running the measurement, and it refuses while one is in
/// flight rather than restarting the thing it is reporting.
class StatusAudioTab extends StatelessWidget {
  /// Creates a [StatusAudioTab].
  const StatusAudioTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.watch<AudioSetupCubit>();
    final state = cubit.state;
    final status = state.engineStatus;
    final measuring = status.latencyState == LatencyState.measuring;

    return KeyedSubtree(
      key: const Key('audio_status_tab'),
      child: AudioFace(
        groups: [
          AudioGroup(
            caption: l10n.statusGroupLabel,
            blocks: [
              ConsoleCard(
                children: [
                  _readout(
                    key: const Key('audio_status_device'),
                    title: l10n.deviceLabel,
                    // The em-dash rather than "Not running": this is a table of
                    // what the engine reports, and a running-state sentence in
                    // a device column is a different fact in the same slot.
                    value: status.deviceName.isNotEmpty
                        ? status.deviceName
                        : l10n.emDash,
                  ),
                  _readout(
                    key: const Key('audio_status_rate'),
                    title: l10n.sampleRateLabel,
                    value: status.sampleRate > 0
                        ? l10n.sampleRateHz(status.sampleRate)
                        : l10n.emDash,
                  ),
                  _readout(
                    key: const Key('audio_status_buffer'),
                    title: l10n.bufferLabel,
                    value: status.bufferFrames > 0
                        ? l10n.bufferFrames(status.bufferFrames)
                        : l10n.emDash,
                  ),
                  _readout(
                    key: const Key('audio_status_latency'),
                    title: l10n.roundTripLatencyLabel,
                    value: _latency(l10n, status),
                  ),
                  _readout(
                    key: const Key('audio_status_offset'),
                    title: l10n.recordOffsetLabel,
                    value: l10n.bufferFrames(status.recordOffsetFrames),
                    showDivider: false,
                  ),
                ],
              ),
              ConsoleCard(
                children: [
                  ConsoleRow(
                    key: const Key('audio_measure_row'),
                    title: measuring
                        ? l10n.measuringEllipsis
                        : l10n.measureRoundTripLatency,
                    subtitle: l10n.measureLatencySubtitle,
                    semanticLabel: l10n.a11yAudioMeasureLatency,
                    expanded: false,
                    showDivider: false,
                    // Refuses while one is in flight rather than restarting the
                    // thing it is reporting.
                    onTap: measuring ? null : cubit.measureLatency,
                  ),
                ],
              ),
              // Only when there IS one: the resolver's other branch describes a
              // loopback that exists but cannot be auto-routed, and with none
              // at all it would name a kind that is not there.
              if (state.loopback.available)
                ConsoleProse(l10n.loopbackNote(state.loopback)),
            ],
          ),
        ],
      ),
    );
  }

  /// A row that only reports: no tap, and no gutter reserved for a marker
  /// there is none of.
  Widget _readout({
    required Key key,
    required String title,
    required String value,
    bool showDivider = true,
  }) => ConsoleRow(
    key: key,
    title: title,
    value: value,
    showDisclosure: false,
    showDivider: showDivider,
  );

  String _latency(AppLocalizations l10n, EngineStatus status) =>
      switch (status.latencyState) {
        LatencyState.measuring => l10n.measuringEllipsis,
        LatencyState.done => l10n.latencyMs(
          status.measuredLatencyMs.toStringAsFixed(2),
        ),
        LatencyState.timeout => l10n.noSignalDetected,
        LatencyState.idle => l10n.notMeasured,
      };
}
