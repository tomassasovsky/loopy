/// The control-surface invariant spec: loopy's LED / armed-set / cursor truth
/// rules, written ONCE and enforced twice — the sequence fuzzer
/// (`test/fuzz/`) checks every predicate after each settled step against the
/// REAL engine, and debug builds assert them on every frame projection
/// (`control_projection.dart`). Documentation and enforcement are the same
/// artifact.
///
/// Predicates are over SETTLED states: engine truth is polled (~16 ms), so a
/// command's effect reaches the projections one poll later. Callers settle
/// (pump + poll + microtask flush) before checking; asserting mid-transition
/// is a caller bug, not a violation.
///
/// The rules deliberately RESTATE the derivation (sounding, parked, the armed
/// formula) rather than importing `control_projection.dart` — a spec that
/// called the implementation it checks would be tautological.
///
/// History: the pre-refactor spec carried `pin`/`fuzzOnly` tags for rules the
/// stored-armed-set architecture could not honour at projection time (a
/// deliberate disarm was indistinguishable from a stale set). With the
/// overlay's explicit `excluded` set, every rule is projection-safe; the
/// retired `cursor-mirrored` pin is now unrepresentable — there is one
/// cursor.
library;

import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control_overlay.dart';
import 'package:loopy/looper/model/looper_mode.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// Everything the spec predicates over: engine truth, the stored-intent
/// overlay, and the projected wire frame.
class ControlContext {
  /// Creates a [ControlContext].
  const ControlContext({
    required this.looper,
    required this.overlay,
    required this.frame,
  });

  /// Engine truth (the polled snapshot projection).
  final LooperState looper;

  /// The stored user intent (mode, cursor, bank, excluded, parkedResume).
  final ControlOverlayState overlay;

  /// The projected LED frame (what the hardware pedal renders).
  final PedalStateFrame frame;
}

/// One named rule whose check returns `null` when satisfied, or a description
/// of the violation.
class ControlInvariant {
  /// Creates a [ControlInvariant].
  const ControlInvariant(this.name, this.check);

  /// Stable identifier, used in failure output and corpus annotations.
  final String name;

  /// Returns `null` when the rule holds for the context, else a violation
  /// message.
  final String? Function(ControlContext c) check;
}

Track? _trackAt(LooperState s, int channel) =>
    channel >= 0 && channel < s.tracks.length ? s.tracks[channel] : null;

bool _playable(Track t) => t.hasContent || t.isCapturing;

bool _sounding(Track t) =>
    t.hasContent &&
    !t.muted &&
    (t.state == TrackState.playing || t.state == TrackState.overdubbing);

bool _parked(LooperState s) =>
    s.tracks.any((t) => t.hasContent) &&
    !s.tracks.any(
      (t) =>
          t.hasContent &&
          (t.state == TrackState.playing || t.state == TrackState.overdubbing),
    );

/// The control-surface invariants, most fundamental first.
final List<ControlInvariant> controlInvariants = [
  ControlInvariant('depths-sane', (c) {
    for (final t in c.looper.tracks) {
      if (t.undoDepth < 0 || t.redoDepth < 0) {
        return 'track ${t.channel} negative depth';
      }
      if (t.state == TrackState.empty &&
          (t.lengthFrames != 0 || t.undoDepth != 0)) {
        return 'EMPTY track ${t.channel} has length ${t.lengthFrames} / '
            'undoDepth ${t.undoDepth}';
      }
    }
    return null;
  }),
  ControlInvariant('cursor-and-bank-in-range', (c) {
    final cursor = c.overlay.cursor;
    if (cursor < 0 || cursor >= 8) return 'cursor $cursor out of range';
    final bank = c.overlay.activeBank;
    if (bank < 0 || bank >= ControlOverlayState.bankCount) {
      return 'bank $bank out of range';
    }
    return null;
  }),
  ControlInvariant('frame-mirrors-overlay', (c) {
    if (c.frame.selectedTrack != c.overlay.cursor) {
      return 'frame cursor ${c.frame.selectedTrack} != overlay '
          '${c.overlay.cursor}';
    }
    if (c.frame.activeBank != c.overlay.activeBank) {
      return 'frame bank ${c.frame.activeBank} != overlay '
          '${c.overlay.activeBank}';
    }
    final want = c.overlay.mode == LooperMode.play
        ? PedalMode.play
        : PedalMode.rec;
    if (c.frame.mode != want) {
      return 'frame mode ${c.frame.mode} != overlay mode ${c.overlay.mode}';
    }
    return null;
  }),
  // The invalidation table as predicates: stored sets may only reference
  // tracks that still hold (or are finishing) a loop.
  ControlInvariant('stored-intent-playable', (c) {
    for (final channel in c.overlay.excluded.followedBy(
      c.overlay.parkedResume,
    )) {
      final t = _trackAt(c.looper, channel);
      if (t == null || !_playable(t)) {
        return 'stored intent references non-playable channel $channel';
      }
    }
    return null;
  }),
  ControlInvariant('empty-track-dark', (c) {
    for (final t in c.looper.tracks) {
      if (t.state != TrackState.empty ||
          t.channel >= c.frame.trackLeds.length) {
        continue;
      }
      final led = c.frame.trackLeds[t.channel];
      final isCursor =
          c.overlay.mode == LooperMode.record && t.channel == c.overlay.cursor;
      if (!isCursor && led != PedalTrackLed.off) {
        return 'EMPTY track ${t.channel} shows $led';
      }
    }
    return null;
  }),
  ControlInvariant('muted-dark-in-play', (c) {
    if (c.overlay.mode != LooperMode.play) return null;
    for (final t in c.looper.tracks) {
      if (t.muted &&
          t.channel < c.frame.trackLeds.length &&
          c.frame.trackLeds[t.channel] != PedalTrackLed.off) {
        return 'muted track ${t.channel} shows '
            '${c.frame.trackLeds[t.channel]}';
      }
    }
    return null;
  }),
  // The redo-relight rule, now projection-safe: anything sounding in the mix
  // that the user did NOT deliberately exclude reads green. Sound-but-dark
  // was the original bug class; under pure derivation it is structurally
  // unreachable — this pins it against regressions in the derivation itself.
  ControlInvariant('sounding-unexcluded-green', (c) {
    if (c.overlay.mode != LooperMode.play) return null;
    if (_parked(c.looper)) return null; // nothing sounds while parked
    for (final t in c.looper.tracks) {
      if (!_sounding(t) || c.overlay.excluded.contains(t.channel)) continue;
      if (t.channel < c.frame.trackLeds.length &&
          c.frame.trackLeds[t.channel] != PedalTrackLed.green) {
        return 'sounding track ${t.channel} LED is '
            '${c.frame.trackLeds[t.channel]}, not green';
      }
    }
    return null;
  }),
  // While parked, the LEDs preview exactly what Rec/Play resumes.
  ControlInvariant('parked-preview-matches-resume', (c) {
    if (c.overlay.mode != LooperMode.play || !_parked(c.looper)) return null;
    for (var ch = 0; ch < c.frame.trackLeds.length; ch++) {
      final t = _trackAt(c.looper, ch);
      final wantGreen =
          c.overlay.parkedResume.contains(ch) && !(t?.muted ?? false);
      final green = c.frame.trackLeds[ch] == PedalTrackLed.green;
      if (wantGreen != green) {
        return 'parked LED $ch is ${c.frame.trackLeds[ch]} but resume '
            'membership is ${c.overlay.parkedResume.contains(ch)}';
      }
    }
    return null;
  }),
  ControlInvariant('capturing-red-in-rec', (c) {
    if (c.overlay.mode != LooperMode.record) return null;
    for (final t in c.looper.tracks) {
      if (t.isCapturing &&
          t.channel < c.frame.trackLeds.length &&
          c.frame.trackLeds[t.channel] != PedalTrackLed.red) {
        return 'capturing track ${t.channel} LED is '
            '${c.frame.trackLeds[t.channel]}, not red';
      }
    }
    return null;
  }),
  ControlInvariant('ring-length-iff-loops', (c) {
    // The ring shows a length only when there is BOTH something holding (or
    // capturing) a loop AND an established grid: a defining recording has no
    // length until it finalizes (dark ring), and an undone-to-empty ghost
    // grid with zero content must not render either.
    final anyLoop = c.looper.tracks.any((t) => t.hasContent || t.isCapturing);
    final want = anyLoop && c.looper.transport.masterLengthFrames > 0;
    final lit = c.frame.loopLengthMicros > 0;
    if (want != lit) {
      return 'loopLengthMicros ${c.frame.loopLengthMicros} but anyLoop == '
          '$anyLoop with master ${c.looper.transport.masterLengthFrames}';
    }
    return null;
  }),
];

/// Evaluates the invariants against [c]; returns the violations
/// (`"name: message"`), empty when all hold.
List<String> checkControlInvariants(ControlContext c) => [
  for (final invariant in controlInvariants)
    if (invariant.check(c) case final String message)
      '${invariant.name}: $message',
];

/// Assert-mode hook for projection time: throws (listing every violation)
/// when the spec is broken, returns true otherwise. Usable inside
/// `assert(...)` for zero release-mode cost.
bool debugControlInvariantsHold(ControlContext c) {
  final violations = checkControlInvariants(c);
  if (violations.isNotEmpty) {
    throw StateError(
      'control invariants violated:\n  ${violations.join('\n  ')}',
    );
  }
  return true;
}
