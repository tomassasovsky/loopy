import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:settings_repository/settings_repository.dart';

part 'pedal_state.dart';

/// Drives the bidirectional foot pedal: turns inbound [PedalEvent]s into
/// `LooperRepository` commands and projects the looper snapshot back into a
/// [PedalStateFrame] that it pushes to the pedal's LEDs.
///
/// loopy is the single source of truth — the cubit holds the pedal-facing
/// overlay (mode / armed track / bank / clear-fade) in [PedalState], reads all
/// transport/track truth from the looper, and never trusts pedal-side state.
///
/// The behavior table (Rec vs Play mode) and the snapshot-driven derivation of
/// discrete actions from the engine's single cycling `record` command live in
/// [_handleEvent]. The encoder drives the global master gain.
class PedalCubit extends Cubit<PedalState> {
  /// Creates a [PedalCubit].
  ///
  /// [onBankSelected] is called whenever the pedal changes the active bank, so
  /// the wiring layer can keep the app's `BankCubit` in sync (the pedal is the
  /// source of truth for its own bank in v1). [onTrackSelected] is called with
  /// the absolute channel whenever the pedal arms a track, so the wiring layer
  /// can move loopy's on-screen selected track to match.
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

  // Play-mode "armed for play" set: the channels the user has selected to play.
  // Membership (not the engine's playing/stopped state) drives the green track
  // LEDs and persists across Stop, so the LEDs keep showing what Rec/Play will
  // resume. Seeded from the recorded tracks on entering Play mode.
  final Set<int> _playSet = {};

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
      armed: channel == state.armedTrack,
    );
  }

  /// Arms [channel] for Rec mode and mirrors the selection to loopy's UI.
  void armTrack(int channel) => _setArmed(channel);

  /// Toggles Rec / Play mode (same rules as the pedal's Mode footswitch).
  void toggleMode() => _toggleMode();

  /// Toggles [channel]'s play-mode armed set membership without transport
  /// changes — for on-screen mute toggles while the looper handles playback.
  void togglePlayArm(int channel) {
    if (!state.isPlayMode) return;
    final track = _trackAt(channel);
    if (track == null || !track.hasContent) return;
    if (_playSet.contains(channel)) {
      _playSet.remove(channel);
    } else {
      _playSet.add(channel);
    }
    _emitPedal(state);
  }

  /// Mirrors the on-screen bank switch into pedal overlay state.
  void selectBank(int bank) {
    if (bank != 0 && bank != 1) return;
    if (bank == state.activeBank) return;
    final base = bank * PedalState.tracksPerBank;
    _emitPedal(state.copyWith(activeBank: bank, armedTrack: base));
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

  void _onRecPlay() {
    if (state.isPlayMode) {
      _togglePlayback();
    } else {
      // Rec mode: the engine's cycling record handles idle -> record ->
      // finalize (-> overdub per the looper's rec_dub) on the armed track.
      _looper.record(channel: state.armedTrack);
    }
  }

  void _onTrack(int index) {
    final channel = state.bankBaseChannel + index;
    if (state.isPlayMode) {
      // Play mode: toggle the pressed track's "armed for play" membership.
      // Arming (green) starts it playing; disarming (off) stops it. Empty
      // tracks have nothing to play.
      final track = _trackAt(channel);
      if (track == null || !track.hasContent) return;
      if (_playSet.remove(channel)) {
        _looper.stopTrack(channel: channel); // disarm -> off
      } else {
        _playSet.add(channel);
        _looper.play(channel: channel); // arm -> green + play
      }
      _pushProjected();
      return;
    }
    // Rec mode.
    final capturing = _capturingChannel();
    if (capturing == null) {
      // Nothing recording: pressing a track just (re)arms it.
      _setArmed(channel);
    } else if (capturing == channel) {
      // Same track: finish the loop (engine cycles record).
      _looper.record(channel: channel);
    } else {
      // Hand-off: finalize the recording track, then start the pressed one.
      _looper
        ..record(channel: capturing)
        ..record(channel: channel);
      _setArmed(channel);
    }
  }

  /// Arms [channel] and mirrors the selection to loopy's on-screen UI.
  void _setArmed(int channel) {
    _emitPedal(state.copyWith(armedTrack: channel));
    _onTrackSelected?.call(channel);
  }

  void _onStop() {
    if (state.isPlayMode) {
      // Stop every track so all playback halts and the transport (and the
      // on-screen playheads) freeze.
      for (final track in _tracks) {
        _looper.stopTrack(channel: track.channel);
      }
      return;
    }
    // Rec mode: mute the armed track, finalizing a recording first.
    final channel = state.armedTrack;
    final track = _trackAt(channel);
    if (track != null && track.isCapturing) {
      _looper.record(channel: channel);
    }
    _looper.setMute(muted: true, channel: channel);
  }

  void _toggleMode() {
    final next = state.isPlayMode ? PedalMode.rec : PedalMode.play;
    if (!state.isPlayMode) {
      // Rec -> Play: finalize any capture, then auto-arm every track that has
      // (or is finishing) content, so the recorded loops are immediately
      // playable and shown green without pressing each one.
      for (final track in _tracks) {
        if (track.isCapturing) _looper.record(channel: track.channel);
      }
      _playSet
        ..clear()
        ..addAll([
          for (final track in _tracks)
            if (track.hasContent || track.isCapturing) track.channel,
        ]);
    }
    _emitPedal(state.copyWith(mode: next));
  }

  void _toggleBank() {
    final nextBank = state.activeBank == 0 ? 1 : 0;
    final base = nextBank * PedalState.tracksPerBank;
    // Re-resolve the armed track to the new bank (default its first track).
    _emitPedal(state.copyWith(activeBank: nextBank, armedTrack: base));
    _onBankSelected?.call(nextBank);
    _onTrackSelected?.call(base);
  }

  void _onClear() {
    // Clear is instantaneous. Erase every track immediately, then re-arm the
    // first track (bank A, track 1) so the pedal lands on a clean start point.
    _clearAll();
    _emitPedal(state.copyWith(activeBank: 0, armedTrack: 0));
    _onBankSelected?.call(0);
    _onTrackSelected?.call(0);
  }

  void _clearAll() {
    for (var channel = 0; channel < PedalStateFrame.trackCount; channel++) {
      _looper.clear(channel: channel);
    }
    _playSet.clear();
  }

  void _armUndo() {
    _undoArmed = true;
    _undoHandled = false;
    _undoTimer?.cancel();
    _undoTimer = Timer(_longPress, () {
      _undoHandled = true; // long-press = redo
      _looper.redo(channel: state.armedTrack);
    });
  }

  void _onUndoRelease() {
    if (!_undoArmed) return;
    _undoArmed = false;
    _undoTimer?.cancel();
    _undoTimer = null;
    if (!_undoHandled) _looper.undo(channel: state.armedTrack); // tap = undo
  }

  void _onEncoder(int delta) {
    _masterGain = (_masterGain + delta * _encoderStep).clamp(0.0, 1.0);
    _looper.setMasterGain(_masterGain);
  }

  /// Rec/Play in Play mode: toggle the whole armed set. If any armed track is
  /// playing, freeze them all; otherwise resume the entire set.
  void _togglePlayback() {
    final anyPlaying = _playSet.any(
      (channel) => _trackAt(channel)?.state == TrackState.playing,
    );
    for (final channel in _playSet) {
      if (anyPlaying) {
        _looper.stopTrack(channel: channel);
      } else {
        _looper.play(channel: channel);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Outbound projection
  // ---------------------------------------------------------------------------

  void _onLooperState(LooperState looperState) {
    _looperState = looperState;
    // Reconcile the pedal-side armed set against looper truth: drop any channel
    // that is no longer a real (or finalizing) loop — e.g. cleared from the
    // on-screen UI — so a stale green LED can't linger and _togglePlayback
    // can't act on an empty channel. (loopy is the single source of truth.)
    _playSet.removeWhere((channel) {
      final track = _trackAtIn(looperState, channel);
      return track == null || (!track.hasContent && !track.isCapturing);
    });
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

  /// Emits [next] and re-projects, so a pedal-overlay change (mode / armed /
  /// bank / clear-fade) is reflected on the LEDs immediately.
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
          armed: channel == pedal.armedTrack,
        ),
    ];
    // global_color carries the ring's activity color: red while recording,
    // amber while overdubbing, green while a loop plays, off when idle. (The
    // pedal's Rec/Play mode is shown separately by the mode LED, from playMode.)
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
      armedTrack: pedal.armedTrack,
      playMode: pedal.isPlayMode,
      loopLengthMicros: lengthMicros.clamp(
        0,
        PedalStateFrame.maxLoopLengthMicros,
      ),
      // Clear is instantaneous now — there is no clear-fade overlay state.
      clearFadeActive: false,
    );
  }

  PedalTrackLed _ledFor(Track? track, PedalState pedal, {required bool armed}) {
    if (pedal.isPlayMode) {
      // Green = armed for play (in [_playSet]), whether currently playing or
      // frozen by Stop; everything else is off.
      final channel = track?.channel;
      return channel != null && _playSet.contains(channel)
          ? PedalTrackLed.green
          : PedalTrackLed.off;
    }
    // Rec mode: the armed (selected) track and any capturing track are red.
    if (armed) return PedalTrackLed.red;
    if (track?.isCapturing ?? false) return PedalTrackLed.red;
    return PedalTrackLed.off;
  }

  // ---------------------------------------------------------------------------
  // Snapshot helpers
  // ---------------------------------------------------------------------------

  List<Track> get _tracks => _looperState?.tracks ?? const [];

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
