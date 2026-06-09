import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/audio_setup_cubit.dart';

/// Self-contained palette so the setup surface reads identically whether it is
/// the first-run start screen or pushed from settings. Neutral near-black with
/// a single green accent used sparingly (selection + primary action).
class _C {
  static const bg = Color(0xFF0A0A0D);
  static const card = Color(0xFF141418);
  static const cardHi = Color(0xFF1C1C22);
  static const line = Color(0xFF272730);
  static const accent = Color(0xFF3B82F6); // blue
  static const accentSoft = Color(0x1A3B82F6); // blue @ 10%
  static const onAccent = Color(0xFFFFFFFF);
  static const danger = Color(0xFFFF5468);
  static const t1 = Color(0xFFF3F4F7);
  static const t2 = Color(0xFF989AA4);
  static const t3 = Color(0xFF5B5D67);
}

const _kicker = TextStyle(
  fontSize: 11,
  fontWeight: FontWeight.w700,
  letterSpacing: 1.8,
  color: _C.t3,
);

const _num = [FontFeature.tabularFigures()];

/// Stepped audio-device setup: a three-step flow (Engine → Input → Ready) while
/// the device is closed, collapsing to a live status panel once it is open.
class AudioSetupView extends StatefulWidget {
  /// Creates an [AudioSetupView].
  const AudioSetupView({super.key});

  @override
  State<AudioSetupView> createState() => _AudioSetupViewState();
}

class _AudioSetupViewState extends State<AudioSetupView> {
  static const _steps = ['Audio engine', 'Input', 'Ready to play'];
  int _step = 0;
  bool _forward = true;

  void _go(int next) => setState(() {
    _forward = next > _step;
    _step = next;
  });

  @override
  Widget build(BuildContext context) {
    final cubit = context.watch<AudioSetupCubit>();
    final state = cubit.state;
    final running = state.status == AudioSetupStatus.running;
    final isLast = _step == _steps.length - 1;
    final showError =
        state.status == AudioSetupStatus.error && state.errorMessage != null;

    return Scaffold(
      backgroundColor: _C.bg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 28),
            child: running
                ? _RunningPanel(state: state, cubit: cubit)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _TopBar(
                        kicker: 'AUDIO SETUP',
                        trailing: '${_step + 1} / ${_steps.length}',
                      ),
                      const SizedBox(height: 18),
                      _Progress(count: _steps.length, current: _step),
                      // The animated, scrollable body expands so the footer is
                      // always pinned to the bottom of the surface.
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 340),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: _slideFade,
                          child: SingleChildScrollView(
                            key: ValueKey(_step),
                            padding: const EdgeInsets.only(top: 30),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(_steps[_step], style: _title),
                                const SizedBox(height: 8),
                                Text(_blurb(_step), style: _body),
                                const SizedBox(height: 28),
                                switch (_step) {
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
                          if (_step > 0)
                            _Ghost(
                              label: 'Back',
                              onTap: () => _go(_step - 1),
                            ),
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
                              onTap: () => _go(_step + 1),
                            ),
                        ],
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _slideFade(Widget child, Animation<double> animation) {
    final entering = child.key == ValueKey(_step);
    final dx = (_forward ? 1.0 : -1.0) * (entering ? 0.10 : -0.10);
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: animation.drive(
          Tween(begin: Offset(dx, 0), end: Offset.zero),
        ),
        child: child,
      ),
    );
  }

  static String _blurb(int step) => switch (step) {
    0 => 'Pick the resolution and the latency / stability trade-off.',
    1 => 'Choose how your incoming signal is monitored and routed.',
    _ => 'Review your settings and open the device.',
  };
}

// ── Steps ────────────────────────────────────────────────────────────────────

class _EngineStep extends StatelessWidget {
  const _EngineStep({required this.state, required this.cubit});

  final AudioSetupState state;
  final AudioSetupCubit cubit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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

// ── Running panel ────────────────────────────────────────────────────────────

class _RunningPanel extends StatelessWidget {
  const _RunningPanel({required this.state, required this.cubit});

  final AudioSetupState state;
  final AudioSetupCubit cubit;

  @override
  Widget build(BuildContext context) {
    final s = state.engineStatus;
    final device = s.deviceName.isEmpty ? 'Default device' : s.deviceName;
    final measuring = s.latencyState == LatencyState.measuring;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _TopBar(kicker: 'AUDIO ENGINE'),
        const SizedBox(height: 40),
        Row(
          children: [
            const _Pulse(),
            const SizedBox(width: 10),
            Text('LIVE', style: _kicker.copyWith(color: _C.accent)),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          device,
          style: _title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 26),
        _InfoTable(
          rows: [
            ('Sample rate', '${s.sampleRate} Hz'),
            ('Buffer', '${s.bufferFrames} frames'),
            ('Round-trip latency', _latencyLabel(s)),
            ('Record offset', '${s.recordOffsetFrames} frames'),
          ],
        ),
        // Pin the actions to the bottom of the surface.
        const Spacer(),
        _Ghost(
          key: const Key('audioSetup_measureLatency_button'),
          label: measuring ? 'Measuring…' : 'Measure round-trip latency',
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
    );
  }
}

// ── Building blocks ──────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  const _TopBar({required this.kicker, this.trailing});

  final String kicker;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Row(
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
        Text(kicker, style: _kicker.copyWith(color: _C.t2)),
        const Spacer(),
        if (trailing != null)
          Text(
            trailing!,
            style: _kicker.copyWith(color: _C.t3, fontFeatures: _num),
          ),
        if (canPop)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: IconButton(
              key: const Key('audioSetup_close_button'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18, color: _C.t2),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.count, required this.current});

  final int count;
  final int current;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < count; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i == count - 1 ? 0 : 6),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                height: 3,
                decoration: BoxDecoration(
                  color: i <= current ? _C.accent : _C.line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label, style: _kicker.copyWith(color: _C.t2)),
        const SizedBox(width: 10),
        const Expanded(child: Divider(color: _C.line, height: 1)),
      ],
    );
  }
}

/// Lays children out as equal-width columns with consistent gaps.
class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < children.length; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i == children.length - 1 ? 0 : 8),
              child: children[i],
            ),
          ),
      ],
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.optionKey,
    required this.headline,
    required this.sub,
    required this.selected,
    required this.onTap,
  });

  final String optionKey;
  final String headline;
  final String sub;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: Key(optionKey),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 6),
        decoration: BoxDecoration(
          color: selected ? _C.accentSoft : _C.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? _C.accent : _C.line,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          children: [
            Text(
              headline,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? _C.accent : _C.t1,
                fontSize: 17,
                fontWeight: FontWeight.w700,
                fontFeatures: _num,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? _C.accent.withValues(alpha: 0.7) : _C.t3,
                fontSize: 10.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.toggleKey,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String toggleKey;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
      decoration: BoxDecoration(
        color: _C.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _C.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: _C.t1,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: _C.t2,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Switch(
            key: Key(toggleKey),
            value: value,
            onChanged: onChanged,
            activeThumbColor: _C.onAccent,
            activeTrackColor: _C.accent,
            inactiveThumbColor: _C.t2,
            inactiveTrackColor: _C.cardHi,
            trackOutlineColor: const WidgetStatePropertyAll(_C.line),
          ),
        ],
      ),
    );
  }
}

class _InfoTable extends StatelessWidget {
  const _InfoTable({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _C.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _C.line),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
              decoration: BoxDecoration(
                border: i == rows.length - 1
                    ? null
                    : const Border(bottom: BorderSide(color: _C.line)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      rows[i].$1,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _C.t2, fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      rows[i].$2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: _C.t1,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        fontFeatures: _num,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text, {this.icon = Icons.info_outline, super.key});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: _C.t3),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: _C.t3, fontSize: 12, height: 1.4),
          ),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('audioSetup_error_text'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0x1AFF5468),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _C.danger.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: _C.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: _C.danger, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _Primary extends StatelessWidget {
  const _Primary({
    required this.label,
    required this.icon,
    required this.onTap,
    this.iconTrailing = false,
    this.stretch = false,
    this.danger = false,
    super.key,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool iconTrailing;
  final bool stretch;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final bg = danger ? _C.danger : _C.accent;
    final fg = danger ? Colors.white : _C.onAccent;
    final iconWidget = Icon(icon, size: 19, color: fg);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          width: stretch ? double.infinity : null,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
          child: Row(
            mainAxisSize: stretch ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!iconTrailing) ...[iconWidget, const SizedBox(width: 8)],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (iconTrailing) ...[const SizedBox(width: 8), iconWidget],
            ],
          ),
        ),
      ),
    );
  }
}

class _Ghost extends StatelessWidget {
  const _Ghost({
    required this.label,
    required this.onTap,
    this.icon,
    this.stretch = false,
    super.key,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool stretch;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          width: stretch ? double.infinity : null,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _C.line),
          ),
          child: Row(
            mainAxisSize: stretch ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: _C.t2),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _C.t2,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pulse extends StatefulWidget {
  const _Pulse();

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_c.value);
        return Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: _C.accent,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: _C.accent.withValues(alpha: 0.2 + 0.5 * t),
                blurRadius: 5 + 8 * t,
                spreadRadius: 0.5 + t,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Text styles + helpers ────────────────────────────────────────────────────

const _title = TextStyle(
  color: _C.t1,
  fontSize: 27,
  fontWeight: FontWeight.w700,
  letterSpacing: -0.5,
);

const _body = TextStyle(color: _C.t2, fontSize: 14, height: 1.4);

String _khz(int rate) {
  final khz = rate / 1000;
  final text = khz == khz.roundToDouble()
      ? khz.toStringAsFixed(0)
      : khz.toStringAsFixed(1);
  return '$text kHz';
}

String _latencyMs(int frames, int sampleRate) {
  if (sampleRate <= 0) return '—';
  return (1000 * frames / sampleRate).toStringAsFixed(1);
}

String _rateNote(int rate) => switch (rate) {
  44100 => 'CD',
  48000 => 'Studio',
  96000 => 'Hi-res',
  _ => '',
};

String _bufferHint(int frames) => switch (frames) {
  <= 64 => 'Tightest timing — best feel, highest CPU and dropout risk.',
  128 => 'Low latency — a solid default for most interfaces.',
  256 => 'Balanced — safe headroom with still-tight timing.',
  _ => 'Most stable — pick this if you hear clicks or dropouts.',
};

String _latencyLabel(EngineStatus s) => switch (s.latencyState) {
  LatencyState.done => '${s.measuredLatencyMs.toStringAsFixed(2)} ms',
  LatencyState.measuring => 'measuring…',
  LatencyState.timeout => 'no loopback',
  LatencyState.idle => 'not measured',
};

String _loopbackNote(LoopbackInfo loopback) {
  final where = loopback.deviceName.isNotEmpty
      ? ' (${loopback.deviceName})'
      : '';
  if (loopback.isAutoRoutable) {
    return 'Loopback detected$where — latency is auto-measured on start as a '
        'digital-path estimate. Use a cable for the true analog figure.';
  }
  return 'A ${loopback.kind.name} loopback is available$where but cannot be '
      'auto-routed; use a physical loopback cable to measure latency.';
}
