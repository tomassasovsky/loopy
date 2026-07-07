import 'package:daw_export/src/daw_project.dart';

/// Thins a raw, densely-sampled continuous automation curve (e.g. every
/// logged `LE_CMD_SET_LANE_VOLUME`/`LE_CMD_SET_VOLUME` event for one
/// channel, in frame order) into a bounded set of breakpoints in two passes:
/// first an epsilon-tolerance simplification (linear interpolation between
/// kept points stays within [epsilon] of the raw curve), then a hard
/// [maxBreakpointsPerSecond] density cap applied on TOP of that result.
///
/// **The density cap can override the epsilon guarantee — this is by
/// design, not an oversight.** The two constraints are independent and the
/// cap runs second, so for a curve that legitimately needs more breakpoints
/// than the density cap allows to stay within epsilon everywhere (a
/// pathologically fast sweep — the "≤30 breakpoints/s for a 1 kHz sweep"
/// acceptance criterion is exactly this case), some interpolation error
/// beyond [epsilon] is accepted rather than letting breakpoint density grow
/// unbounded. For any realistic human-performed volume ride (bounded by how
/// fast a fader can actually move), the density cap at its default of 30/s
/// is far above what epsilon alone would ever keep, so the two constraints
/// don't conflict in practice — see
/// `automation_thinning_test.dart`'s "a realistic ride stays within epsilon
/// under the DEFAULT density cap" test for that composed, non-isolated
/// case, as opposed to the epsilon-only and density-only tests that
/// deliberately neutralize one constraint to test the other in isolation.
///
/// [raw] must already be sorted by [AutomationBreakpoint.beat], ascending —
/// this only thins a continuous ramp; it is never used for the
/// [AutomationTarget.activator] (mute) case, whose step-shaped breakpoints
/// are assembled directly from the logged toggle events with no thinning at
/// all (D-MUTE: a mute is a discrete state change, not a curve to
/// approximate).
///
/// The first and last points of [raw] are always kept exactly, regardless of
/// [epsilon] or [maxBreakpointsPerSecond] — an export that silently moved a
/// ride's starting or ending value would be a correctness bug, not a
/// simplification.
List<AutomationBreakpoint> thinVolumeAutomation({
  required List<AutomationBreakpoint> raw,
  required double tempoBpm,
  double epsilon = 0.01,
  double maxBreakpointsPerSecond = 30,
}) {
  if (raw.length <= 2) return List.unmodifiable(raw);

  final kept = List<bool>.filled(raw.length, false);
  kept[0] = true;
  kept[raw.length - 1] = true;
  _markRdpKeep(raw, 0, raw.length - 1, epsilon, kept);

  final epsilonThinned = [
    for (var i = 0; i < raw.length; i++)
      if (kept[i]) raw[i],
  ];

  return _capDensity(epsilonThinned, maxBreakpointsPerSecond, tempoBpm);
}

/// Ramer-Douglas-Peucker line simplification, recursively marking `kept[i]`
/// for any point between `lo` and `hi` whose vertical deviation from the
/// straight line `raw[lo]`-`raw[hi]` (i.e. the interpolation error a reader
/// would actually see, not Euclidean distance — [AutomationBreakpoint.beat]
/// and [AutomationBreakpoint.value] are different units, so a geometric
/// distance would conflate them) exceeds [epsilon].
void _markRdpKeep(
  List<AutomationBreakpoint> pts,
  int lo,
  int hi,
  double epsilon,
  List<bool> kept,
) {
  if (hi <= lo + 1) return;

  var maxDeviation = -1.0;
  var farthestIndex = -1;
  for (var i = lo + 1; i < hi; i++) {
    final deviation = _interpolationError(pts[i], pts[lo], pts[hi]);
    if (deviation > maxDeviation) {
      maxDeviation = deviation;
      farthestIndex = i;
    }
  }

  if (maxDeviation > epsilon) {
    kept[farthestIndex] = true;
    _markRdpKeep(pts, lo, farthestIndex, epsilon, kept);
    _markRdpKeep(pts, farthestIndex, hi, epsilon, kept);
  }
}

/// How far `p.value` deviates from what linear interpolation between `a` and
/// `b` would predict at `p.beat`.
double _interpolationError(
  AutomationBreakpoint p,
  AutomationBreakpoint a,
  AutomationBreakpoint b,
) {
  if (b.beat == a.beat) return (p.value - a.value).abs();
  final t = (p.beat - a.beat) / (b.beat - a.beat);
  final interpolated = a.value + t * (b.value - a.value);
  return (p.value - interpolated).abs();
}

/// Greedily drops any point closer than the minimum spacing
/// [maxPerSecond] implies (converted to beats via [bpm]) to the last KEPT
/// point — a hard cap independent of [_markRdpKeep]'s epsilon tolerance, so
/// a curve that legitimately deviates by more than epsilon at every sample
/// (e.g. a fast sweep) still can't produce unbounded breakpoint density.
/// Always keeps the first and last points of [pts].
List<AutomationBreakpoint> _capDensity(
  List<AutomationBreakpoint> pts,
  double maxPerSecond,
  double bpm,
) {
  if (pts.length <= 2 || maxPerSecond <= 0) return pts;

  final beatsPerSecond = bpm / 60.0;
  final minBeatSpacing = beatsPerSecond / maxPerSecond;

  final result = <AutomationBreakpoint>[pts.first];
  for (var i = 1; i < pts.length - 1; i++) {
    if (pts[i].beat - result.last.beat >= minBeatSpacing) {
      result.add(pts[i]);
    }
  }
  result.add(pts.last);
  return result;
}
