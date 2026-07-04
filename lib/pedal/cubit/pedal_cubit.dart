import 'dart:async';
import 'dart:developer' as dev;

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/looper/model/looper_mode.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:settings_repository/settings_repository.dart';

part 'pedal_state.dart';

/// Drives the bidirectional foot pedal: turns inbound [PedalEvent]s into
/// `LooperRepository` commands and projects the looper snapshot back into a
/// [PedalStateFrame] pushed to the pedal's LEDs.
///
/// loopy is the single source of truth — the cubit holds only the control
/// overlay in [PedalState] (mode / Rec cursor / Play-armed set / bank), reads
/// all transport & track truth from the looper, and never trusts pedal-side
/// state.
///
/// The [LooperMode] here is the *system* mode, not a pedal-local one: the
/// pedal's MODE footswitch, the keyboard's `M`, and the on-screen mode chip
/// all toggle this one state (the on-screen surfaces call [toggleMode] /
/// [setDefaultMode]), so a track press means the same thing on every surface.
///
/// ## Behavior table
///
/// **Rec mode** — [PedalState.selectedTrack] is a single cursor:
///
/// | button   | action                                                       |
/// |----------|--------------------------------------------------------------|
/// | track    | select it (or, mid-capture, finalize the old + start it)     |
/// | Rec/Play | advance the selected track: the engine's cycling `record()`  |
/// |          | walks empty→record→(play↔overdub). A *muted* selected track  |
/// |          | is first unmuted: overdub if the loop still runs, else just  |
/// |          | resume playback (the parked sole-track case).                |
/// | Stop     | mute the selected track (finalizing a capture first)         |
///
/// **Play mode** — [PedalState.playArmed] is a set, and the transport is either
/// *playing* or *stopped* (parked = every armed track halted):
///
/// | button   | while STOPPED (parked)      | while PLAYING                   |
/// |----------|-----------------------------|---------------------------------|
/// | track    | arm (unmuting it) / disarm  | mute/unmute it; muting the last |
/// |          | its membership              | audible track parks everything  |
/// | Rec/Play | play the armed set — or all | park (stop) everything          |
/// |          | content tracks when none    |                                 |
/// |          | are armed                   |                                 |
/// | Stop     | (already parked)            | park everything                 |
///
/// mute ≠ stop: muting silences a track while its playhead keeps running in
/// sync; stopping (parking) freezes the playhead. The encoder drives master
/// gain.
class PedalCubit extends Cubit<PedalState> {
  /// Creates a [PedalCubit].
  ///
  /// The pedal's cursor (`selectedTrack` + `activeBank`) lives in [PedalState];
  /// the presentation layer bridges it to the app's `TracksCubit` with a
  /// `BlocListener` (see `PedalCursorBridge`), rather than this cubit reaching
  /// into another — bloc-to-bloc communication done at the presentation layer.
  PedalCubit({
    required PedalRepository pedal,
    required LooperRepository looper,
    required SettingsRepository settings,
    Duration pollInterval = const Duration(seconds: 2),
  }) : _pedal = pedal,
       _looper = looper,
       _settings = settings,
       super(const PedalState()) {
    _eventsSub = _pedal.events.listen(_handleEvent);
    _statusSub = _pedal.statusChanges.listen(_onBindStatus);
    _looperSub = _looper.looperState.listen(_onLooperState);
    // Seed the output set so the settings picker has it before the first poll.
    _syncOutputs();
    // Hotplug auto-reconnect for the bound output (mirrors MidiSetupCubit).
    // Pass Duration.zero to disable the timer (tests drive [reconnect]).
    if (pollInterval > Duration.zero) {
      _pollTimer = Timer.periodic(pollInterval, (_) => reconnect());
    }
  }

  final PedalRepository _pedal;
  final LooperRepository _looper;
  final SettingsRepository _settings;

  late final StreamSubscription<PedalEvent> _eventsSub;
  late final StreamSubscription<PedalBindStatus> _statusSub;
  late final StreamSubscription<LooperState> _looperSub;

  // Loaded settings (defaults until [load] resolves them).
  Duration _longPress = const Duration(milliseconds: 500);

  // Encoder accumulator. The engine exposes no master-gain read-back, so the
  // pedal tracks the value it last sent (unity until the first turn).
  static const double _encoderStep = 1 / 64;
  double _masterGain = 1;

  // Undo press/release timing (tap = undo, long-press = redo). The target
  // channel is LATCHED at press time: an on-screen click mid-hold must not
  // retarget the action the foot already committed to.
  Timer? _undoTimer;
  bool _undoArmed = false;
  bool _undoHandled = false;
  int _undoChannel = 0;

  // Whether the Clear footswitch is currently held down. Lights the Clear LED
  // (the `clearFadeActive` frame bit) for as long as the button is pressed.
  bool _clearHeld = false;

  // Latest looper snapshot + diff state for projection.
  LooperState? _looperState;
  PedalStateFrame? _lastFrame;
  int? _lastPosition;

  // Hotplug reconnect for the bound output: the pinned device id and the poll
  // timer that re-binds it when it (re)appears. The enumerated set + bound id
  // live in PedalState (see _syncOutputs); Equatable dedups no-op refreshes.
  Timer? _pollTimer;
  String? _savedOutputId;

  Future<void>? _loadFuture;

  /// Loads persisted pedal settings and auto-binds the saved output device.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    _longPress = Duration(milliseconds: await _settings.loadPedalLongPressMs());
    // Boot the live mode into the persisted default. Applied via _setMode so
    // a `play` default runs the same entry side effects as a mode toggle.
    final defaultMode = LooperMode.fromToken(
      await _settings.loadDefaultLooperMode(),
    );
    if (isClosed) return;
    emit(state.copyWith(defaultMode: defaultMode));
    _setMode(defaultMode);
    final saved = await _settings.loadPedalOutputDevice();
    if (saved == null) return;
    // Pin the saved output so the poll can reconnect it; bind now if present,
    // otherwise the poll binds it as soon as it appears.
    _savedOutputId = saved.id;
    if (_pedal.availableOutputs().any((d) => d.id == saved.id)) {
      _pedal.bind(saved.id);
    }
    _syncOutputs();
  }

  /// Folds the host's enumerated MIDI outputs and the bound destination into
  /// [PedalState], so the settings picker reads them from state rather than via
  /// read-through accessors. Equatable dedups when nothing changed.
  void _syncOutputs() {
    if (isClosed) return;
    emit(
      state.copyWith(
        availableOutputs: _pedal.availableOutputs(),
        boundOutputId: _pedal.boundOutputId,
      ),
    );
  }

  /// Binds the pedal output to [device] and persists the choice.
  Future<void> selectOutput(PedalOutput device) async {
    _savedOutputId = device.id;
    _pedal.bind(device.id);
    _syncOutputs();
    await _settings.savePedalOutputDevice(id: device.id, name: device.name);
  }

  /// Unbinds the pedal output and clears the saved device.
  Future<void> selectNone() async {
    _savedOutputId = null;
    _pedal.unbind();
    _syncOutputs();
    await _settings.clearPedalOutputDevice();
    _emitPedal(state.copyWith(boundOutputId: null));
  }

  /// Hotplug poll: re-enumerates the host's MIDI outputs and reconciles the
  /// pinned pedal output — (re)binds it when it appears (launch, replug, or a
  /// retry after a failed open) and drops the stale handle when it vanishes, so
  /// the LED-feedback link survives unplugs without relaunching loopy. Mirrors
  /// `MidiSetupCubit.refresh`; runs on the poll timer and is callable directly.
  void reconnect() {
    if (isClosed) return;
    final outputs = _pedal.availableOutputs();
    final saved = _savedOutputId;
    if (saved != null) {
      final present = outputs.any((d) => d.id == saved);
      if (present && _pedal.boundOutputId != saved) {
        _pedal.bind(saved); // (re)connect on appear / replug / retry
      } else if (!present && _pedal.boundOutputId == saved) {
        _pedal.unbind(); // pinned device vanished: drop the stale port handle
      }
    }
    // Reflect the (possibly changed) output set + bound id into state; the
    // settings picker re-renders only when one of them actually changed.
    _syncOutputs();
  }

  // ---------------------------------------------------------------------------
  // Public API mirrored by the on-screen UI
  // ---------------------------------------------------------------------------

  /// The pedal-track LED color for [channel], using the same rules as outbound
  /// projection ([_ledFor]). A read-only projection (used by tests and the
  /// hardware LED feedback), not a state mutation, so the non-void return is
  /// intentional.
  // ignore: prefer_void_public_cubit_methods
  PedalTrackLed trackLedFor(int channel) {
    final looperState = _looperState;
    if (looperState == null) return PedalTrackLed.off;
    return _ledFor(
      _trackAtIn(looperState, channel),
      state,
      selected: channel == state.selectedTrack,
    );
  }

  /// Selects [channel] as the Rec-mode cursor and mirrors it to loopy's UI.
  void selectTrack(int channel) => _selectTrack(channel);

  /// Toggles Record / Play mode (same rules as the pedal's Mode footswitch).
  void toggleMode() => _toggleMode();

  /// Sets and persists the default [mode] the system boots into, and applies
  /// it to the live mode now (entering Play auto-arms, as the footswitch
  /// does).
  Future<void> setDefaultMode(LooperMode mode) async {
    if (isClosed) return;
    emit(state.copyWith(defaultMode: mode));
    _setMode(mode);
    await _settings.saveDefaultLooperMode(mode.token);
  }

  /// Toggles [channel]'s Play-mode armed-set membership (no transport change) —
  /// for on-screen arm toggles while the looper handles playback.
  void togglePlayArm(int channel) {
    if (state.mode != LooperMode.play) return;
    if (!_playable(_trackAt(channel))) return;
    _setPlayArmed(_withToggled(state.playArmed, channel));
  }

  /// Mirrors the on-screen bank switch into pedal overlay state.
  void selectBank(int bank) {
    if (bank != 0 && bank != 1) return;
    if (bank == state.activeBank) return;
    final base = bank * PedalState.tracksPerBank;
    _emitPedal(state.copyWith(activeBank: bank, selectedTrack: base));
  }

  // ---------------------------------------------------------------------------
  // Inbound events
  // ---------------------------------------------------------------------------

  void _handleEvent(PedalEvent event) {
    switch (event) {
      case ButtonPressed(:final button):
        _onPress(button);
      case ButtonReleased(:final button):
        if (button == PedalButton.undo) _onUndoRelease();
        if (button == PedalButton.clear) _onClearRelease();
      case EncoderDelta(:final delta):
        _onEncoder(delta);
    }
  }

  void _onPress(PedalButton button) {
    _log('press ${button.name}  [${_overlay(state)}]');
    switch (button) {
      case PedalButton.undo:
        _armUndo();
      case PedalButton.recPlay:
        _onRecPlay();
      case PedalButton.stop:
        _onStop();
      case PedalButton.mode:
        _toggleMode();
      case PedalButton.bank:
        _toggleBank();
      case PedalButton.clear:
        _onClear();
      case PedalButton.track1:
      case PedalButton.track2:
      case PedalButton.track3:
      case PedalButton.track4:
        _onTrack(_trackIndex(button));
    }
  }

  // --- Rec/Play -------------------------------------------------------------

  void _onRecPlay() {
    switch (state.mode) {
      case LooperMode.record:
        _recAdvanceSelected();
      case LooperMode.play:
        _playToggleTransport();
    }
  }

  /// Rec mode: advance the selected track through record / overdub / play.
  void _recAdvanceSelected() {
    final channel = state.selectedTrack;
    final track = _trackAt(channel);
    if (track != null && track.muted) {
      // Stop had muted it. Unmute and bring it back: overdub if its loop is
      // still running, or just resume playback if it was the parked sole track.
      _looper.setMute(muted: false, channel: channel);
      if (track.state == TrackState.stopped) {
        _looper.play(channel: channel); // parked -> resume, no overdub
      } else {
        _looper.record(channel: channel); // running -> unmute + overdub
      }
      return;
    }
    // The engine's cycling record() walks empty→record, capturing→play
    // (finalize), playing→overdub — the whole record/overdub↔play cycle.
    _looper.record(channel: channel);
  }

  /// Play mode: Rec/Play toggles the whole armed set between playing and parked.
  void _playToggleTransport() {
    final isPlaying = _playIsPlaying();
    // An armed set can be running yet fully silent (every track muted from the
    // keyboard/screen, which never parks). A dead early-return there would
    // leave Rec/Play unresponsive in silence — fall through to _resumePlay,
    // which unmutes and plays the set.
    final anyAudible = _tracks.any(
      (t) =>
          state.playArmed.contains(t.channel) &&
          !t.muted &&
          (t.state == TrackState.playing ||
              t.state == TrackState.overdubbing),
    );
    final isPlayingAllWithContent =
        isPlaying &&
        anyAudible &&
        state.playArmed.length == _tracks.where((t) => t.hasContent).length;

    if (isPlayingAllWithContent) return;
    _resumePlay(allWithContent: !isPlayingAllWithContent && isPlaying);
  }

  // --- Track buttons --------------------------------------------------------

  void _onTrack(int index) {
    final channel = state.bankBaseChannel + index;
    switch (state.mode) {
      case LooperMode.record:
        _recTrackButton(channel);
      case LooperMode.play:
        _playTrackButton(channel);
    }
  }

  /// Rec mode: select the track, or hand off a live recording to it.
  void _recTrackButton(int channel) {
    final capturing = _capturingChannel();
    if (capturing == null) {
      // Nothing recording: pressing a track just (re)selects it.
      _selectTrack(channel);
    } else if (capturing == channel) {
      // Same track: finish the loop (the engine cycles record).
      _looper.record(channel: channel);
    } else {
      // Hand-off: finalize the recording track, then start the pressed one.
      _looper
        ..record(channel: capturing)
        ..record(channel: channel);
      _selectTrack(channel);
    }
  }

  /// Play mode track button. While the transport runs, a track already live in
  /// the mix (armed with its playhead advancing) toggles its mute; a track out
  /// of the mix (disarmed, or armed but parked) joins it — arm, unmute, play.
  /// While fully parked, a press instead toggles armed-set membership, built up
  /// for the next Rec/Play. Empty tracks have nothing to act on.
  void _playTrackButton(int channel) {
    final track = _trackAt(channel);
    if (!_playable(track)) return;
    final t = track!;
    if (!_playIsPlaying()) {
      // Parked: toggle armed-set membership. Arming a muted track (a park can
      // leave it muted) unmutes it so it reads green and is ready for Rec/Play.
      final next = _withToggled(state.playArmed, channel);
      if (next.contains(channel) && t.muted) {
        _looper.setMute(muted: false, channel: channel);
      }
      _setPlayArmed(next);
      return;
    }
    // Transport running: a live track (armed and playing) toggles mute; one out
    // of the mix (disarmed, or armed but parked) joins it — arm, unmute, play.
    final live =
        state.playArmed.contains(channel) && t.state == TrackState.playing;
    if (live) {
      _playMuteToggle(channel, t);
    } else {
      _setPlayArmed({...state.playArmed, channel});
      _looper
        ..setMute(muted: false, channel: channel)
        ..play(channel: channel);
    }
  }

  /// Mutes or unmutes [channel]. Muting the last audible armed track parks the
  /// whole transport (a track is never individually stopped while others play).
  void _playMuteToggle(int channel, Track track) {
    final muting = !track.muted;
    _looper.setMute(muted: muting, channel: channel);
    if (muting && _isLastAudibleArmed(channel)) {
      // Muting the last audible track stops the loop and disarms everything.
      _parkPlay();
      _emitPedal(state.copyWith(playArmed: const {}));
    }
  }

  // --- Stop -----------------------------------------------------------------

  void _onStop() {
    switch (state.mode) {
      case LooperMode.record:
        _recStopSelected();
      case LooperMode.play:
        _parkPlay();
    }
  }

  /// Rec mode: mute the selected track (finalizing a capture first). Muting the
  /// only audible track parks the loop — Rec/Play then resumes it (no overdub).
  void _recStopSelected() {
    final channel = state.selectedTrack;
    final track = _trackAt(channel);
    if (track == null) return;
    if (track.isCapturing) _looper.record(channel: channel); // finalize first
    _looper.setMute(muted: true, channel: channel);
    // Sole-track case: muting the only audible loop parks the whole transport.
    if (track.state == TrackState.playing && _isLastAudibleTrack(channel)) {
      _parkAllTracks();
    }
  }

  // --- Play-transport helpers ----------------------------------------------

  /// True when the Play transport is running (any armed track's playhead is
  /// advancing — a muted-but-playing track still counts as running, and an
  /// overdubbing track is running by definition).
  bool _playIsPlaying() => state.playArmed.any((c) {
    final st = _trackAt(c)?.state;
    return st == TrackState.playing || st == TrackState.overdubbing;
  });

  /// Parks the armed set: freezes every armed track's playhead.
  void _parkPlay() {
    for (final channel in state.playArmed) {
      _looper.stopTrack(channel: channel);
    }
  }

  /// Resumes the armed set: unmutes and plays every armed track. With nothing
  /// armed (e.g. just after parking) it first arms every content track, so
  /// Rec/Play plays the whole loop set by default without arming each one.
  void _resumePlay({
    bool allWithContent = false,
  }) {
    var armed = state.playArmed;
    if (armed.isEmpty || allWithContent) {
      armed = {
        for (final track in _tracks)
          if (_playable(track)) track.channel,
      };
      if (armed.isEmpty) return; // nothing recorded yet
      _setPlayArmed(armed);
    }
    for (final channel in armed) {
      _looper
        ..setMute(muted: false, channel: channel)
        ..play(channel: channel);
    }
  }

  /// Whether muting [channel] would leave no audible armed track (so the loop
  /// should park). Reads the current snapshot, in which [channel] is not yet
  /// muted, so it is excluded from the check.
  bool _isLastAudibleArmed(int channel) => !state.playArmed.any((c) {
    if (c == channel) return false;
    final track = _trackAt(c);
    return track != null && !track.muted && track.state == TrackState.playing;
  });

  /// Whether muting [channel] would silence every track (Rec-mode sole-track
  /// case, where muting the last content track parks the whole loop).
  bool _isLastAudibleTrack(int channel) => !_tracks.any(
    (t) =>
        t.channel != channel &&
        !t.muted &&
        t.hasContent &&
        t.state == TrackState.playing,
  );

  void _parkAllTracks() {
    for (final track in _tracks) {
      _looper.stopTrack(channel: track.channel);
    }
  }

  // --- Mode / bank / clear --------------------------------------------------

  void _toggleMode() => _setMode(
    state.mode == LooperMode.record ? LooperMode.play : LooperMode.record,
  );

  /// Applies [next] with its entry side effects; a no-op when already there.
  void _setMode(LooperMode next) {
    if (next == state.mode) return;
    switch (next) {
      case LooperMode.record:
        _emitPedal(state.copyWith(mode: LooperMode.record));
      case LooperMode.play:
        _enterPlayMode();
    }
  }

  /// Record → Play: finalize any capture, then auto-arm every track that holds
  /// (or is finishing) content, so the recorded loops are immediately playable
  /// and shown green without pressing each one.
  void _enterPlayMode() {
    for (final track in _tracks) {
      if (track.isCapturing) _looper.record(channel: track.channel);
    }
    final armed = {
      for (final track in _tracks)
        if (track.hasContent || track.isCapturing) track.channel,
    };
    _emitPedal(state.copyWith(mode: LooperMode.play, playArmed: armed));
  }

  void _toggleBank() {
    final nextBank = state.activeBank == 0 ? 1 : 0;
    final base = nextBank * PedalState.tracksPerBank;
    // Re-resolve the Rec cursor to the new bank (default its first track). The
    // presentation bridge mirrors the new cursor onto the app.
    _emitPedal(state.copyWith(activeBank: nextBank, selectedTrack: base));
  }

  void _onClear() {
    _log('clear  [${_overlay(state)}]');
    // Light the Clear LED while the footswitch is held (cleared on release).
    _clearHeld = true;
    void clearAndArm(int channel) {
      _looper
        ..clear(channel: channel)
        ..setMute(muted: false, channel: channel);
      // Persist the unmute per lane (the engine unmutes every lane on clear),
      // so a cleared track stays audible across a restart.
      final lanes = _trackAt(channel)?.lanes.length ?? 1;
      for (var lane = 0; lane < (lanes < 1 ? 1 : lanes); lane++) {
        unawaited(_settings.saveLaneMute(channel, lane, muted: false));
      }
    }

    // Undone-to-empty tracks (canRedo) must be cleared too: only clear wipes
    // their resurrect path, and the master grid resets when everything is
    // empty — a surviving redo would reinstate a loop into a dead grid.
    for (final track in _tracks) {
      if (track.hasContent || track.canRedo) clearAndArm(track.channel);
    }

    _selectTrack(0);
    _emitPedal(
      state.copyWith(
        activeBank: 0,
        selectedTrack: 0,
        playArmed: {},
        mode: LooperMode.record,
      ),
    );
  }

  /// Clear footswitch released: darken the Clear LED (the clear itself already
  /// happened on press — this only ends the held-button light).
  void _onClearRelease() {
    if (!_clearHeld) return;
    _clearHeld = false;
    _pushProjected();
  }

  // --- Undo / encoder -------------------------------------------------------

  void _armUndo() {
    _undoArmed = true;
    _undoHandled = false;
    _undoChannel = state.selectedTrack; // latch the target at press
    _undoTimer?.cancel();
    _undoTimer = Timer(_longPress, () {
      _undoHandled = true; // long-press = redo
      _log('redo ch=$_undoChannel  (long-press)');
      _looper.redo(channel: _undoChannel);
    });
  }

  void _onUndoRelease() {
    if (!_undoArmed) return;
    _undoArmed = false;
    _undoTimer?.cancel();
    _undoTimer = null;
    if (!_undoHandled) {
      _log('undo ch=$_undoChannel  (tap)');
      // Per-layer undo all the way down: each tap peels one overdub pass, and
      // undoing past the base recording empties the track while keeping redo
      // able to reinstate it layer by layer (long-press). Never a clear.
      _looper.undo(channel: _undoChannel);
    }
  }

  void _onEncoder(int delta) {
    _masterGain = (_masterGain + delta * _encoderStep).clamp(0.0, 1.0);
    _log('encoder $delta -> gain ${_masterGain.toStringAsFixed(2)}');
    _looper.setMasterGain(_masterGain);
  }

  // --- Overlay mutations ----------------------------------------------------

  /// Selects [channel] as the Rec cursor, following it into its bank (an
  /// on-screen selection can land in the other bank; the pedal's bank LED and
  /// track buttons must track the cursor). The presentation bridge mirrors it
  /// onto loopy's on-screen selection.
  void _selectTrack(int channel) => _emitPedal(
    state.copyWith(
      selectedTrack: channel,
      activeBank: channel ~/ PedalState.tracksPerBank,
    ),
  );

  void _setPlayArmed(Set<int> armed) =>
      _emitPedal(state.copyWith(playArmed: armed));

  static Set<int> _withToggled(Set<int> set, int value) {
    final next = {...set};
    if (!next.remove(value)) next.add(value);
    return next;
  }

  // ---------------------------------------------------------------------------
  // Debug logging (dev builds only) — a `pedal` channel tracing button presses,
  // pedal overlay changes, and track transitions, so behavior can be observed
  // against the hardware. Track logging is deduped to real state/mute changes
  // (not the constant peak updates), keeping the trace quiet.
  // ---------------------------------------------------------------------------

  String? _lastTrackSig;

  void _log(String message) {
    dev.log(message, name: 'pedal');
  }

  /// The pedal overlay in one line: mode, Rec cursor, Play-armed set, bank.
  String _overlay(PedalState s) =>
      'mode=${s.mode.name} sel=${s.selectedTrack} '
      'armed=${_fmtSet(s.playArmed)} bank=${s.activeBank}';

  static String _fmtSet(Set<int> set) {
    if (set.isEmpty) return '{}';
    final sorted = set.toList()..sort();
    return '{${sorted.join(',')}}';
  }

  /// Compact per-channel view of the loops that exist (empty tracks omitted):
  /// `0:playing 1:playing(m) 3:stopped` — `(m)` marks a muted track.
  static String _fmtTracks(LooperState s) {
    final parts = [
      for (final track in s.tracks)
        if (track.hasContent || track.state != TrackState.empty)
          '${track.channel}:${track.state.name}${track.muted ? '(m)' : ''}',
    ];
    return parts.isEmpty ? '(no loops)' : parts.join(' ');
  }

  /// Logs the engine's track states, but only when a state/mute/content change
  /// actually happened — peak-only updates are skipped to keep it quiet.
  void _logTracks(LooperState s) {
    final sig = [
      for (final t in s.tracks)
        '${t.channel}:${t.state.name}:${t.muted}:${t.hasContent}',
    ].join('|');
    if (sig == _lastTrackSig) return;
    _lastTrackSig = sig;
    _log('tracks ${_fmtTracks(s)}');
  }

  // ---------------------------------------------------------------------------
  // Outbound projection
  // ---------------------------------------------------------------------------

  /// Whether [track] is actually sounding in the mix: playing or overdubbing
  /// recorded content, unmuted. Mute matters here: park-by-mute deliberately
  /// empties the armed set while the stop commands are still in flight, and a
  /// muted track must not re-arm through that window — while an unmute of a
  /// still-playing track IS a fresh sounding edge and re-arms it.
  static bool _sounding(Track? track) =>
      track != null &&
      track.hasContent &&
      !track.muted &&
      (track.state == TrackState.playing ||
          track.state == TrackState.overdubbing);

  void _onLooperState(LooperState looperState) {
    final previous = _looperState;
    _looperState = looperState;
    _logTracks(looperState);
    // Reconcile the armed set against looper truth in BOTH directions (loopy
    // is the single source of truth):
    //  - drop any channel that no longer holds (or is finishing) a loop —
    //    cleared or undone-to-empty tracks can't linger green or be acted on;
    //  - arm any track that just STARTED sounding — a redo that reinstates an
    //    undone-to-empty track, or an on-screen play press, re-enters the mix
    //    and the pedal must show and control it again. Edge-triggered on the
    //    transition, so a deliberate on-screen disarm of a still-playing track
    //    is respected rather than fought every poll; parked (stopped) tracks
    //    keep their existing membership only.
    final reconciled = <int>{
      for (final channel in state.playArmed)
        if (_playable(_trackAtIn(looperState, channel))) channel,
      for (final track in looperState.tracks)
        if (_sounding(track) &&
            !_sounding(_trackAtIn(previous, track.channel)))
          track.channel,
    };
    if (reconciled.length != state.playArmed.length ||
        !reconciled.containsAll(state.playArmed)) {
      emit(state.copyWith(playArmed: reconciled));
    }
    _detectLoopTop(looperState);
    _pushProjected();
  }

  void _onBindStatus(PedalBindStatus status) {
    if (isClosed) return;
    emit(state.copyWith(bindStatus: status));
    // A fresh bind has no last frame on the pedal — force the next push.
    if (status == PedalBindStatus.bound) {
      _lastFrame = null;
      _pushProjected();
    }
  }

  void _detectLoopTop(LooperState s) {
    final position = s.transport.masterPositionFrames;
    final previous = _lastPosition;
    if (previous != null &&
        position < previous &&
        s.transport.masterLengthFrames > 0) {
      _pedal.sendLoopTop();
    }
    _lastPosition = position;
  }

  /// Emits [next] and re-projects, so a pedal-overlay change (mode / cursor /
  /// armed set / bank) is reflected on the LEDs immediately.
  void _emitPedal(PedalState next) {
    if (isClosed) return;
    emit(next);
    _log('pedal  ${_overlay(next)}');
    _pushProjected();
  }

  void _pushProjected() {
    final looperState = _looperState;
    if (looperState == null) return;
    final frame = _projectFrame(looperState, state);
    // The control-surface invariant spec (lib/control/invariants.dart) runs
    // on every projection in debug builds — the same predicates the sequence
    // fuzzer checks. assert() only: zero release-mode cost.
    assert(
      debugControlInvariantsHold(
        ControlContext(looper: looperState, pedal: state, frame: frame),
      ),
      'control-surface invariants must hold at projection time',
    );
    if (frame == _lastFrame) return; // diff: only push on change
    _lastFrame = frame;
    _pedal.pushState(frame);
  }

  PedalStateFrame _projectFrame(LooperState s, PedalState pedal) {
    final leds = <PedalTrackLed>[
      for (var channel = 0; channel < PedalStateFrame.trackCount; channel++)
        _ledFor(
          _trackAtIn(s, channel),
          pedal,
          selected: channel == pedal.selectedTrack,
        ),
    ];
    // global_color carries the ring's activity color: red while recording,
    // amber while overdubbing, green while a loop plays, off when idle. (The
    // pedal's Rec/Play mode is shown separately by the mode LED, from mode.)
    final anyRecording = s.tracks.any((t) => t.state == TrackState.recording);
    final anyOverdub = s.tracks.any((t) => t.state == TrackState.overdubbing);
    final anyPlaying = s.tracks.any(
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
    final sampleRate = s.status.sampleRate;
    // The engine keeps the master grid alive after undo-to-empty (redo needs
    // it), but a pedal with no loops anywhere must not keep its ring lit and
    // sweeping — render the length only while something holds or captures one.
    final anyLoop = s.tracks.any((t) => t.hasContent || t.isCapturing);
    final lengthMicros = sampleRate > 0 && anyLoop
        ? (s.transport.masterLengthFrames * 1000000 / sampleRate).round()
        : 0;
    return PedalStateFrame(
      globalColor: global,
      trackLeds: leds,
      activeBank: pedal.activeBank,
      selectedTrack: pedal.selectedTrack,
      // The wire frame carries the mode as the transport-level PedalMode.
      mode: pedal.mode == LooperMode.play ? PedalMode.play : PedalMode.rec,
      loopLengthMicros: lengthMicros.clamp(
        0,
        PedalStateFrame.maxLoopLengthMicros,
      ),
      // Lit while the Clear footswitch is held (the clear itself is instant).
      clearFadeActive: _clearHeld,
    );
  }

  PedalTrackLed _ledFor(
    Track? track,
    PedalState pedal, {
    required bool selected,
  }) {
    switch (pedal.mode) {
      case LooperMode.play:
        // Green = armed for play AND audible: a muted (or disarmed) track reads
        // off. While parked, an armed track is unmuted, so it stays green to
        // show what Rec/Play will resume.
        final channel = track?.channel;
        final armed = channel != null && pedal.playArmed.contains(channel);
        return armed && !(track?.muted ?? false)
            ? PedalTrackLed.green
            : PedalTrackLed.off;
      case LooperMode.record:
        // The selected (cursor) track and any capturing track are red.
        if (selected) return PedalTrackLed.red;
        if (track?.isCapturing ?? false) return PedalTrackLed.red;
        return PedalTrackLed.off;
    }
  }

  // ---------------------------------------------------------------------------
  // Snapshot helpers
  // ---------------------------------------------------------------------------

  List<Track> get _tracks => _looperState?.tracks ?? const [];

  /// A track that exists and holds (or is finishing) a loop — armable/mutable.
  bool _playable(Track? track) =>
      track != null && (track.hasContent || track.isCapturing);

  Track? _trackAt(int channel) => _trackAtIn(_looperState, channel);

  Track? _trackAtIn(LooperState? s, int channel) {
    final tracks = s?.tracks ?? const <Track>[];
    return channel >= 0 && channel < tracks.length ? tracks[channel] : null;
  }

  int? _capturingChannel() {
    for (final track in _tracks) {
      if (track.isCapturing) return track.channel;
    }
    return null;
  }

  int _trackIndex(PedalButton button) => switch (button) {
    PedalButton.track1 => 0,
    PedalButton.track2 => 1,
    PedalButton.track3 => 2,
    PedalButton.track4 => 3,
    _ => throw ArgumentError('not a track button: $button'),
  };

  @override
  Future<void> close() async {
    _undoTimer?.cancel();
    _pollTimer?.cancel();
    await _eventsSub.cancel();
    await _statusSub.cancel();
    await _looperSub.cancel();
    // Darken the pedal on shutdown (no-op when not bound), then release the
    // transport — the cubit is the pedal repository's sole owner.
    _pedal.pushState(PedalStateFrame.blank(goodbye: true));
    await _pedal.dispose();
    return super.close();
  }
}
