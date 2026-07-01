import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:settings_repository/settings_repository.dart';

part 'pedal_state.dart';

/// Drives the bidirectional foot pedal: turns inbound [PedalEvent]s into
/// `LooperRepository` commands and projects the looper snapshot back into a
/// [PedalStateFrame] pushed to the pedal's LEDs.
///
/// loopy is the single source of truth — the cubit holds only the pedal-facing
/// overlay in [PedalState] (mode / Rec cursor / Play-armed set / bank), reads
/// all transport & track truth from the looper, and never trusts pedal-side
/// state.
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
/// | track    | arm/disarm its membership   | mute/unmute it; muting the last |
/// |          |                             | audible track parks everything  |
/// | Rec/Play | play the armed set (needs   | park (stop) everything          |
/// |          | ≥1 armed)                   |                                 |
/// | Stop     | (already parked)            | park everything                 |
///
/// mute ≠ stop: muting silences a track while its playhead keeps running in
/// sync; stopping (parking) freezes the playhead. The encoder drives master
/// gain.
class PedalCubit extends Cubit<PedalState> {
  /// Creates a [PedalCubit].
  ///
  /// [onBankSelected] is called whenever the pedal changes the active bank, so
  /// the wiring layer can keep the app's `BankCubit` in sync (the pedal is the
  /// source of truth for its own bank in v1). [onTrackSelected] is called with
  /// the absolute channel whenever the pedal moves its Rec cursor, so the
  /// wiring layer can move loopy's on-screen selected track to match.
  PedalCubit({
    required PedalRepository pedal,
    required LooperRepository looper,
    required SettingsRepository settings,
    void Function(int bank)? onBankSelected,
    void Function(int channel)? onTrackSelected,
    Duration pollInterval = const Duration(seconds: 2),
  }) : _pedal = pedal,
       _looper = looper,
       _settings = settings,
       _onBankSelected = onBankSelected,
       _onTrackSelected = onTrackSelected,
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
  final void Function(int bank)? _onBankSelected;
  final void Function(int channel)? _onTrackSelected;

  late final StreamSubscription<PedalEvent> _eventsSub;
  late final StreamSubscription<PedalBindStatus> _statusSub;
  late final StreamSubscription<LooperState> _looperSub;

  // Loaded settings (defaults until [load] resolves them).
  Duration _longPress = const Duration(milliseconds: 500);

  // Encoder accumulator. The engine exposes no master-gain read-back, so the
  // pedal tracks the value it last sent (unity until the first turn).
  static const double _encoderStep = 1 / 64;
  double _masterGain = 1;

  // Undo press/release timing (tap = undo, long-press = redo).
  Timer? _undoTimer;
  bool _undoArmed = false;
  bool _undoHandled = false;

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

  /// Toggles Rec / Play mode (same rules as the pedal's Mode footswitch).
  void toggleMode() => _toggleMode();

  /// Toggles [channel]'s Play-mode armed-set membership (no transport change) —
  /// for on-screen arm toggles while the looper handles playback.
  void togglePlayArm(int channel) {
    if (state.mode != PedalMode.play) return;
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
      case EncoderDelta(:final delta):
        _onEncoder(delta);
    }
  }

  void _onPress(PedalButton button) {
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
      case PedalMode.rec:
        _recAdvanceSelected();
      case PedalMode.play:
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
    if (_playIsPlaying()) {
      _parkPlay();
    } else {
      _resumePlay();
    }
  }

  // --- Track buttons --------------------------------------------------------

  void _onTrack(int index) {
    final channel = state.bankBaseChannel + index;
    switch (state.mode) {
      case PedalMode.rec:
        _recTrackButton(channel);
      case PedalMode.play:
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

  /// Play mode: while playing a track button mutes/unmutes; while parked it
  /// arms/disarms membership. Empty tracks have nothing to arm or mute.
  void _playTrackButton(int channel) {
    final track = _trackAt(channel);
    if (!_playable(track)) return;
    if (_playIsPlaying()) {
      _playMuteToggle(channel, track!);
    } else {
      _setPlayArmed(_withToggled(state.playArmed, channel));
    }
  }

  /// Mutes or unmutes [channel]. Muting the last audible armed track parks the
  /// whole transport (a track is never individually stopped while others play).
  void _playMuteToggle(int channel, Track track) {
    final muting = !track.muted;
    _looper.setMute(muted: muting, channel: channel);
    if (muting && _isLastAudibleArmed(channel)) {
      _parkPlay(); // everything muted -> freeze the loop
    }
  }

  // --- Stop -----------------------------------------------------------------

  void _onStop() {
    switch (state.mode) {
      case PedalMode.rec:
        _recStopSelected();
      case PedalMode.play:
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
  /// advancing — a muted-but-playing track still counts as running).
  bool _playIsPlaying() =>
      state.playArmed.any((c) => _trackAt(c)?.state == TrackState.playing);

  /// Parks the armed set: freezes every armed track's playhead.
  void _parkPlay() {
    for (final channel in state.playArmed) {
      _looper.stopTrack(channel: channel);
    }
  }

  /// Resumes the armed set: unmutes and plays every armed track. No-op when
  /// nothing is armed (the user must select tracks before playing).
  void _resumePlay() {
    if (state.playArmed.isEmpty) return;
    for (final channel in state.playArmed) {
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

  void _toggleMode() {
    switch (state.mode) {
      case PedalMode.play:
        _emitPedal(state.copyWith(mode: PedalMode.rec));
      case PedalMode.rec:
        _enterPlayMode();
    }
  }

  /// Rec → Play: finalize any capture, then auto-arm every track that holds (or
  /// is finishing) content, so the recorded loops are immediately playable and
  /// shown green without pressing each one.
  void _enterPlayMode() {
    for (final track in _tracks) {
      if (track.isCapturing) _looper.record(channel: track.channel);
    }
    final armed = {
      for (final track in _tracks)
        if (track.hasContent || track.isCapturing) track.channel,
    };
    _emitPedal(state.copyWith(mode: PedalMode.play, playArmed: armed));
  }

  void _toggleBank() {
    final nextBank = state.activeBank == 0 ? 1 : 0;
    final base = nextBank * PedalState.tracksPerBank;
    // Re-resolve the Rec cursor to the new bank (default its first track).
    _emitPedal(state.copyWith(activeBank: nextBank, selectedTrack: base));
    _onBankSelected?.call(nextBank);
    _onTrackSelected?.call(base);
  }

  void _onClear() {
    // Clear is instantaneous. Erase every track immediately, then land the
    // pedal on a clean start point (bank A, track 1, nothing armed).
    _clearAllTracks();
    _emitPedal(
      state.copyWith(activeBank: 0, selectedTrack: 0, playArmed: const {}),
    );
    _onBankSelected?.call(0);
    _onTrackSelected?.call(0);
  }

  void _clearAllTracks() {
    for (var channel = 0; channel < PedalStateFrame.trackCount; channel++) {
      _looper.clear(channel: channel);
    }
  }

  // --- Undo / encoder -------------------------------------------------------

  void _armUndo() {
    _undoArmed = true;
    _undoHandled = false;
    _undoTimer?.cancel();
    _undoTimer = Timer(_longPress, () {
      _undoHandled = true; // long-press = redo
      _looper.redo(channel: state.selectedTrack);
    });
  }

  void _onUndoRelease() {
    if (!_undoArmed) return;
    _undoArmed = false;
    _undoTimer?.cancel();
    _undoTimer = null;
    if (!_undoHandled) _looper.undo(channel: state.selectedTrack); // tap = undo
  }

  void _onEncoder(int delta) {
    _masterGain = (_masterGain + delta * _encoderStep).clamp(0.0, 1.0);
    _looper.setMasterGain(_masterGain);
  }

  // --- Overlay mutations ----------------------------------------------------

  /// Selects [channel] as the Rec cursor and mirrors it to loopy's UI.
  void _selectTrack(int channel) {
    _emitPedal(state.copyWith(selectedTrack: channel));
    _onTrackSelected?.call(channel);
  }

  void _setPlayArmed(Set<int> armed) =>
      _emitPedal(state.copyWith(playArmed: armed));

  static Set<int> _withToggled(Set<int> set, int value) {
    final next = {...set};
    if (!next.remove(value)) next.add(value);
    return next;
  }

  // ---------------------------------------------------------------------------
  // Outbound projection
  // ---------------------------------------------------------------------------

  void _onLooperState(LooperState looperState) {
    _looperState = looperState;
    // Reconcile the armed set against looper truth: drop any channel that is no
    // longer a real (or finalizing) loop — e.g. cleared from the on-screen UI —
    // so a stale green LED can't linger and the transport helpers can't act on
    // an empty channel. (loopy is the single source of truth.)
    final pruned = state.playArmed
        .where((c) => _playable(_trackAtIn(looperState, c)))
        .toSet();
    if (pruned.length != state.playArmed.length) {
      emit(state.copyWith(playArmed: pruned));
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
    _pushProjected();
  }

  void _pushProjected() {
    final looperState = _looperState;
    if (looperState == null) return;
    final frame = _projectFrame(looperState, state);
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
    final lengthMicros = sampleRate > 0
        ? (s.transport.masterLengthFrames * 1000000 / sampleRate).round()
        : 0;
    return PedalStateFrame(
      globalColor: global,
      trackLeds: leds,
      activeBank: pedal.activeBank,
      armedTrack: pedal.selectedTrack,
      mode: pedal.mode,
      loopLengthMicros: lengthMicros.clamp(
        0,
        PedalStateFrame.maxLoopLengthMicros,
      ),
      // Clear is instantaneous now — there is no clear-fade overlay state.
      clearFadeActive: false,
    );
  }

  PedalTrackLed _ledFor(
    Track? track,
    PedalState pedal, {
    required bool selected,
  }) {
    switch (pedal.mode) {
      case PedalMode.play:
        // Green = armed for play (in the set), whether currently playing,
        // muted, or parked — the LEDs show what Rec/Play will resume.
        final channel = track?.channel;
        return channel != null && pedal.playArmed.contains(channel)
            ? PedalTrackLed.green
            : PedalTrackLed.off;
      case PedalMode.rec:
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
