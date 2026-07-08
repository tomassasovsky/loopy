import 'dart:math' as math;

import 'package:daw_export/daw_export.dart';
import 'package:test/test.dart';

/// Evaluates the linear interpolation `thinned` implies at `beat`, or
/// throws if `beat` is out of the thinned curve's range — the test's own
/// ground truth for "does the thinned curve still predict the raw value
/// within epsilon," independent of the thinning algorithm's own internals.
double _interpolate(List<AutomationBreakpoint> thinned, double beat) {
  for (var i = 0; i < thinned.length - 1; i++) {
    final a = thinned[i];
    final b = thinned[i + 1];
    if (beat >= a.beat && beat <= b.beat) {
      if (b.beat == a.beat) return a.value;
      final t = (beat - a.beat) / (b.beat - a.beat);
      return a.value + t * (b.value - a.value);
    }
  }
  return thinned.last.value;
}

void main() {
  group('thinVolumeAutomation', () {
    test('returns raw unchanged when 2 or fewer points', () {
      const raw = [
        AutomationBreakpoint(beat: 0, value: 0.5),
        AutomationBreakpoint(beat: 4, value: 0.8),
      ];
      expect(thinVolumeAutomation(raw: raw, tempoBpm: 120), raw);
    });

    test('always keeps the exact first and last breakpoints', () {
      final raw = [
        for (var i = 0; i <= 200; i++)
          AutomationBreakpoint(
            beat: i * 0.05,
            value: 0.5 + 0.3 * math.sin(i * 0.3),
          ),
      ];
      final thinned = thinVolumeAutomation(raw: raw, tempoBpm: 120);
      expect(thinned.first.beat, raw.first.beat);
      expect(thinned.first.value, raw.first.value);
      expect(thinned.last.beat, raw.last.beat);
      expect(thinned.last.value, raw.last.value);
    });

    test(
      'a straight ramp thins to just its two endpoints (well within epsilon '
      'everywhere)',
      () {
        final raw = [
          for (var i = 0; i <= 100; i++)
            AutomationBreakpoint(beat: i * 0.1, value: i / 100.0),
        ];
        final thinned = thinVolumeAutomation(raw: raw, tempoBpm: 120);
        expect(thinned, hasLength(2));
      },
    );

    test(
      'thinned breakpoints stay within epsilon of the raw curve at every '
      'raw sample',
      () {
        const epsilon = 0.02;
        final raw = [
          for (var i = 0; i <= 300; i++)
            AutomationBreakpoint(
              beat: i * 0.02,
              value: 0.5 + 0.45 * math.sin(i * 0.15),
            ),
        ];
        final thinned = thinVolumeAutomation(
          raw: raw,
          tempoBpm: 120,
          epsilon: epsilon,
          // Density cap set generously high so this test isolates the
          // epsilon guarantee specifically, not the density cap's.
          maxBreakpointsPerSecond: 10000,
        );
        expect(thinned.length, lessThan(raw.length));
        for (final sample in raw) {
          final predicted = _interpolate(thinned, sample.beat);
          expect((predicted - sample.value).abs(), lessThanOrEqualTo(epsilon));
        }
      },
    );

    test(
      'density is bounded for a fast sweep even where every sample exceeds '
      'epsilon (the density cap, not epsilon, is what bounds it here)',
      () {
        // A 1 kHz-equivalent-density fixture: far more samples per second
        // than any reasonable epsilon-only simplification would keep sparse
        // on its own, forcing the hard density cap to do the work.
        final raw = [
          for (var i = 0; i <= 1000; i++)
            AutomationBreakpoint(
              beat: i * 0.001,
              value: 0.5 + 0.5 * math.sin(i * 3.0),
            ),
        ];
        const tempoBpm = 120.0;
        const maxPerSecond = 30.0;
        final thinned = thinVolumeAutomation(
          raw: raw,
          tempoBpm: tempoBpm,
          epsilon: 0.0001, // tiny — would keep nearly everything on its own
        );

        final totalSeconds =
            (raw.last.beat - raw.first.beat) / (tempoBpm / 60.0);
        final maxAllowed =
            (totalSeconds * maxPerSecond).ceil() + 2; // +first/last slack
        expect(thinned.length, lessThanOrEqualTo(maxAllowed));
        expect(thinned.length, lessThan(raw.length));
      },
    );

    test(
      'a realistic volume ride stays within epsilon under the DEFAULT '
      'density cap — the composed case, not either constraint in isolation',
      () {
        // A human fader move: ~4 seconds, sampled every ~20ms (the rate a
        // UI would realistically post SET_LANE_VOLUME at), a gentle S-curve
        // ride — nothing close to the pathological 1 kHz sweep above.
        final raw = [
          for (var i = 0; i <= 200; i++)
            AutomationBreakpoint(
              beat: i * 0.01, // 20ms steps at 120 BPM
              value: 0.3 + 0.5 * (0.5 - 0.5 * math.cos(i * math.pi / 200)),
            ),
        ];
        final thinned = thinVolumeAutomation(raw: raw, tempoBpm: 120);

        for (final sample in raw) {
          final predicted = _interpolate(thinned, sample.beat);
          expect(
            (predicted - sample.value).abs(),
            lessThanOrEqualTo(0.01), // the default epsilon
            reason:
                'a realistic ride should never need the density cap to '
                'override epsilon — if this fails, either the default '
                'density cap is too aggressive for real fader moves, or '
                'this fixture accidentally drifted into the pathological '
                'regime the fast-sweep test above covers',
          );
        }
      },
    );

    test('an empty curve thins to empty', () {
      expect(thinVolumeAutomation(raw: const [], tempoBpm: 120), isEmpty);
    });

    test('a single point thins to itself', () {
      const raw = [AutomationBreakpoint(beat: 1, value: 0.7)];
      expect(thinVolumeAutomation(raw: raw, tempoBpm: 120), raw);
    });
  });
}
