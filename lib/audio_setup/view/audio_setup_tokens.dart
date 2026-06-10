part of 'audio_setup_view.dart';

/// Self-contained palette so the setup surface reads identically whether it is
/// the first-run start screen or pushed from settings. Neutral grey/black with
/// a single blue accent used sparingly (selection + primary action).
class _C {
  static const bg = Color(0xFF08080A);
  static const surface = Color(0xFF0D0D11);
  static const card = Color(0xFF16161B);
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

const _title = TextStyle(
  color: _C.t1,
  fontSize: 26,
  fontWeight: FontWeight.w700,
  letterSpacing: -0.5,
);

const _body = TextStyle(color: _C.t2, fontSize: 14, height: 1.45);

const _num = [FontFeature.tabularFigures()];

String _blurb(int step) => switch (step) {
  0 => 'Pick the resolution and the latency / stability trade-off.',
  1 => 'Choose how your incoming signal is monitored and routed.',
  _ => 'Review your settings and open the device.',
};

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

/// Shared directional slide-and-fade for the step [AnimatedSwitcher]: the
/// entering step (whose key matches the current [step]) slides in from the
/// [forward] direction while the leaving step slides out the other way.
Widget _slideFade(
  Widget child,
  Animation<double> animation,
  int step,
  bool forward,
) {
  final entering = child.key == ValueKey(step);
  final dx = (forward ? 1.0 : -1.0) * (entering ? 0.08 : -0.08);
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
