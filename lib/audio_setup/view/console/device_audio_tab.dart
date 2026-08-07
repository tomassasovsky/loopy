import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/view/console/audio_face.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/theme/theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// Which of the tab's three rows is open, if any.
///
/// One enum with a [none] member rather than three booleans, because opening
/// one row must close the others: two lists open at once is a scroll, and a
/// buffer choice is only meaningful next to the rate it divides.
enum _OpenRow {
  /// Nothing is open.
  none,

  /// The device list.
  device,

  /// The sample rate and buffer groups.
  rate,

  /// The hardware inputs.
  inputs,
}

/// One interface, both directions.
///
/// The host lists playback and capture separately while one box is both, so
/// the console's single Device row pairs them **by name** — that is the only
/// thing the two halves reliably share, and `18 in · 20 out` is one device's
/// fact, not two devices'.
@immutable
class _Interface {
  const _Interface({
    required this.name,
    this.playbackId = '',
    this.captureId = '',
    this.inputChannels = 0,
    this.outputChannels = 0,
    this.absent = false,
  });

  final String name;
  final String playbackId;
  final String captureId;

  /// `0` means UNKNOWN, never "no channels" — a device that cannot answer
  /// keeps it, and the row then says nothing rather than claiming a zero.
  final int inputChannels;
  final int outputChannels;

  /// Whether this is the pinned device the host is no longer reporting.
  final bool absent;
}

/// The Device tab: what the rig plays through, how fast it runs, and what its
/// inputs are called.
///
/// Three rows, each opening **in place** onto its own list rather than pushing
/// a route. The mockups make the reason plain: a buffer choice is only
/// meaningful beside the rate it divides, and a route would hide the other two
/// settings while you changed one.
class DeviceAudioTab extends StatefulWidget {
  /// Creates a [DeviceAudioTab].
  const DeviceAudioTab({super.key});

  @override
  State<DeviceAudioTab> createState() => _DeviceAudioTabState();
}

class _DeviceAudioTabState extends State<DeviceAudioTab> {
  _OpenRow _open = _OpenRow.none;

  /// The ASIO4ALL download page — a generic ASIO driver for interfaces without
  /// their own. Linked, never bundled: its licence forbids redistribution.
  static final Uri _asio4all = Uri.parse('https://asio4all.org');

  void _toggle(_OpenRow row) =>
      setState(() => _open = _open == row ? _OpenRow.none : row);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<AudioSetupCubit>().state;
    // The silence banner is read from the LOOPER's own gate, not from device
    // state: outputs are switched per channel on the Signal page, and every one
    // of them off is silence with no other symptom — the meters move, the loop
    // plays, nothing comes out.
    //
    // Over the outputs the RIG HAS, never over the raw mask. The mask is
    // default-on across all 32 bits and the app only ever gates the sockets the
    // device reports, so `mask == 0` is a value the rig cannot produce: gating
    // both outputs of a stereo interface leaves 0xFFFFFFFC. Same predicate the
    // Signal page's own no-output notice uses.
    final silent = context.select<LooperBloc, bool>((bloc) {
      final looper = bloc.state;
      final outputs = looper.status.outputChannels;
      return outputs > 0 &&
          List.generate(outputs, looper.isOutputEnabled).every((on) => !on);
    });

    final blocks = <Widget>[
      _card(context, state),
      if (silent)
        ConsoleCard(
          key: const Key('audio_no_outputs_card'),
          children: [
            ConsoleBanner(
              key: const Key('audio_no_outputs_banner'),
              message: l10n.audioNoOutputsBanner,
              tone: ConsoleBannerTone.failure,
            ),
          ],
        ),
    ];

    return KeyedSubtree(
      key: const Key('audio_device_tab'),
      child: AudioFace(
        lastGroupExtent: state.asioOnly ? _asioExtent(state) : 0,
        groups: [
          AudioGroup(caption: l10n.audioGroupLabel, blocks: blocks),
          // Windows runs ASIO exclusively, so the driver it opens is a setting
          // of its own rather than one of the devices above.
          if (state.asioOnly) _asioGroup(context, state),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- the card

  Widget _card(BuildContext context, AudioSetupState state) {
    final l10n = context.l10n;
    final surface = context.surface;
    final devices = _interfaces(context, state);
    final current = _currentInterface(devices, state);
    final rate = state.sampleRate;
    final buffer = state.bufferFrames;
    final estimate = AudioSetupState.estimatedRoundTripMs(buffer, rate);

    return ConsoleCard(
      children: [
        ConsoleRow(
          key: const Key('audio_device_row'),
          title: l10n.deviceLabel,
          // The PINNED device, falling back to the engine's, then the system
          // default, and only then to the em-dash: picking a device and seeing
          // a dash reads as a tap that did nothing.
          value: current?.name ?? _engineOrDefaultName(context, state),
          expanded: _open == _OpenRow.device,
          fill: _open == _OpenRow.device ? surface.control : null,
          onTap: () => _toggle(_OpenRow.device),
        ),
        ConsoleChooser(
          key: const Key('audio_device_chooser'),
          open: _open == _OpenRow.device,
          children: [
            for (final (index, device) in devices.indexed)
              ConsolePickRow(
                key: Key('audio_device_option_$index'),
                title: device.name,
                state: device.absent
                    ? l10n.audioDeviceUnplugged
                    : _channelCounts(l10n, device),
                dimmed: device.absent,
                selected: device == current,
                showDivider: index < devices.length - 1,
                onTap: () => context.read<AudioSetupCubit>().setDevice(
                  playbackDeviceId: device.playbackId,
                  captureDeviceId: device.captureId,
                ),
              ),
          ],
        ),
        ConsoleRow(
          key: const Key('audio_rate_row'),
          title: l10n.audioRateBufferRow,
          // The ESTIMATE rides the closed row; the measured figure stays on
          // Status, where it is measured.
          subtitle: estimate > 0
              ? l10n.audioRoundTripEstimate(estimate.toStringAsFixed(1))
              : null,
          value: l10n.audioRateBufferValue(
            l10n.sampleRateKhzLabel(rate),
            buffer,
          ),
          expanded: _open == _OpenRow.rate,
          fill: _open == _OpenRow.rate ? surface.control : null,
          onTap: () => _toggle(_OpenRow.rate),
        ),
        ConsoleChooser(
          key: const Key('audio_rate_chooser'),
          open: _open == _OpenRow.rate,
          children: [
            ConsoleDrawerLabel(l10n.audioSampleRateGroup),
            for (final (index, option) in state.sampleRateChoices.indexed)
              ConsolePickRow(
                key: Key('audio_sample_rate_$option'),
                title: l10n.sampleRateKhzLabel(option),
                // Only the option that COSTS something says so. 96 kHz halves
                // the frames a buffer of the same size holds.
                state: option >= 96000 ? l10n.audioSampleRateCost96 : null,
                selected: option == rate,
                onTap: () =>
                    context.read<AudioSetupCubit>().setSampleRate(option),
                showDivider: index < state.sampleRateChoices.length - 1,
              ),
            ConsoleDrawerLabel(l10n.audioBufferGroup),
            for (final (index, option) in state.bufferChoices.indexed)
              ConsolePickRow(
                key: Key('audio_buffer_$option'),
                title: '$option',
                // EVERY option carries its own cost, not only the chosen one:
                // a list where the current pick is the only annotated row
                // cannot be used to choose.
                state: _bufferCost(l10n, option, rate),
                selected: option == buffer,
                onTap: () =>
                    context.read<AudioSetupCubit>().setBufferFrames(option),
                showDivider: index < state.bufferChoices.length - 1,
              ),
          ],
        ),
        _inputsRow(context, _inputCount(state, current)),
        _inputsChooser(context, state, current),
      ],
    );
  }

  // ----------------------------------------------------------- the inputs

  Widget _inputsRow(BuildContext context, int count) {
    final l10n = context.l10n;
    final surface = context.surface;
    // Counted over the sockets the list SHOWS, not over every socket a name
    // was ever stored for: a name kept from a wider rig is still on disk, and
    // "3 named" over a list of two names is a row disagreeing with itself.
    final inputs = context.watch<InputsCubit>().state;
    final named = [
      for (var input = 0; input < count; input++)
        if (inputs.isNamed(input)) input,
    ].length;
    return ConsoleRow(
      key: const Key('audio_inputs_row'),
      title: l10n.audioInputsRow,
      value: l10n.audioInputsNamed(named),
      expanded: _open == _OpenRow.inputs,
      fill: _open == _OpenRow.inputs ? surface.control : null,
      showDivider: false,
      onTap: () => _toggle(_OpenRow.inputs),
    );
  }

  Widget _inputsChooser(
    BuildContext context,
    AudioSetupState state,
    _Interface? current,
  ) {
    final l10n = context.l10n;
    final inputs = context.watch<InputsCubit>().state;
    final names = inputs.names;
    final count = _inputCount(state, current);
    return ConsoleChooser(
      key: const Key('audio_inputs_chooser'),
      open: _open == _OpenRow.inputs,
      children: [
        if (count == 0)
          Padding(
            padding: ConsoleChooser.gridInset,
            child: ConsoleEmptyCard(
              key: const Key('audio_no_inputs_card'),
              message: l10n.audioNoInputs,
            ),
          )
        else
          for (var input = 0; input < count; input++)
            ConsoleRow(
              key: Key('audio_input_$input'),
              // One step in, so the check column lines up with the pick rows
              // of the lists above it.
              indented: true,
              leading: _NamedCheck(named: inputs.isNamed(input)),
              title: l10n.inputName(names, input),
              // The SOCKET, in the muted tone the mockups give a row's own
              // facts — `guitar` over `input 1`.
              state: l10n.inputOrdinal(input + 1),
              valueColor: context.surface.textMuted,
              showDisclosure: false,
              showDivider: input < count - 1,
              onTap: () => unawaited(_rename(context, names, input)),
            ),
      ],
    );
  }

  Future<void> _rename(
    BuildContext context,
    List<String> names,
    int input,
  ) async {
    final l10n = context.l10n;
    final cubit = context.read<InputsCubit>();
    final name = await showConsoleRenameSheet(
      context,
      title: l10n.audioRenameInputTitle,
      subtitle: l10n.inputOrdinal(input + 1),
      current: names[input],
      fieldLabel: l10n.a11yInputRenameField,
      // `AUDIO / settings-rename` has no Clear button — it has a backspace and
      // Save — so emptying the field IS how an input is un-named, and the
      // socket takes its ordinal back.
      allowEmpty: true,
    );
    if (name == null) return;
    await cubit.rename(input, name);
  }

  // ------------------------------------------------------------ ASIO group

  /// How tall the ASIO group is: its caption, plus either the install banner's
  /// own card or one row per enumerated driver in a card that insets 1px top
  /// and bottom.
  double _asioExtent(AudioSetupState state) {
    final drivers = state.cachedAsioDrivers.length;
    return ConsolePinnedGroupLabel.extent +
        (drivers == 0 ? _bannerCardExtent : kConsoleRowHeight * drivers + 2);
  }

  /// The install banner's card: a 61px banner (the sentence plus the button
  /// that is taller than it) inside a card that insets 1px top and bottom.
  static const double _bannerCardExtent = 63;

  AudioGroup _asioGroup(BuildContext context, AudioSetupState state) {
    final l10n = context.l10n;
    // The cached enumeration, which stays populated even while ASIO holds the
    // device — re-probing live would tear the stream down (R1).
    final drivers = state.cachedAsioDrivers;
    return AudioGroup(
      caption: l10n.audioAsioDriverGroup,
      blocks: [
        if (drivers.isEmpty)
          ConsoleCard(
            key: const Key('audio_no_asio_card'),
            children: [
              ConsoleBanner(
                key: const Key('audio_no_asio_banner'),
                message: l10n.audioNoAsioDriver,
                tone: ConsoleBannerTone.failure,
                actions: [
                  ConsoleSmallButton(
                    key: const Key('audio_asio4all_button'),
                    label: l10n.audioOpenAsio4all,
                    onPressed: () => unawaited(
                      launchUrl(
                        _asio4all,
                        mode: LaunchMode.externalApplication,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          )
        else
          ConsoleCard(
            children: [
              for (final (index, driver) in drivers.indexed)
                ConsolePickRow(
                  key: Key('audio_asio_driver_$index'),
                  title: driver.name,
                  state: l10n.audioDeviceChannels(
                    driver.inputChannels,
                    driver.outputChannels,
                  ),
                  selected: driver.id == state.asioDriver,
                  showDivider: index < drivers.length - 1,
                  onTap: () =>
                      context.read<AudioSetupCubit>().setAsioDriver(driver.id),
                ),
            ],
          ),
      ],
    );
  }

  // -------------------------------------------------------------- helpers

  /// The host's devices, paired by name, plus the pinned one it is no longer
  /// reporting.
  List<_Interface> _interfaces(BuildContext context, AudioSetupState state) {
    final paired = <String, _Interface>{};
    for (final device in state.playbackDevices) {
      final existing = paired[device.name];
      paired[device.name] = _Interface(
        name: device.name,
        playbackId: device.id,
        captureId: existing?.captureId ?? '',
        inputChannels: existing?.inputChannels ?? 0,
        outputChannels: device.outputChannels,
      );
    }
    for (final device in state.captureDevices) {
      final existing = paired[device.name];
      paired[device.name] = _Interface(
        name: device.name,
        playbackId: existing?.playbackId ?? '',
        captureId: device.id,
        inputChannels: device.inputChannels,
        outputChannels: existing?.outputChannels ?? 0,
      );
    }
    final devices = paired.values.toList();
    // A pinned device the host has stopped reporting stays listed and stays
    // checked: a pin still points at it, and dropping it from the list would
    // read as a device you never had.
    final pinnedPlayback = state.playbackDeviceId;
    final pinnedCapture = state.captureDeviceId;
    // Against the host's RAW list rather than the paired one: two interfaces
    // answering to the same name collapse into one entry, and asking the
    // collapsed list would call a device that is plugged in "unplugged".
    final present = state.devices.any(
      (device) => device.id == pinnedPlayback || device.id == pinnedCapture,
    );
    if (!present && (pinnedPlayback.isNotEmpty || pinnedCapture.isNotEmpty)) {
      devices.add(
        _Interface(
          // The last name it answered to. Falling back to the id rather than
          // to nothing: an unnamed greyed row says even less than an opaque
          // token does.
          name: state.connectivityDeviceName.isNotEmpty
              ? state.connectivityDeviceName
              : (pinnedPlayback.isNotEmpty ? pinnedPlayback : pinnedCapture),
          playbackId: pinnedPlayback,
          captureId: pinnedCapture,
          absent: true,
        ),
      );
    }
    return devices;
  }

  /// The listed interface the engine is pinned to, or null when nothing is.
  _Interface? _currentInterface(
    List<_Interface> devices,
    AudioSetupState state,
  ) {
    if (state.playbackDeviceId.isEmpty && state.captureDeviceId.isEmpty) {
      return null;
    }
    for (final device in devices) {
      if (device.playbackId == state.playbackDeviceId &&
          device.captureId == state.captureDeviceId) {
        return device;
      }
    }
    return null;
  }

  /// `18 in · 20 out`, or one side of it, or **nothing at all**.
  ///
  /// `0` is UNKNOWN, so it is omitted rather than printed: `0 in · 0 out` is a
  /// lie, and a device claiming no channels reads as one that cannot be used.
  String? _channelCounts(AppLocalizations l10n, _Interface device) {
    final inputs = device.inputChannels;
    final outputs = device.outputChannels;
    if (inputs > 0 && outputs > 0) {
      return l10n.audioDeviceChannels(inputs, outputs);
    }
    if (inputs > 0) return l10n.audioDeviceInputsOnly(inputs);
    if (outputs > 0) return l10n.audioDeviceOutputsOnly(outputs);
    return null;
  }

  /// What the closed Device row says when nothing is pinned: the device the
  /// engine has open, or the system default, since that is what a start would
  /// use.
  String _engineOrDefaultName(BuildContext context, AudioSetupState state) {
    final l10n = context.l10n;
    final reported = state.engineStatus.deviceName;
    if (reported.isNotEmpty) return reported;
    if (state.playbackDeviceId.isEmpty && state.captureDeviceId.isEmpty) {
      return l10n.systemDefault;
    }
    return l10n.emDash;
  }

  /// How many input sockets to list.
  ///
  /// Capped at the engine's own input ceiling: a socket past it can be neither
  /// laned nor monitored, so a name for it would be one the rig could never
  /// use. Falls back to a stereo pair while nothing is open — every other
  /// surface assumes the same when the engine reports 0.
  int _inputCount(AudioSetupState state, _Interface? current) {
    // The pinned device's OWN count first: it is known from enumeration even
    // while the engine is closed, which the engine's report is not.
    if (current != null && current.inputChannels > 0) {
      return math.min(current.inputChannels, InputsState.maxInputs);
    }
    // A device the host lists only as playback is a real ZERO, not an unknown
    // one — and it outranks the engine's report, which still describes the
    // interface this one is replacing until the device is reopened.
    if (current != null && !current.absent && current.captureId.isEmpty) {
      return 0;
    }
    final reported = state.engineStatus.inputChannels;
    if (reported > 0) return math.min(reported, InputsState.maxInputs);
    return 2;
  }

  String? _bufferCost(AppLocalizations l10n, int frames, int rate) {
    final ms = AudioSetupState.estimatedRoundTripMs(frames, rate);
    return ms > 0 ? l10n.latencyMs(ms.toStringAsFixed(1)) : null;
  }
}

/// The mark on an input that has been given a name.
///
/// Its slot is the same width lit or not, so the names beside it do not move
/// as sockets are named and un-named.
class _NamedCheck extends StatelessWidget {
  const _NamedCheck({required this.named});

  final bool named;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: ConsolePickRow.checkWidth,
    child: named ? const ConsoleCheck() : const SizedBox.shrink(),
  );
}
