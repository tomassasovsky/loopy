/// The pure projections from `(LooperState × ControlState)` to
/// everything the control surfaces render: the armed set, per-track LEDs, and
/// the pedal wire frame. NOTHING here is stored — a projection cannot go
/// stale, which retires the reconciliation bug class ("redo didn't relight
/// the LED") structurally.
///
/// Debug builds assert the control-surface invariant spec on every projected
/// frame ([projectFrame]); the sequence fuzzer checks the same spec against
/// the real engine.
library;

import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/cubit/control_cubit.dart';
import 'package:loopy/control/invariants.dart';
import 'package:loopy/looper/model/interaction_mode.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// Whether the play transport is PARKED: content exists but none of it is
/// running. State-based and mute-ignored — keyboard-muting every track does
/// NOT park (mute silences; only Stop freezes playheads).
bool isParked(LooperState looper) {
  var anyContent = false;
  for (final t in looper.tracks) {
    if (!t.hasContent) continue;
    anyContent = true;
    if (t.state == TrackState.playing || t.state == TrackState.overdubbing) {
      return false;
    }
  }
  return anyContent;
}

/// Whether [track] is actually sounding in the mix: unmuted recorded content
/// with a running playhead.
bool isSounding(Track track) =>
    track.hasContent &&
    !track.muted &&
    (track.state == TrackState.playing ||
        track.state == TrackState.overdubbing);

/// The mute-mode armed set, DERIVED on every read:
/// `parked ? parkedResume : sounding ∖ excluded`. A redo, an on-screen play,
/// or any future engine state is reflected the moment the snapshot changes —
/// there is no stored set to forget to update.
Set<int> armedTracks(LooperState looper, ControlState overlay) {
  if (isParked(looper)) return overlay.parkedResume;
  return {
    for (final t in looper.tracks)
      if (isSounding(t) && !overlay.excluded.contains(t.channel)) t.channel,
  };
}

/// The pedal-track LED for [channel] under the current mode.
///
/// Mute mode: green = armed AND audible (a muted or excluded track reads
/// off; while parked, the parked-resume members show what Rec/Play brings
/// back). Record mode: the cursor and any capturing track read red.
PedalTrackLed projectTrackLed(
  LooperState looper,
  ControlState overlay,
  int channel,
) {
  final track = channel >= 0 && channel < looper.tracks.length
      ? looper.tracks[channel]
      : null;
  switch (overlay.mode) {
    case InteractionMode.mute:
      final armed = armedTracks(looper, overlay).contains(channel);
      return armed && !(track?.muted ?? false)
          ? PedalTrackLed.green
          : PedalTrackLed.off;
    case InteractionMode.record:
      if (channel == overlay.cursor) return PedalTrackLed.red;
      if (track?.isCapturing ?? false) return PedalTrackLed.red;
      return PedalTrackLed.off;
  }
}

/// Projects the full pedal wire frame — LEDs, ring activity color, bank,
/// cursor, mode, loop length — from engine truth and the overlay. Pure; the
/// pedal cubit diff-pushes the result, the simulator renders it.
PedalStateFrame projectFrame(
  LooperState looper,
  ControlState overlay, {
  bool clearFadeActive = false,
  bool performanceArmed = false,
  double masterGain = 1.0,
}) {
  final leds = <PedalTrackLed>[
    for (var channel = 0; channel < PedalStateFrame.trackCount; channel++)
      projectTrackLed(looper, overlay, channel),
  ];
  // global_color carries the ring's activity color: red while recording,
  // amber while overdubbing, green while a loop plays, off when idle. (The
  // pedal's Rec/Mute interaction mode is shown separately by the mode LED.)
  final anyRecording = looper.tracks.any(
    (t) => t.state == TrackState.recording,
  );
  final anyOverdub = looper.tracks.any(
    (t) => t.state == TrackState.overdubbing,
  );
  final anyPlaying = looper.tracks.any(
    (t) => t.state == TrackState.playing && !t.muted,
  );
  final global = anyRecording && anyPlaying
      ? GlobalColor.amber
      : anyRecording
      ? GlobalColor.red
      : anyOverdub
      ? GlobalColor.amber
      : anyPlaying
      ? GlobalColor.green
      : GlobalColor.off;
  final sampleRate = looper.status.sampleRate;
  // The engine keeps the master grid alive after undo-to-empty (redo needs
  // it), but a pedal with no loops anywhere must not keep its ring lit —
  // render the length only while something holds or captures one.
  final anyLoop = looper.tracks.any((t) => t.hasContent || t.isCapturing);
  final lengthMicros = sampleRate > 0 && anyLoop
      ? (looper.transport.masterLengthFrames * 1000000 / sampleRate).round()
      : 0;
  final frame = PedalStateFrame(
    globalColor: global,
    trackLeds: leds,
    activeBank: overlay.activeBank,
    selectedTrack: overlay.cursor,
    // The wire frame still calls mute mode PLAY: PedalMode is the pedal
    // firmware's protocol enum (its mode LED predates the rename), so the
    // mapping — not the wire token — carries the new name.
    mode: overlay.mode == InteractionMode.mute ? PedalMode.play : PedalMode.rec,
    loopLengthMicros: lengthMicros.clamp(
      0,
      PedalStateFrame.maxLoopLengthMicros,
    ),
    clearFadeActive: clearFadeActive,
    performanceArmed: performanceArmed,
    masterGain: masterGain,
  );
  // The control-surface invariant spec runs on every projection in debug
  // builds — the same predicates the sequence fuzzer checks. assert() only:
  // zero release-mode cost.
  assert(
    debugControlInvariantsHold(
      ControlContext(looper: looper, overlay: overlay, frame: frame),
    ),
    'control-surface invariants must hold at projection time',
  );
  return frame;
}
