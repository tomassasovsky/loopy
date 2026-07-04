/// The control-surface invariant spec: loopy's LED / armed-set / cursor truth
/// rules, written ONCE and enforced twice — the sequence fuzzer
/// (`test/fuzz/`) checks every predicate after each settled step against the
/// REAL engine, and debug builds assert them on every pedal frame projection.
/// Documentation and enforcement are the same artifact.
///
/// Predicates are over SETTLED states: engine truth is polled (~16 ms), so a
/// command's effect reaches the projections one poll later. Callers settle
/// (pump + poll + microtask flush) before checking; asserting mid-transition
/// is a caller bug, not a violation.
///
/// Each invariant carries a `pin` tag:
///  - timeless (pin: false): must survive the phase-2 projection refactor;
///  - current-behavior pin (pin: true): pins today's architecture (stored
///    armed set, mirrored cursor); phase 2 replaces it with a successor
///    written against the ControlOverlay.
library;

import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/cubit/tracks_cubit.dart';
import 'package:loopy/looper/model/looper_mode.dart';
import 'package:loopy/pedal/cubit/pedal_cubit.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// Everything the spec predicates over: engine truth ([looper]) plus each
/// surface's state and the projected wire frame.
class ControlContext {
  /// Creates a [ControlContext].
  const ControlContext({
    required this.looper,
    required this.pedal,
    required this.frame,
    this.tracks,
  });

  /// Engine truth (the polled snapshot projection).
  final LooperState looper;

  /// The pedal overlay (mode, cursor, armed set, bank).
  final PedalState pedal;

  /// The on-screen cursor state; null where unavailable (the pedal cubit's
  /// projection-time assert has no TracksCubit access), skipping the
  /// cursor-mirror rule.
  final TracksState? tracks;

  /// The projected LED frame (what the hardware pedal renders).
  final PedalStateFrame frame;
}

/// One named rule whose check returns `null` when satisfied, or a description
/// of the violation.
class ControlInvariant {
  /// Creates a [ControlInvariant].
  const ControlInvariant(
    this.name,
    this.check, {
    this.pin = false,
    this.fuzzOnly = false,
  });

  /// Stable identifier, used in failure output and corpus annotations.
  final String name;

  /// Whether this pins CURRENT behavior (replaced in phase 2) rather than a
  /// timeless truth.
  final bool pin;

  /// True for rules that only hold under the fuzzer's action alphabet — e.g.
  /// sounding⟹armed is violated by a DELIBERATE on-screen disarm
  /// (`togglePlayArm`), which pre-phase-2 state cannot distinguish from a
  /// stale armed set. The projection-time debug assert skips these; phase 2's
  /// explicit excluded-set makes them projection-safe successors.
  final bool fuzzOnly;

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
  ControlInvariant('cursor-in-range', (c) {
    final cursor = c.pedal.selectedTrack;
    if (cursor < 0 || cursor >= c.looper.tracks.length && cursor >= 8) {
      return 'cursor $cursor out of range';
    }
    if (c.pedal.activeBank != cursor ~/ PedalState.tracksPerBank) {
      return 'bank ${c.pedal.activeBank} does not match cursor $cursor';
    }
    return null;
  }),
  ControlInvariant('cursor-mirrored', (c) {
    final tracks = c.tracks;
    if (tracks == null) return null; // context without the on-screen cursor
    if (tracks.selectedChannel != c.pedal.selectedTrack) {
      return 'on-screen cursor ${tracks.selectedChannel} != pedal cursor '
          '${c.pedal.selectedTrack}';
    }
    return null;
  }, pin: true),
  ControlInvariant('empty-track-dark', (c) {
    for (final t in c.looper.tracks) {
      if (t.state != TrackState.empty ||
          t.channel >= c.frame.trackLeds.length) {
        continue;
      }
      final led = c.frame.trackLeds[t.channel];
      final isCursor =
          c.pedal.mode == LooperMode.record &&
          t.channel == c.pedal.selectedTrack;
      if (!isCursor && led != PedalTrackLed.off) {
        return 'EMPTY track ${t.channel} shows $led';
      }
    }
    return null;
  }),
  ControlInvariant('muted-dark-in-play', (c) {
    if (c.pedal.mode != LooperMode.play) return null;
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
  ControlInvariant('armed-only-playable', (c) {
    for (final channel in c.pedal.playArmed) {
      final t = _trackAt(c.looper, channel);
      if (t == null || !_playable(t)) {
        return 'armed channel $channel is not playable';
      }
    }
    return null;
  }, pin: true),
  // The redo-relight rule: anything actually sounding in the mix is under
  // pedal control and reads green. Sound-but-dark was the original bug class.
  // fuzzOnly: the fuzz alphabet never calls the UI-only deliberate-disarm API
  // (togglePlayArm), so there a sounding track outside the armed set is
  // always a reconciliation bug; at projection time a deliberate disarm is
  // legitimate and indistinguishable until phase 2's excluded-set.
  ControlInvariant('sounding-armed-and-green', (c) {
    if (c.pedal.mode != LooperMode.play) return null;
    for (final t in c.looper.tracks) {
      if (!_sounding(t)) continue;
      if (!c.pedal.playArmed.contains(t.channel)) {
        return 'sounding track ${t.channel} is not armed';
      }
      if (t.channel < c.frame.trackLeds.length &&
          c.frame.trackLeds[t.channel] != PedalTrackLed.green) {
        return 'sounding track ${t.channel} LED is '
            '${c.frame.trackLeds[t.channel]}, not green';
      }
    }
    return null;
  }, pin: true, fuzzOnly: true),
  ControlInvariant('capturing-red-in-rec', (c) {
    if (c.pedal.mode != LooperMode.record) return null;
    for (final t in c.looper.tracks) {
      if (t.isCapturing &&
          t.channel < c.frame.trackLeds.length &&
          c.frame.trackLeds[t.channel] != PedalTrackLed.red) {
        return 'capturing track ${t.channel} LED is '
            '${c.frame.trackLeds[t.channel]}, not red';
      }
    }
    return null;
  }, pin: true),
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
  ControlInvariant('frame-mirrors-mode', (c) {
    final want = c.pedal.mode == LooperMode.play
        ? PedalMode.play
        : PedalMode.rec;
    if (c.frame.mode != want) {
      return 'frame mode ${c.frame.mode} != pedal mode ${c.pedal.mode}';
    }
    return null;
  }, pin: true),
];

/// Evaluates the invariants against [c]; returns the violations
/// (`"name: message"`), empty when all hold. [projectionContext] skips the
/// fuzz-only rules (see [ControlInvariant.fuzzOnly]).
List<String> checkControlInvariants(
  ControlContext c, {
  bool projectionContext = false,
}) => [
  for (final invariant in controlInvariants)
    if (!(projectionContext && invariant.fuzzOnly))
      if (invariant.check(c) case final String message)
        '${invariant.name}: $message',
];

/// Assert-mode hook for projection time: throws (listing every violation)
/// when the spec is broken, returns true otherwise. Usable inside
/// `assert(...)` for zero release-mode cost.
bool debugControlInvariantsHold(ControlContext c) {
  final violations = checkControlInvariants(c, projectionContext: true);
  if (violations.isNotEmpty) {
    throw StateError(
      'control invariants violated:\n  ${violations.join('\n  ')}',
    );
  }
  return true;
}
