import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control_projection.dart';
import 'package:loopy/control/cubit/control_overlay_cubit.dart';
import 'package:loopy/looper/model/looper_mode.dart';
import 'package:settings_repository/settings_repository.dart';

/// The ONE intent interpreter for the control surfaces: the pedal's decoded
/// footswitches and the keyboard/on-screen actions call the SAME methods, so
/// the surfaces can never diverge in the command sequences they issue.
///
/// Holds the [LooperRepository] for commands OUT; the overlay cubit gets
/// engine truth through its own subscription (state IN), keeping it a pure
/// inventory + reducer. Derived reads (the armed set, parked) come from the
/// pure projections, never from stored state.
class ControlIntents {
  /// Creates a [ControlIntents] over the shared repositories and overlay.
  ControlIntents({
    required LooperRepository looper,
    required ControlOverlayCubit overlay,
    required SettingsRepository settings,
  }) : _looper = looper,
       _overlay = overlay,
       _settings = settings;

  final LooperRepository _looper;
  final ControlOverlayCubit _overlay;
  final SettingsRepository _settings;

  // Encoder accumulator: the engine exposes no master-gain read-back, so the
  // control layer tracks the value it last sent (unity until the first turn).
  static const double _encoderStep = 1 / 64;
  double _masterGain = 1;

  Future<void>? _loadFuture;

  ControlOverlayState get _o => _overlay.state;
  LooperState get _l => _looper.state;

  List<Track> get _tracks => _l.tracks;

  Track? _trackAt(int channel) =>
      channel >= 0 && channel < _tracks.length ? _tracks[channel] : null;

  /// A track that exists and holds (or is finishing) a loop.
  bool _playable(Track? track) =>
      track != null && (track.hasContent || track.isCapturing);

  /// Content tracks whose playhead is RUNNING (playing or overdubbing),
  /// mute-ignored — what a park must freeze, and what it resumes.
  Set<int> _running() => {
    for (final t in _tracks)
      if (t.hasContent &&
          (t.state == TrackState.playing || t.state == TrackState.overdubbing))
        t.channel,
  };

  /// Restores the persisted boot-default mode and applies it (a `play`
  /// default runs the same entry side effects as a live toggle).
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final defaultMode = LooperMode.fromToken(
      await _settings.loadDefaultLooperMode(),
    );
    _overlay.setDefaultMode(defaultMode);
    setMode(defaultMode);
  }

  // ---------------------------------------------------------------------------
  // Mode
  // ---------------------------------------------------------------------------

  /// Toggles Record / Play mode (identical from every surface).
  void toggleMode() => setMode(
    _o.mode == LooperMode.record ? LooperMode.play : LooperMode.record,
  );

  /// Applies [next] with its entry side effects; a no-op when already there.
  ///
  /// Entering Play finalizes any capture and previews the whole content set:
  /// `parkedResume` = every track holding (or finishing) a loop, so Rec/Play
  /// resumes them all and the parked LEDs show it — including stopped and
  /// muted tracks, which pure `sounding` could never cover. Any mode entry
  /// clears the stored play intent (the invalidation table).
  void setMode(LooperMode next) {
    if (next == _o.mode) return;
    switch (next) {
      case LooperMode.record:
        _overlay.applyMode(LooperMode.record, parkedResume: const {});
      case LooperMode.play:
        for (final track in _tracks) {
          if (track.isCapturing) _looper.record(channel: track.channel);
        }
        _overlay.applyMode(
          LooperMode.play,
          parkedResume: {
            for (final track in _tracks)
              if (_playable(track)) track.channel,
          },
        );
    }
  }

  /// Sets and persists the default [mode] the system boots into, applying it
  /// to the live mode now.
  Future<void> setDefaultMode(LooperMode mode) async {
    _overlay.setDefaultMode(mode);
    setMode(mode);
    await _settings.saveDefaultLooperMode(mode.token);
  }

  // ---------------------------------------------------------------------------
  // Cursor / bank
  // ---------------------------------------------------------------------------

  /// Moves the shared cursor to [channel] (reveals its bank).
  void selectTrack(int channel) => _overlay.selectTrack(channel);

  /// Reveals [bank] without moving the cursor (the browse flow).
  void browseBank(int bank) => _overlay.browseBank(bank);

  /// Toggles the visible bank, moving the cursor to the new bank's first
  /// track — the pedal BANK footswitch / keyboard `B` semantics.
  void toggleBankWithCursor() {
    final nextBank = _o.activeBank == 0 ? 1 : 0;
    _overlay.selectTrack(nextBank * ControlOverlayState.tracksPerBank);
  }

  // ---------------------------------------------------------------------------
  // Rec/Play
  // ---------------------------------------------------------------------------

  /// The Rec/Play action under the current mode.
  void recPlay() {
    switch (_o.mode) {
      case LooperMode.record:
        _recAdvance(_o.cursor);
      case LooperMode.play:
        _playRecPlay();
    }
  }

  /// Rec mode: advance the cursor track through record / overdub / play. A
  /// muted track is first unmuted and brought back: overdub if its loop still
  /// runs, plain resume if it was the parked sole track.
  void _recAdvance(int channel) {
    final track = _trackAt(channel);
    if (track != null && track.muted) {
      _looper.setMute(muted: false, channel: channel);
      if (track.state == TrackState.stopped) {
        _looper.play(channel: channel); // parked -> resume, no overdub
      } else {
        _looper.record(channel: channel); // running -> unmute + overdub
      }
      return;
    }
    // The engine's cycling record() walks empty -> record, capturing -> play
    // (finalize), playing -> overdub.
    _looper.record(channel: channel);
  }

  /// Play mode Rec/Play: resume while parked; while running, expand to the
  /// whole content set (a no-op when everything audible is already in).
  void _playRecPlay() {
    if (isParked(_l)) {
      final resume = _o.parkedResume.isNotEmpty
          ? _o.parkedResume
          : {
              for (final track in _tracks)
                if (_playable(track)) track.channel,
            };
      if (resume.isEmpty) return; // nothing recorded yet
      for (final channel in resume) {
        _looper
          ..setMute(muted: false, channel: channel)
          ..play(channel: channel);
      }
      // Consumed: the resumed tracks are now sounding, so the derived armed
      // set carries them from here.
      _overlay.latchParkedResume(const {});
      return;
    }
    // Running: expand to every content track unless the full audible set is
    // already in the mix (then the press is a no-op).
    final armed = armedTracks(_l, _o);
    final all = {
      for (final track in _tracks)
        if (track.hasContent) track.channel,
    };
    final anyAudible = _tracks.any(
      (t) => armed.contains(t.channel) && !t.muted && isSounding(t),
    );
    if (anyAudible && armed.containsAll(all)) return;
    for (final channel in all) {
      _looper
        ..setMute(muted: false, channel: channel)
        ..play(channel: channel);
    }
  }

  // ---------------------------------------------------------------------------
  // Stop
  // ---------------------------------------------------------------------------

  /// The Stop action under the current mode.
  void stop() {
    switch (_o.mode) {
      case LooperMode.record:
        _recStop(_o.cursor);
      case LooperMode.play:
        parkAll();
    }
  }

  /// Rec mode: mute the cursor track (finalizing a capture first). Muting the
  /// only audible loop parks the whole transport.
  void _recStop(int channel) {
    final track = _trackAt(channel);
    if (track == null) return;
    if (track.isCapturing) _looper.record(channel: channel); // finalize first
    _looper.setMute(muted: true, channel: channel);
    if (track.state == TrackState.playing && _isLastAudibleTrack(channel)) {
      for (final t in _tracks) {
        _looper.stopTrack(channel: t.channel);
      }
    }
  }

  /// Parks the play transport: freezes EVERY running content track (muted
  /// ones too — mute silences, park freezes) and latches what Rec/Play brings
  /// back at INTENT time, before engine truth catches up with the stops.
  void parkAll() {
    final running = _running();
    if (running.isEmpty) return; // already parked: keep the resume set
    _overlay.latchParkedResume(
      {...running}..removeWhere(_o.excluded.contains),
    );
    for (final channel in running) {
      _looper.stopTrack(channel: channel);
    }
  }

  // ---------------------------------------------------------------------------
  // Track buttons (pedal semantics)
  // ---------------------------------------------------------------------------

  /// A track-button press on [channel] under the current mode — the pedal's
  /// footswitch semantics.
  void trackPressed(int channel) {
    switch (_o.mode) {
      case LooperMode.record:
        _recTrackPressed(channel);
      case LooperMode.play:
        _playTrackPressed(channel);
    }
  }

  /// Rec mode: select the track, or hand off a live recording to it.
  void _recTrackPressed(int channel) {
    final capturing = _capturingChannel();
    if (capturing == null) {
      _overlay.selectTrack(channel);
    } else if (capturing == channel) {
      _looper.record(channel: channel); // finish the loop
    } else {
      _looper
        ..record(channel: capturing) // finalize the running capture
        ..record(channel: channel); // start the pressed one
      _overlay.selectTrack(channel);
    }
  }

  /// Play mode: while parked, toggle resume membership (arming a muted track
  /// unmutes it so it reads green). While running, a live track toggles its
  /// mute — muting the last audible one parks everything with an empty
  /// resume set (Rec/Play then brings back ALL content) — and a track out of
  /// the mix joins it (un-exclude, unmute, play).
  void _playTrackPressed(int channel) {
    final track = _trackAt(channel);
    if (!_playable(track)) return;
    final t = track!;
    if (isParked(_l)) {
      if (!_o.parkedResume.contains(channel) && t.muted) {
        _looper.setMute(muted: false, channel: channel);
      }
      _overlay.toggleParkedResume(channel);
      return;
    }
    final live =
        armedTracks(_l, _o).contains(channel) && t.state == TrackState.playing;
    if (live) {
      final muting = !t.muted;
      _looper.setMute(muted: muting, channel: channel);
      if (muting && _isLastAudibleArmed(channel)) {
        // Muting the last audible track parks the loop with nothing latched:
        // the next Rec/Play resumes the whole content set.
        for (final c in _running()) {
          _looper.stopTrack(channel: c);
        }
        _overlay.latchParkedResume(const {});
      }
    } else {
      _overlay.include(channel); // joining is the explicit un-exclude
      _looper
        ..setMute(muted: false, channel: channel)
        ..play(channel: channel);
    }
  }

  // ---------------------------------------------------------------------------
  // Clear-all / undo / redo / encoder
  // ---------------------------------------------------------------------------

  /// The whole-rig reset, unified across surfaces: every track holding
  /// content OR a redo history is cleared and re-armed (unmuted, persisted),
  /// and the overlay returns home (record mode, cursor 0). Undone-to-empty
  /// tracks must be included — only clear wipes their resurrect path, and the
  /// master grid resets once everything is empty.
  void clearAll() {
    for (final track in _tracks) {
      if (!track.hasContent && !track.canRedo) continue;
      _looper
        ..clear(channel: track.channel)
        ..setMute(muted: false, channel: track.channel);
      final lanes = track.lanes.isEmpty ? 1 : track.lanes.length;
      for (var lane = 0; lane < lanes; lane++) {
        unawaited(
          _settings.saveLaneMute(track.channel, lane, muted: false),
        );
      }
    }
    _overlay.resetForClearAll();
  }

  /// Undoes the latest overdub pass on [channel] (per-layer all the way
  /// down; past the base recording the track empties, redo-ably).
  void undo(int channel) => _looper.undo(channel: channel);

  /// Redoes the last undone layer on [channel] (including resurrecting an
  /// undone-to-empty track).
  void redo(int channel) => _looper.redo(channel: channel);

  /// An encoder detent turn: accumulates into the master output gain.
  void encoderTurned(int delta) {
    _masterGain = (_masterGain + delta * _encoderStep).clamp(0.0, 1.0);
    _looper.setMasterGain(_masterGain);
  }

  // ---------------------------------------------------------------------------
  // Snapshot helpers
  // ---------------------------------------------------------------------------

  int? _capturingChannel() {
    for (final track in _tracks) {
      if (track.isCapturing) return track.channel;
    }
    return null;
  }

  /// Whether muting [channel] would leave no audible armed track.
  bool _isLastAudibleArmed(int channel) {
    final armed = armedTracks(_l, _o);
    return !armed.any((c) {
      if (c == channel) return false;
      final track = _trackAt(c);
      return track != null && !track.muted && track.state == TrackState.playing;
    });
  }

  /// Whether muting [channel] would silence every track (the Rec-mode
  /// sole-track case).
  bool _isLastAudibleTrack(int channel) => !_tracks.any(
    (t) =>
        t.channel != channel &&
        !t.muted &&
        t.hasContent &&
        t.state == TrackState.playing,
  );
}
