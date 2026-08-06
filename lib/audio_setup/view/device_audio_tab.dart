import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/theme/theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// The Device tab of the console's Audio domain, drawn to `AUDIO / audio`,
/// `settings-device`, `settings-rate`, `settings-inputs`, `no-outputs`,
/// `asio` and `asio-missing`.
///
/// Three rows that open in place — what the rig plays through, how fast it
/// runs, and what its sockets are called. Opening rather than pushing is the
/// console's rule for a list you pick from (the Network face's rows work the
/// same way), and it keeps the other two settings visible while you change
/// one: a buffer choice is only meaningful next to the rate it divides.
class DeviceAudioTab extends StatefulWidget {
  /// Creates a [DeviceAudioTab].
  const DeviceAudioTab({super.key});

  @override
  State<DeviceAudioTab> createState() => _DeviceAudioTabState();
}

/// Which of the three rows is open, if any.
enum _OpenRow { none, device, rate, inputs }

class _DeviceAudioTabState extends State<DeviceAudioTab> {
  _OpenRow _open = _OpenRow.none;

  void _toggle(_OpenRow row) =>
      setState(() => _open = _open == row ? _OpenRow.none : row);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<AudioSetupCubit>();
    final state = context.watch<AudioSetupCubit>().state;
    final inputs = context.watch<InputsCubit>().state;
    final status = state.engineStatus;
    // The enabled-output mask is looper state, not device state: outputs are
    // turned off per channel on the Signal page, and every one of them off is
    // silence with no other symptom — meters move, the loop plays, nothing
    // comes out.
    final looper = context.watch<LooperBloc>().state;
    final outputsSilent =
        status.outputChannels > 0 && looper.outputEnabledMask == 0;

    return KeyedSubtree(
      key: const Key('device_audio_tab'),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConsoleGroupLabel(l10n.audioDeviceGroup),
            const SizedBox(height: 10),
            ConsoleCard(
              children: [
                _OpenableRow(
                  padding: EdgeInsets.zero,
                  key: const Key('audio_device_row'),
                  title: l10n.deviceLabel,
                  // The device that is PINNED, not only one the engine has
                  // managed to open: the row has to name what the next start
                  // will use, or picking one and seeing an em-dash reads as a
                  // tap that did nothing.
                  value: _deviceName(l10n, state, status),
                  expanded: _open == _OpenRow.device,
                  onTap: () => _toggle(_OpenRow.device),
                  child: _DeviceList(
                    devices: state.playbackDevices,
                    selectedId: state.playbackDeviceId,
                    openDeviceName: status.deviceName,
                    openInputChannels: status.inputChannels,
                    openOutputChannels: status.outputChannels,
                    lostDeviceName:
                        state.deviceConnectivity == DeviceConnectivity.lost
                        ? state.connectivityDeviceName
                        : '',
                    onSelected: cubit.setPlaybackDevice,
                  ),
                ),
                _OpenableRow(
                  padding: EdgeInsets.zero,
                  key: const Key('audio_rate_row'),
                  title: l10n.audioRateBufferTitle,
                  subtitle: l10n.audioRoundTripSubtitle(
                    _roundTrip(l10n, state),
                  ),
                  value: l10n.audioRateBufferValue(
                    l10n.sampleRateKhzLabel(state.sampleRate),
                    '${state.bufferFrames}',
                  ),
                  expanded: _open == _OpenRow.rate,
                  onTap: () => _toggle(_OpenRow.rate),
                  child: _RateAndBuffer(
                    state: state,
                    onRate: cubit.setSampleRate,
                    onBuffer: cubit.setBufferFrames,
                  ),
                ),
                _OpenableRow(
                  padding: EdgeInsets.zero,
                  key: const Key('audio_inputs_row'),
                  divider: false,
                  title: l10n.audioInputsTitle,
                  value: l10n.audioInputsNamedValue(inputs.namedCount),
                  expanded: _open == _OpenRow.inputs,
                  onTap: () => _toggle(_OpenRow.inputs),
                  child: _InputList(
                    count: status.inputChannels,
                    names: inputs.names,
                  ),
                ),
              ],
            ),
            // Every output turned off is silence with no other symptom: the
            // meters move, the loop plays, nothing comes out.
            if (outputsSilent) ...[
              const SizedBox(height: 14),
              ConsoleBanner(
                key: const Key('audio_no_outputs'),
                message: l10n.audioNoOutputsWarning,
                failed: true,
              ),
            ],
            if (state.asioOnly) ...[
              const SizedBox(height: 14),
              ConsoleGroupLabel(l10n.audioAsioGroup),
              const SizedBox(height: 10),
              if (state.asioDrivers.isEmpty) ...[
                ConsoleEmptyCard(message: l10n.audioAsioMissing),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ConsoleSmallButton(
                    key: const Key('audio_asio4all_link'),
                    label: l10n.audioAsioLink,
                    large: true,
                    // The generic driver, linked and never bundled — its
                    // licence forbids redistribution.
                    onPressed: () => unawaited(
                      launchUrl(
                        Uri.parse('https://asio4all.org'),
                        mode: LaunchMode.externalApplication,
                      ),
                    ),
                  ),
                ),
              ] else
                ConsoleCard(
                  children: [
                    for (final driver in state.asioDrivers)
                      ConsoleRow(
                        key: Key('audio_asio_${driver.id}'),
                        divider: driver != state.asioDrivers.last,
                        title: driver.name,
                        value: l10n.audioAsioChannels(
                          driver.inputChannels,
                          driver.outputChannels,
                        ),
                        selected: driver.id == state.asioDriver,
                        onTap: () => cubit.setAsioDriver(driver.id),
                      ),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// What to call the current device: the pinned one by name, else whatever
  /// the engine reports, else nothing to say.
  static String _deviceName(
    AppLocalizations l10n,
    AudioSetupState state,
    EngineStatus status,
  ) {
    final devices = state.playbackDevices;
    final pinned = devices
        .where((device) => device.id == state.playbackDeviceId)
        .map((device) => device.name)
        .firstOrNull;
    if (pinned != null && pinned.isNotEmpty) return pinned;
    if (status.deviceName.isNotEmpty) return status.deviceName;
    // Nothing pinned and nothing open yet: the system default is what a start
    // would use, so that is what the row is about to mean.
    final fallback = devices
        .where((device) => device.isDefault)
        .map((device) => device.name)
        .firstOrNull;
    return fallback ?? l10n.emDash;
  }

  /// The measured round-trip when there is one, else what this rate and
  /// buffer imply. Never blank: the row's whole job is to say what the
  /// current pair costs.
  static String _roundTrip(AppLocalizations l10n, AudioSetupState state) {
    final status = state.engineStatus;
    if (status.latencyState == LatencyState.done) {
      return l10n.latencyMs(status.measuredLatencyMs.toStringAsFixed(1));
    }
    return l10n.latencyMs(
      estimatedRoundTripMs(
        state.bufferFrames,
        state.sampleRate,
      ).toStringAsFixed(1),
    );
  }
}

/// What a buffer of [frames] at [rate] costs, there and back.
///
/// An ESTIMATE — two buffer periods, which is what the audio path owes before
/// the driver's own overhead. The measured figure is on the Status tab; this
/// is what lets every option in the list carry a number instead of only the
/// chosen one, which is what the mockups ask for.
double estimatedRoundTripMs(int frames, int rate) =>
    rate <= 0 ? 0 : frames * 2 * 1000 / rate;

/// A row that opens onto a recessed list, the way the Network face's rows do.
class _OpenableRow extends StatelessWidget {
  const _OpenableRow({
    required this.title,
    required this.value,
    required this.expanded,
    required this.onTap,
    required this.child,
    this.subtitle,
    this.divider = true,
    this.padding = const EdgeInsets.fromLTRB(20, 0, 20, 14),
    super.key,
  });

  final String title;
  final String? subtitle;
  final String value;
  final bool expanded;
  final VoidCallback onTap;
  final Widget child;
  final bool divider;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      ConsoleRow(
        title: title,
        subtitle: subtitle,
        value: value,
        divider: divider,
        expanded: expanded,
        onTap: onTap,
      ),
      ConsoleExpansion(
        expanded: expanded,
        child: Padding(
          padding: padding,
          child: child,
        ),
      ),
    ],
  );
}

/// The enumerated devices: what each one offers, and which are not there.
class _DeviceList extends StatelessWidget {
  const _DeviceList({
    required this.devices,
    required this.selectedId,
    required this.lostDeviceName,
    required this.openDeviceName,
    required this.openInputChannels,
    required this.openOutputChannels,
    required this.onSelected,
  });

  final List<AudioDevice> devices;
  final String selectedId;

  /// What the engine has open, and the channel counts it negotiated.
  ///
  /// Enumeration only carries channel counts on ASIO, where a probe fills
  /// them in; everywhere else they come back `0`, meaning unknown. The device
  /// that is actually OPEN has real numbers, so it can say them.
  final String openDeviceName;
  final int openInputChannels;
  final int openOutputChannels;

  /// The pinned device the rig can no longer see, or empty.
  ///
  /// It stays on the list, greyed and inert, as the mockups draw it: a device
  /// that vanished from the list would read as a device you never had, and
  /// the pin is still pointing at it.
  final String lostDeviceName;

  final ValueChanged<String> onSelected;

  /// `18 in · 20 out` when the counts are known, else nothing.
  String? _channels(AppLocalizations l10n, AudioDevice device) {
    var inputs = device.inputChannels;
    var outputs = device.outputChannels;
    if (inputs <= 0 && outputs <= 0 && device.name == openDeviceName) {
      inputs = openInputChannels;
      outputs = openOutputChannels;
    }
    if (inputs <= 0 && outputs <= 0) return null;
    return l10n.audioDeviceChannels(inputs, outputs);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ConsoleCard(
      borderRadius: 0,
      color: context.surface.background,
      children: [
        for (final device in devices)
          ConsoleRow(
            key: Key('audio_device_${device.id}'),
            divider: device != devices.last || lostDeviceName.isNotEmpty,
            title: device.name,
            // Nothing rather than "0 in · 0 out": an unknown count is not a
            // count of zero, and a device claiming no channels reads as one
            // that cannot be used.
            value: _channels(l10n, device),
            valueColor: context.surface.textMuted,
            showDisclosure: false,
            leading: _Check(selected: device.id == selectedId),
            onTap: () => onSelected(device.id),
          ),
        if (lostDeviceName.isNotEmpty)
          ConsoleRow(
            key: const Key('audio_device_unplugged'),
            divider: false,
            title: lostDeviceName,
            titleColor: context.surface.textMuted,
            value: l10n.audioDeviceUnplugged,
            valueColor: context.surface.textMuted,
            showDisclosure: false,
            leading: const _Check(selected: false),
          ),
      ],
    );
  }
}

/// Sample rate and buffer, each option carrying what it costs.
class _RateAndBuffer extends StatelessWidget {
  const _RateAndBuffer({
    required this.state,
    required this.onRate,
    required this.onBuffer,
  });

  final AudioSetupState state;
  final ValueChanged<int> onRate;
  final ValueChanged<int> onBuffer;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final rates = state.sampleRateChoices;
    final buffers = state.bufferChoices;
    return ConsoleCard(
      // Flush and square inside the row's own card, as the mockups draw every
      // opened list: an inset rounded card would read as a second surface.
      borderRadius: 0,
      color: context.surface.background,
      children: [
        _Caption(l10n.audioSampleRateGroup),
        for (final rate in rates)
          ConsoleRow(
            key: Key('audio_rate_$rate'),
            title: l10n.sampleRateKhzLabel(rate),
            // The one rate that costs something to choose says so.
            subtitle: rate >= 96000 ? l10n.audioRateHalvesHeadroom : null,
            showDisclosure: false,
            leading: _Check(selected: rate == state.sampleRate),
            onTap: () => onRate(rate),
          ),
        _Caption(l10n.audioBufferGroup),
        for (final frames in buffers)
          ConsoleRow(
            key: Key('audio_buffer_$frames'),
            divider: frames != buffers.last,
            title: '$frames',
            value: l10n.latencyMs(
              estimatedRoundTripMs(
                frames,
                state.sampleRate,
              ).toStringAsFixed(1),
            ),
            valueColor: context.surface.textMuted,
            showDisclosure: false,
            leading: _Check(selected: frames == state.bufferFrames),
            onTap: () => onBuffer(frames),
          ),
      ],
    );
  }
}

/// The hardware inputs, by the name they were given.
class _InputList extends StatelessWidget {
  const _InputList({required this.count, required this.names});

  final int count;
  final List<String> names;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final inputs = count > 0 ? count : 0;
    if (inputs == 0) {
      return ConsoleEmptyCard(message: l10n.audioInputsEmpty);
    }
    return ConsoleCard(
      borderRadius: 0,
      color: context.surface.background,
      children: [
        for (var i = 0; i < inputs; i++)
          ConsoleRow(
            key: Key('audio_input_$i'),
            divider: i != inputs - 1,
            title: l10n.inputName(names, i),
            // The socket it is, under the name you gave it.
            value: l10n.audioInputOrdinal(i + 1),
            valueColor: context.surface.textMuted,
            leading: _Check(selected: i < names.length && names[i].isNotEmpty),
            onTap: () => unawaited(_rename(context, i)),
          ),
      ],
    );
  }

  Future<void> _rename(BuildContext context, int input) async {
    final l10n = context.l10n;
    final cubit = context.read<InputsCubit>();
    final name = await showConsoleRenameSheet(
      context,
      title: l10n.audioInputRenameTitle,
      // The socket being named, as the mockups put it beside the title.
      subtitle: l10n.audioInputOrdinal(input + 1),
      initial: cubit.state.nameOf(input),
      // Empty is a real answer here: it hands the socket back its ordinal.
      allowEmpty: true,
    );
    if (name == null) return;
    await cubit.rename(input, name);
  }
}

/// A caption inside an opened list — the mockups' 13px muted heading over the
/// sample-rate and buffer groups. Not a [ConsoleRow]: a row is 70px and
/// tappable, and these are neither.
class _Caption extends StatelessWidget {
  const _Caption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 7),
    child: ConsoleGroupLabel(text),
  );
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
