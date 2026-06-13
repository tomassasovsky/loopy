part of 'audio_setup_view.dart';

/// The two-pane wizard body: a context rail on the left and the active step's
/// controls plus footer on the right.
class _Wizard extends StatelessWidget {
  const _Wizard({
    required this.steps,
    required this.step,
    required this.forward,
    required this.onGo,
    required this.state,
    required this.cubit,
  });

  final List<String> steps;
  final int step;
  final bool forward;
  final ValueChanged<int> onGo;
  final AudioSetupState state;
  final AudioSetupCubit cubit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isLast = step == steps.length - 1;
    final showError =
        state.status == AudioSetupStatus.error && state.error != null;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 264,
          child: _Rail(steps: steps, current: step),
        ),
        const VerticalDivider(width: 1, thickness: 1, color: _C.line),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(34, 34, 30, 26),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 320),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) =>
                        _slideFade(child, animation, step, forward),
                    child: SingleChildScrollView(
                      key: ValueKey(step),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(_blurb(l10n, step), style: _body),
                          const SizedBox(height: 24),
                          switch (step) {
                            0 => _EngineStep(state: state, cubit: cubit),
                            1 => _InputStep(state: state, cubit: cubit),
                            _ => _ReadyStep(state: state),
                          },
                        ],
                      ),
                    ),
                  ),
                ),
                if (showError) ...[
                  const SizedBox(height: 16),
                  _ErrorBanner(
                    error: state.error!,
                    detail: state.errorDetail ?? '',
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  children: [
                    if (step > 0)
                      _Ghost(
                        label: l10n.back,
                        onTap: () => onGo(step - 1),
                      ),
                    const Spacer(),
                    if (isLast)
                      _Primary(
                        key: const Key('audioSetup_startStop_button'),
                        label: l10n.startEngine,
                        icon: Icons.play_arrow_rounded,
                        onTap: cubit.start,
                      )
                    else
                      _Primary(
                        key: const Key('audioSetup_next_button'),
                        label: l10n.continueButton,
                        icon: Icons.arrow_forward_rounded,
                        iconTrailing: true,
                        onTap: () => onGo(step + 1),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The left rail: brand, a constant heading, and the step list.
class _Rail extends StatelessWidget {
  const _Rail({required this.steps, required this.current});

  final List<String> steps;
  final int current;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 32, 22, 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  color: _C.accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 9),
              Text(
                l10n.audioSetupKicker,
                style: _kicker.copyWith(color: _C.t2),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Text(l10n.audioDeviceTitle, style: _title),
          const SizedBox(height: 10),
          Text(l10n.audioSetupRailIntro, style: _body),
          const Spacer(),
          _StepList(steps: steps, current: current),
        ],
      ),
    );
  }
}

class _EngineStep extends StatelessWidget {
  const _EngineStep({required this.state, required this.cubit});

  final AudioSetupState state;
  final AudioSetupCubit cubit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Each ASIO driver is one duplex device; label it with its probed counts so
    // the picker reads e.g. "Focusrite USB ASIO · 18 in / 20 out".
    final asioDriverDevices = [
      for (final d in state.asioDrivers)
        AudioDevice(
          id: d.id,
          name:
              '${d.name} · '
              '${l10n.asioChannelCounts(d.inputChannels, d.outputChannels)}',
          isDefault: d.isDefault,
          isInput: d.isInput,
          inputChannels: d.inputChannels,
          outputChannels: d.outputChannels,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Backend selector — only when ASIO is selectable (Windows + at least
        // one enumerated driver; the cubit loads none otherwise).
        if (state.asioDrivers.isNotEmpty) ...[
          _GroupLabel(l10n.backendGroup),
          const SizedBox(height: 12),
          _OptionRow(
            children: [
              _Option(
                optionKey: 'audioSetup_backend_wasapi',
                headline: l10n.backendWasapi,
                sub: l10n.backendWasapiNote,
                selected: !state.isAsio,
                onTap: () => cubit.setBackend(AudioBackend.wasapi),
              ),
              _Option(
                optionKey: 'audioSetup_backend_asio',
                headline: l10n.backendAsio,
                sub: l10n.backendAsioNote,
                selected: state.isAsio,
                onTap: () => cubit.setBackend(AudioBackend.asio),
              ),
            ],
          ),
          const SizedBox(height: 26),
        ],
        // Under ASIO a single driver drives all I/O, so the two device pickers
        // collapse to one ASIO driver picker; else the output picker shows.
        if (state.isAsio) ...[
          _GroupLabel(l10n.asioDriverGroup),
          const SizedBox(height: 12),
          AudioDevicePicker(
            pickerKey: 'audioSetup_asioDriver_picker',
            devices: asioDriverDevices,
            selectedId: state.asioDriver,
            onSelected: cubit.setAsioDriver,
          ),
        ] else ...[
          _GroupLabel(l10n.outputDeviceGroup),
          const SizedBox(height: 12),
          AudioDevicePicker(
            pickerKey: 'audioSetup_playbackDevice_picker',
            devices: state.playbackDevices,
            selectedId: state.playbackDeviceId,
            onSelected: cubit.setPlaybackDevice,
          ),
        ],
        const SizedBox(height: 26),
        _GroupLabel(l10n.sampleRateGroup),
        const SizedBox(height: 12),
        _OptionRow(
          children: [
            // Under ASIO these are the driver's real supported rates; otherwise
            // the generic list.
            for (final rate in state.sampleRateChoices)
              _Option(
                optionKey: 'audioSetup_sampleRate_$rate',
                headline: _khz(l10n, rate),
                sub: _rateNote(l10n, rate),
                selected: state.sampleRate == rate,
                onTap: () => cubit.setSampleRate(rate),
              ),
          ],
        ),
        const SizedBox(height: 26),
        _GroupLabel(l10n.bufferSizeGroup),
        const SizedBox(height: 12),
        _OptionRow(
          children: [
            // Under ASIO these are the driver's real buffer sizes (e.g. a
            // single size if locked in the driver's control panel).
            for (final size in state.bufferChoices)
              _Option(
                optionKey: 'audioSetup_bufferSize_$size',
                headline: '$size',
                sub: _latencyMs(l10n, size, state.sampleRate),
                selected: state.bufferFrames == size,
                onTap: () => cubit.setBufferFrames(size),
              ),
          ],
        ),
        const SizedBox(height: 14),
        _Hint(_bufferHint(l10n, state.bufferFrames)),
        // Exclusive mode is a Windows-only WASAPI capability, hidden elsewhere
        // so macOS/Linux behavior is unchanged — and hidden under ASIO, which
        // has no share-mode concept.
        if (defaultTargetPlatform == TargetPlatform.windows &&
            !state.isAsio) ...[
          const SizedBox(height: 26),
          _Toggle(
            toggleKey: 'audioSetup_exclusive_switch',
            title: l10n.exclusiveModeTitle,
            subtitle: l10n.exclusiveModeSubtitle,
            value: state.exclusive,
            onChanged: (v) => cubit.setExclusive(exclusive: v),
          ),
        ],
      ],
    );
  }
}

class _InputStep extends StatelessWidget {
  const _InputStep({required this.state, required this.cubit});

  final AudioSetupState state;
  final AudioSetupCubit cubit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Under ASIO the one driver provides every input, so the input picker
        // is replaced by a read-only note.
        if (state.isAsio)
          _Hint(
            l10n.asioDriverHandlesAllIo,
            key: const Key('audioSetup_asioInput_note'),
          )
        else ...[
          _GroupLabel(l10n.inputDeviceGroup),
          const SizedBox(height: 12),
          AudioDevicePicker(
            pickerKey: 'audioSetup_captureDevice_picker',
            devices: state.captureDevices,
            selectedId: state.captureDeviceId,
            onSelected: cubit.setCaptureDevice,
          ),
        ],
      ],
    );
  }
}

class _ReadyStep extends StatelessWidget {
  const _ReadyStep({required this.state});

  final AudioSetupState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetupInfoTable(
          rows: [
            (l10n.sampleRateLabel, _khz(l10n, state.sampleRate)),
            (
              l10n.bufferLabel,
              l10n.bufferFrames(state.bufferFrames),
            ),
            (
              l10n.estimatedLatencyLabel,
              _latencyMs(l10n, state.bufferFrames, state.sampleRate),
            ),
          ],
        ),
        if (state.loopback.available) ...[
          const SizedBox(height: 14),
          _Hint(
            _loopbackNote(l10n, state.loopback),
            key: const Key('audioSetup_loopback_note'),
            icon: Icons.cable_outlined,
          ),
        ],
      ],
    );
  }
}

/// The live status panel shown while the device is open: device + LIVE on the
/// left, the status table and actions on the right.
class _RunningPanel extends StatelessWidget {
  const _RunningPanel({required this.state, required this.cubit});

  final AudioSetupState state;
  final AudioSetupCubit cubit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final s = state.engineStatus;
    final device = s.deviceName.isEmpty ? l10n.defaultDevice : s.deviceName;
    final measuring = s.latencyState == LatencyState.measuring;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(34, 34, 22, 30),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const _Pulse(),
                    const SizedBox(width: 10),
                    Text(
                      l10n.liveKicker,
                      style: _kicker.copyWith(color: _C.accent),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  device,
                  style: _title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                Text(l10n.engineRunningHint, style: _body),
                const Spacer(),
              ],
            ),
          ),
        ),
        const VerticalDivider(width: 1, thickness: 1, color: _C.line),
        Expanded(
          flex: 6,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(30, 34, 30, 26),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SetupInfoTable(
                  rows: [
                    (
                      l10n.sampleRateLabel,
                      l10n.sampleRateHz(s.sampleRate),
                    ),
                    (
                      l10n.bufferLabel,
                      l10n.bufferFrames(s.bufferFrames),
                    ),
                    (
                      l10n.roundTripLatencyLabel,
                      _latencyLabel(l10n, s),
                    ),
                    (
                      l10n.recordOffsetLabel,
                      l10n.bufferFrames(s.recordOffsetFrames),
                    ),
                    (
                      l10n.backendLabel,
                      s.activeBackend == AudioBackend.asio
                          ? l10n.backendAsio
                          : l10n.backendWasapi,
                    ),
                  ],
                ),
                // Surface the negotiated mode only when it diverges from
                // intent: exclusive was requested but the device opened shared.
                // Suppressed under ASIO, where the (WASAPI-only) exclusive
                // intent stays dormant and would read as a spurious fallback.
                if (state.exclusive && !s.exclusiveActive && !state.isAsio) ...[
                  const SizedBox(height: 12),
                  _Hint(
                    l10n.exclusiveSharedFallback,
                    key: const Key('audioSetup_exclusiveFallback_note'),
                  ),
                ],
                // ASIO was requested but the device opened on WASAPI (build
                // off, missing/busy driver, or init failure): show the reality.
                if (state.backend == AudioBackend.asio &&
                    s.activeBackend != AudioBackend.asio) ...[
                  const SizedBox(height: 12),
                  _Hint(
                    l10n.asioUnavailableFallback,
                    key: const Key('audioSetup_asioFallback_note'),
                  ),
                ],
                const Spacer(),
                _Ghost(
                  key: const Key('audioSetup_measureLatency_button'),
                  label: measuring
                      ? l10n.measuringEllipsis
                      : l10n.measureRoundTripLatency,
                  icon: Icons.timer_outlined,
                  stretch: true,
                  onTap: cubit.measureLatency,
                ),
                const SizedBox(height: 12),
                _Primary(
                  key: const Key('audioSetup_startStop_button'),
                  label: l10n.stopEngine,
                  icon: Icons.stop_rounded,
                  stretch: true,
                  danger: true,
                  onTap: cubit.stop,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
