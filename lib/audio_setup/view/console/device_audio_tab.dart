import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart'
    show EngineStatus, LatencyState;
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/theme/theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// Which of the tab's three openable rows is showing its list, if any.
///
/// One enum with a [none] member rather than three booleans, because opening
/// one must close the others: two lists open at once is a scroll, and a buffer
/// choice is only meaningful next to the rate it divides.
enum _OpenRow {
  /// Nothing is open.
  none,

  /// The device list.
  device,

  /// The sample rate and buffer grids.
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

/// The Device tab: what the rig plays through, how fast it runs, what its
/// inputs are called, and what the round trip actually measures.
///
/// **Four rows, because there is no Status tab.** Everything a status page
/// would report is either already the value of one of these rows or belongs
/// beside the setting that decides it — and a figure shown in two places is one
/// that can disagree with itself. What a status page cannot show is a config in
/// flight, so that is a banner here instead.
///
/// Three rows open **in place**. The mockups make the reason plain: a buffer
/// choice is only meaningful beside the rate it divides, and a route would hide
/// the other two settings while you changed one.
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

  /// The install banner's card: a 61px banner (the sentence plus the button
  /// that is taller than it) inside a card that insets 1px top and bottom.
  static const double _bannerCardExtent = 63;

  /// What a chip grid inside this card's drawers is inset by.
  static const EdgeInsets _gridInset = EdgeInsets.fromLTRB(
    ConsoleRow.indentedInset,
    0,
    kConsoleRowInset,
    kConsoleBlockGap,
  );

  void _toggle(_OpenRow row) =>
      setState(() => _open = _open == row ? _OpenRow.none : row);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<AudioSetupCubit>().state;
    // Read from the LOOPER's own gate over the outputs the RIG HAS, never over
    // the raw mask: it is default-on across all 32 bits and the app only gates
    // the sockets the device reports, so `mask == 0` is a value the rig cannot
    // produce — gating both outputs of a stereo interface leaves 0xFFFFFFFC.
    final silent = context.select<LooperBloc, bool>((bloc) {
      final looper = bloc.state;
      final outputs = looper.status.outputChannels;
      return outputs > 0 &&
          List.generate(outputs, looper.isOutputEnabled).every((on) => !on);
    });

    return KeyedSubtree(
      key: const Key('audio_device_tab'),
      child: ConsoleFace(
        previewKey: const Key('audio_upcoming_group'),
        lastGroupExtent: state.asioOnly ? _asioExtent(state) : 0,
        groups: [
          ConsoleGroup(
            caption: l10n.audioGroupLabel,
            blocks: [
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
              // The same sentence the setup page shows, so the two surfaces
              // cannot reach different conclusions about the same rig. Only
              // when there IS a loopback: the resolver's other branch names a
              // kind that is not there.
              if (state.loopback.available)
                ConsoleProse(l10n.loopbackNote(state.loopback)),
            ],
          ),
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
    final devices = _interfaces(state);
    final current = _currentInterface(devices, state);
    final inputCount = _inputCount(state, current);

    return ConsoleCard(
      children: [
        ?_phaseBanner(context, state),
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
            // Devices stay PICK ROWS while every other list here became a chip
            // grid: a device carries its channel counts and a long name, so it
            // is not a bare token and has something to put in a row's width.
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
          // No estimate. Two buffer periods cannot include converter latency,
          // so a figure here read as authoritative and was not; the measured
          // one is on the row that measures it.
          value: l10n.audioRateBufferValue(
            l10n.sampleRateKhzLabel(state.sampleRate),
            state.bufferFrames,
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
            Padding(
              padding: _gridInset,
              child: ConsoleChipGrid<int>(
                selected: {state.sampleRate},
                options: [
                  for (final rate in state.sampleRateChoices)
                    ConsoleSegment(
                      value: rate,
                      label: l10n.sampleRateKhzLabel(rate),
                      optionKey: Key('audio_sample_rate_$rate'),
                    ),
                ],
                onTap: context.read<AudioSetupCubit>().setSampleRate,
              ),
            ),
            ConsoleDrawerLabel(l10n.audioBufferGroup),
            Padding(
              padding: _gridInset,
              child: ConsoleChipGrid<int>(
                selected: {state.bufferFrames},
                options: [
                  for (final frames in state.bufferChoices)
                    ConsoleSegment(
                      value: frames,
                      label: '$frames',
                      optionKey: Key('audio_buffer_$frames'),
                    ),
                ],
                onTap: context.read<AudioSetupCubit>().setBufferFrames,
              ),
            ),
          ],
        ),
        _inputsRow(context, inputCount),
        _inputsChooser(context, inputCount),
        _latencyRow(context, state),
      ],
    );
  }

  // ------------------------------------------------------------ the banner

  /// What the last reopen turned out to be, or null when it is simply what the
  /// rows say.
  ///
  /// A banner rather than a row, per the console's own rule: anything just
  /// failed sits at the top of the list the setting lives in. There is no
  /// in-flight banner — see [ConfigPhase] for why one would be unreachable.
  Widget? _phaseBanner(BuildContext context, AudioSetupState state) {
    final l10n = context.l10n;
    // The open FAILED, so the device never came up. Rate and buffer describe
    // none of that — a device pick moves neither, which would leave the config
    // banner naming the same figures on both sides and claiming the rig is
    // "running at" them while nothing is running. This says what happened, and
    // it takes precedence: the console has no other place for the error, and a
    // rig that will not open is the one thing a player has to be told.
    final error = state.error;
    if (error != null) {
      return ConsoleBanner(
        key: const Key('audio_open_failed_banner'),
        message: switch (error) {
          AudioSetupError.openDeviceFailed => l10n.failedToOpenDevice(
            state.errorDetail ?? '',
          ),
        },
        tone: ConsoleBannerTone.failure,
      );
    }
    if (state.phase == ConfigPhase.settled) return null;
    // Both sides come from the phase fields, not from the selection: the
    // selection holds what the CHOOSER can offer, which is the request itself
    // whenever the device negotiated something the option lists do not carry.
    // This is the only place either figure is still named.
    return ConsoleBanner(
      key: const Key('audio_refused_banner'),
      message: l10n.audioRefusedConfig(
        l10n.audioRateBufferValue(
          l10n.sampleRateKhzLabel(state.requestedRate),
          state.requestedBuffer,
        ),
        l10n.audioRateBufferValue(
          l10n.sampleRateKhzLabel(state.actualRate),
          state.actualBuffer,
        ),
      ),
      tone: ConsoleBannerTone.failure,
    );
  }

  // ----------------------------------------------------------- the inputs

  Widget _inputsRow(BuildContext context, int count) {
    final l10n = context.l10n;
    final surface = context.surface;
    final named = context.watch<InputsCubit>().state.namedCount(count);
    return ConsoleRow(
      key: const Key('audio_inputs_row'),
      title: l10n.audioInputsRow,
      value: l10n.audioInputsNamed(named),
      expanded: _open == _OpenRow.inputs,
      fill: _open == _OpenRow.inputs ? surface.control : null,
      onTap: () => _toggle(_OpenRow.inputs),
    );
  }

  Widget _inputsChooser(BuildContext context, int count) {
    final l10n = context.l10n;
    final inputs = context.watch<InputsCubit>().state;
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
          Padding(
            padding: ConsoleChooser.gridInset,
            // A grid, not a row list: eighteen sockets as 70px rows is 1,260px,
            // five times the height of the card they open inside. As a grid
            // they are two runs and about 106px.
            //
            // Not a pick-one — nothing here is "selected", a tap renames. The
            // chip carries the SOCKET on its second line whether or not it has
            // a name, because the number is what the cable is plugged into and
            // the name is only what you call it.
            child: ConsoleChipGrid<int>(
              selected: const {},
              options: [
                for (var input = 0; input < count; input++)
                  ConsoleSegment(
                    value: input,
                    // An empty label leaves the ordinal alone in the chip and
                    // promotes it to the primary ink — a rig where nothing is
                    // named must not read as a grid of disabled chips.
                    label: inputs.nameOf(input),
                    sublabel: l10n.inputOrdinal(input + 1),
                    optionKey: Key('audio_input_$input'),
                  ),
              ],
              onTap: (input) => unawaited(_rename(context, inputs, input)),
            ),
          ),
      ],
    );
  }

  Future<void> _rename(
    BuildContext context,
    InputsState inputs,
    int input,
  ) async {
    final l10n = context.l10n;
    final cubit = context.read<InputsCubit>();
    final name = await showConsoleRenameSheet(
      context,
      title: l10n.audioRenameInputTitle,
      subtitle: l10n.inputOrdinal(input + 1),
      current: inputs.nameOf(input),
      fieldLabel: l10n.a11yInputRenameField,
      // `AUDIO / settings-rename` has no Clear button — it has a backspace and
      // Save — so emptying the field IS how an input is un-named, and the
      // socket takes its ordinal back.
      allowEmpty: true,
    );
    if (name == null) return;
    await cubit.rename(input, name);
  }

  // ---------------------------------------------------------- the latency

  /// The measurement: what it last reported, what that cost the take, and the
  /// button that runs it again.
  ///
  /// One row for both. The readout and the action were two rows on the old
  /// Status tab, which is one row too many for one fact — but the button is
  /// **explicit**, because a bare tappable row says nothing about being one.
  Widget _latencyRow(BuildContext context, AudioSetupState state) {
    final l10n = context.l10n;
    final cubit = context.read<AudioSetupCubit>();
    final status = state.engineStatus;
    final measuring = status.latencyState == LatencyState.measuring;
    return ConsoleRow(
      key: const Key('audio_latency_row'),
      title: l10n.roundTripLatencyLabel,
      // The offset is a CONSEQUENCE of the measurement, not a setting, so it
      // rides this row rather than taking one of its own.
      subtitle: l10n.audioRecordOffsetSub(status.recordOffsetFrames),
      semanticLabel: l10n.a11yAudioMeasureLatency,
      showDivider: false,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _latency(l10n, status),
            style: TextStyle(
              color: context.surface.textSecondary,
              fontFamily: SurfaceTheme.monoFont,
              fontSize: 14,
              height: 1.14,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
          const SizedBox(width: kConsoleRowGap),
          ConsoleSmallButton(
            key: const Key('audio_measure_button'),
            label: l10n.audioMeasure,
            // Refuses while one is in flight rather than restarting the thing
            // it is reporting.
            onPressed: measuring ? null : cubit.measureLatency,
          ),
        ],
      ),
      customSemanticsActions: measuring
          ? null
          : {
              CustomSemanticsAction(label: l10n.audioMeasure):
                  cubit.measureLatency,
            },
    );
  }

  String _latency(AppLocalizations l10n, EngineStatus status) =>
      switch (status.latencyState) {
        LatencyState.measuring => l10n.measuringEllipsis,
        LatencyState.done => l10n.latencyMs(
          status.measuredLatencyMs.toStringAsFixed(2),
        ),
        LatencyState.timeout => l10n.noSignalDetected,
        LatencyState.idle => l10n.notMeasured,
      };

  // ------------------------------------------------------------ ASIO group

  double _asioExtent(AudioSetupState state) {
    final drivers = state.cachedAsioDrivers.length;
    return ConsolePinnedGroupLabel.extent +
        (drivers == 0 ? _bannerCardExtent : kConsoleRowHeight * drivers + 2);
  }

  ConsoleGroup _asioGroup(BuildContext context, AudioSetupState state) {
    final l10n = context.l10n;
    // The cached enumeration, which stays populated even while ASIO holds the
    // device — re-probing live would tear the stream down (R1).
    final drivers = state.cachedAsioDrivers;
    return ConsoleGroup(
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
  List<_Interface> _interfaces(AudioSetupState state) {
    final paired = <String, _Interface>{};
    for (final device in state.playbackDevices) {
      // By NAME, which is what makes one interface one row. But a name whose
      // playback slot is already filled belongs to another BOX rather than to
      // this one's other half — two identical interfaces answer to one name —
      // so it is keyed apart instead of overwriting the entry already listed,
      // which would drop the first one out of the list entirely.
      final key = (paired[device.name]?.playbackId.isNotEmpty ?? false)
          ? '${device.name} ${device.id}'
          : device.name;
      final existing = paired[key];
      paired[key] = _Interface(
        name: device.name,
        playbackId: device.id,
        captureId: existing?.captureId ?? '',
        inputChannels: existing?.inputChannels ?? 0,
        outputChannels: device.outputChannels,
      );
    }
    for (final device in state.captureDevices) {
      // Same rule on the capture side: an entry whose capture slot is free is
      // this device's playback half waiting to be paired; one already holding
      // a capture id is a different box.
      final key = (paired[device.name]?.captureId.isNotEmpty ?? false)
          ? '${device.name} ${device.id}'
          : device.name;
      final existing = paired[key];
      paired[key] = _Interface(
        name: device.name,
        playbackId: existing?.playbackId ?? '',
        captureId: device.id,
        inputChannels: device.inputChannels,
        outputChannels: existing?.outputChannels ?? 0,
      );
    }
    final devices = paired.values.toList();
    final pinnedPlayback = state.playbackDeviceId;
    final pinnedCapture = state.captureDeviceId;
    // Against the host's RAW list rather than the paired one: the pairing
    // above re-keys and re-shapes entries, and asking it whether an id is
    // still there would call a device that is plugged in "unplugged".
    final present = state.devices.any(
      (device) => device.id == pinnedPlayback || device.id == pinnedCapture,
    );
    // A pinned device the host has stopped reporting stays listed and stays
    // checked: a pin still points at it, and dropping it from the list would
    // read as a device you never had.
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
  /// Whatever the device reports — **no ceiling of its own**. An earlier
  /// version stopped at the engine's `LE_MAX_INPUTS`, on the reading that a
  /// socket past it was unusable; that constant caps how many lanes one TRACK
  /// may have and which inputs can be MONITORED, and a higher-numbered channel
  /// is still recordable (#558). Bounded only by what a name can be stored
  /// against.
  int _inputCount(AudioSetupState state, _Interface? current) {
    // The pinned device's OWN count first: it is known from enumeration even
    // while the engine is closed, which the engine's report is not.
    if (current != null && current.inputChannels > 0) {
      return math.min(current.inputChannels, InputsState.probeCeiling);
    }
    // Then what the engine has open — but only while it is open on THIS
    // interface, since its report otherwise still describes the one this is
    // replacing. It outranks the pairing below, because an empty capture id is
    // the SYSTEM DEFAULT and not "no capture": pinning a playback-only half
    // (the built-in speakers, whose capture half answers to a different name)
    // leaves recording on the default microphone, and the engine is the only
    // thing that knows how wide that is.
    final status = state.engineStatus;
    final onThisDevice = current == null || status.deviceName == current.name;
    if (onThisDevice && status.inputChannels > 0) {
      return math.min(status.inputChannels, InputsState.probeCeiling);
    }
    // A device the host lists only as playback, with no capture reported for
    // it either: a real ZERO rather than an unknown one.
    if (current != null && !current.absent && current.captureId.isEmpty) {
      return 0;
    }
    return 2;
  }
}
