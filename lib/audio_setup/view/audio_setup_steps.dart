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
    final isLast = step == steps.length - 1;
    final showError =
        state.status == AudioSetupStatus.error && state.errorMessage != null;

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
                          Text(_blurb(step), style: _body),
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
                  _ErrorBanner(state.errorMessage!),
                ],
                const SizedBox(height: 20),
                Row(
                  children: [
                    if (step > 0)
                      _Ghost(label: 'Back', onTap: () => onGo(step - 1)),
                    const Spacer(),
                    if (isLast)
                      _Primary(
                        key: const Key('audioSetup_startStop_button'),
                        label: 'Start engine',
                        icon: Icons.play_arrow_rounded,
                        onTap: cubit.start,
                      )
                    else
                      _Primary(
                        key: const Key('audioSetup_next_button'),
                        label: 'Continue',
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
              Text('AUDIO SETUP', style: _kicker.copyWith(color: _C.t2)),
            ],
          ),
          const SizedBox(height: 28),
          const Text('Audio device', style: _title),
          const SizedBox(height: 10),
          const Text(
            'Configure your interface for low-latency looping.',
            style: _body,
          ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _GroupLabel('Output device'),
        const SizedBox(height: 12),
        AudioDevicePicker(
          pickerKey: 'audioSetup_playbackDevice_picker',
          devices: state.playbackDevices,
          selectedId: state.playbackDeviceId,
          onSelected: cubit.setPlaybackDevice,
        ),
        const SizedBox(height: 26),
        const _GroupLabel('Sample rate'),
        const SizedBox(height: 12),
        _OptionRow(
          children: [
            for (final rate in AudioSetupState.sampleRates)
              _Option(
                optionKey: 'audioSetup_sampleRate_$rate',
                headline: _khz(rate),
                sub: _rateNote(rate),
                selected: state.sampleRate == rate,
                onTap: () => cubit.setSampleRate(rate),
              ),
          ],
        ),
        const SizedBox(height: 26),
        const _GroupLabel('Buffer size'),
        const SizedBox(height: 12),
        _OptionRow(
          children: [
            for (final size in AudioSetupState.bufferSizes)
              _Option(
                optionKey: 'audioSetup_bufferSize_$size',
                headline: '$size',
                sub: '${_latencyMs(size, state.sampleRate)} ms',
                selected: state.bufferFrames == size,
                onTap: () => cubit.setBufferFrames(size),
              ),
          ],
        ),
        const SizedBox(height: 14),
        _Hint(_bufferHint(state.bufferFrames)),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _GroupLabel('Input device'),
        const SizedBox(height: 12),
        AudioDevicePicker(
          pickerKey: 'audioSetup_captureDevice_picker',
          devices: state.captureDevices,
          selectedId: state.captureDeviceId,
          onSelected: cubit.setCaptureDevice,
        ),
        const SizedBox(height: 26),
        _Toggle(
          toggleKey: 'audioSetup_monitor_switch',
          title: 'Monitor input',
          subtitle: 'Hear the live input through the outputs.',
          value: state.monitorInput,
          onChanged: (v) => cubit.setMonitorInput(monitorInput: v),
        ),
        const SizedBox(height: 12),
        _Toggle(
          toggleKey: 'audioSetup_mergeToMono_switch',
          title: 'Merge to mono',
          subtitle: 'Sum the inputs and feed both sides — for a mono source.',
          value: state.mergeToMono,
          onChanged: (v) => cubit.setMergeToMono(mergeToMono: v),
        ),
      ],
    );
  }
}

class _ReadyStep extends StatelessWidget {
  const _ReadyStep({required this.state});

  final AudioSetupState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InfoTable(
          rows: [
            ('Sample rate', _khz(state.sampleRate)),
            ('Buffer', '${state.bufferFrames} frames'),
            (
              'Estimated latency',
              '${_latencyMs(state.bufferFrames, state.sampleRate)} ms',
            ),
            ('Monitor input', state.monitorInput ? 'On' : 'Off'),
            ('Merge to mono', state.mergeToMono ? 'On' : 'Off'),
          ],
        ),
        if (state.loopback.available) ...[
          const SizedBox(height: 14),
          _Hint(
            _loopbackNote(state.loopback),
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
    final s = state.engineStatus;
    final device = s.deviceName.isEmpty ? 'Default device' : s.deviceName;
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
                    Text('LIVE', style: _kicker.copyWith(color: _C.accent)),
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
                const Text(
                  'The engine is open and ready. Stop it to reconfigure.',
                  style: _body,
                ),
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
                _InfoTable(
                  rows: [
                    ('Sample rate', '${s.sampleRate} Hz'),
                    ('Buffer', '${s.bufferFrames} frames'),
                    ('Round-trip latency', _latencyLabel(s)),
                    ('Record offset', '${s.recordOffsetFrames} frames'),
                  ],
                ),
                const Spacer(),
                _Ghost(
                  key: const Key('audioSetup_measureLatency_button'),
                  label: measuring
                      ? 'Measuring…'
                      : 'Measure round-trip latency',
                  icon: Icons.timer_outlined,
                  stretch: true,
                  onTap: cubit.measureLatency,
                ),
                const SizedBox(height: 12),
                _Primary(
                  key: const Key('audioSetup_startStop_button'),
                  label: 'Stop engine',
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
