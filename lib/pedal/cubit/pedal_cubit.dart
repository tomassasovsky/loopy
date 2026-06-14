import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_client/midi_client.dart' show MidiDevice;
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
  /// source of truth for its own bank in v1).
  PedalCubit({
    required PedalRepository pedal,
    required LooperRepository looper,
    required SettingsRepository settings,
    void Function(int bank)? onBankSelected,
  }) : _pedal = pedal,
       _looper = looper,
       _settings = settings,
       _onBankSelected = onBankSelected,
       super(const PedalState()) {
    _eventsSub = _pedal.events.listen(_handleEvent);
    _statusSub = _pedal.statusChanges.listen(_onBindStatus);
    _looperSub = _looper.looperState.listen(_onLooperState);
  }

  final PedalRepository _pedal;
  final LooperRepository _looper;
  final SettingsRepository _settings;
  final void Function(int bank)? _onBankSelected;

  late final StreamSubscription<PedalEvent> _eventsSub;
  late final StreamSubscription<PedalBindStatus> _statusSub;
  late final StreamSubscription<LooperState> _looperSub;

  // Loaded settings (defaults until [load] resolves them).
  Duration _longPress = const Duration(milliseconds: 500);
  int _clearFadeMs = 1000;

  // Encoder accumulator. The engine exposes no master-gain read-back, so the
  // pedal tracks the value it last sent (unity until the first turn).
  static const double _encoderStep = 1 / 64;
  double _masterGain = 1;

  // Undo press/release timing (tap = undo, long-press = redo).
  Timer? _undoTimer;
  bool _undoArmed = false;
  bool _undoHandled = false;

  // Clear-all fade guard (the abort window).
  Timer? _clearTimer;

  // Play-mode "remembered playing set" (Rec/Play toggles it).
  Set<int>? _playingSet;

  // Latest looper snapshot + diff state for projection.
  LooperState? _looperState;
  PedalStateFrame? _lastFrame;
  int? _lastPosition;

  Future<void>? _loadFuture;

  /// Loads persisted pedal settings and auto-binds the saved output device.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    _longPress = Duration(milliseconds: await _settings.loadPedalLongPressMs());
    _clearFadeMs = await _settings.loadPedalClearFadeMs();
    final saved = await _settings.loadPedalOutputDevice();
    if (saved != null && availableOutputs().any((d) => d.id == saved.id)) {
      _pedal.bind(saved.id);
    }
  }

  /// The host's available MIDI output destinations.
  List<MidiDevice> availableOutputs() => _pedal.availableOutputs();

  /// The id of the currently bound output destination, or `null` when unbound.
  String? get boundOutputId => _pedal.boundOutputId;

  /// Binds the pedal output to [device] and persists the choice.
  Future<void> selectOutput(MidiDevice device) async {
    _pedal.bind(device.id);
    await _settings.savePedalOutputDevice(id: device.id, name: device.name);
  }

  /// Unbinds the pedal output and clears the saved device.
  Future<void> selectNone() async {
    _pedal.unbind();
    await _settings.clearPedalOutputDevice();
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
        // An Undo during a clear fade aborts the fade instead of undoing.
        if (state.clearFadeActive) {
          _abortClearFade();
        } else {
          _armUndo();
        }
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
      _togglePlayingSet();
    } else {
      // Rec mode: the engine's cycling record handles idle -> record ->
      // finalize (-> overdub per the looper's rec_dub) on the armed track.
      _looper.record(channel: state.armedTrack);
    }
  }

  void _onTrack(int index) {
    final channel = state.bankBaseChannel + index;
    if (state.isPlayMode) {
      final track = _trackAt(channel);
      _looper.setMute(muted: !(track?.muted ?? false), channel: channel);
      return;
    }
    // Rec mode.
    final capturing = _capturingChannel();
    if (capturing == null) {
      // Nothing recording: pressing a track just (re)arms it.
      _emitPedal(state.copyWith(armedTrack: channel));
    } else if (capturing == channel) {
      // Same track: finish the loop (engine cycles record).
      _looper.record(channel: channel);
    } else {
      // Hand-off: finalize the recording track, then start the pressed one.
      _looper
        ..record(channel: capturing)
        ..record(channel: channel);
      _emitPedal(state.copyWith(armedTrack: channel));
    }
  }

  void _onStop() {
    if (state.isPlayMode) {
      for (final track in _tracks) {
        if (track.state == TrackState.playing && !track.muted) {
          _looper.setMute(muted: true, channel: track.channel);
        }
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
      // Rec -> Play finalizes any recording/overdubbing track.
      for (final track in _tracks) {
        if (track.isCapturing) _looper.record(channel: track.channel);
      }
    }
    _emitPedal(state.copyWith(mode: next));
  }

  void _toggleBank() {
    final nextBank = state.activeBank == 0 ? 1 : 0;
    final base = nextBank * PedalState.tracksPerBank;
    // Re-resolve the armed track to the new bank (default its first track).
    _emitPedal(state.copyWith(activeBank: nextBank, armedTrack: base));
    _onBankSelected?.call(nextBank);
  }

  void _onClear() {
    if (_clearFadeMs <= 0) {
      _clearAll();
      return;
    }
    if (state.clearFadeActive) {
      _abortClearFade(); // a 2nd Clear during the fade aborts it
      return;
    }
    _emitPedal(state.copyWith(clearFadeActive: true));
    _clearTimer = Timer(Duration(milliseconds: _clearFadeMs), () {
      _clearAll();
      if (!isClosed) _emitPedal(state.copyWith(clearFadeActive: false));
    });
  }

  void _clearAll() {
    for (var channel = 0; channel < PedalStateFrame.trackCount; channel++) {
      _looper.clear(channel: channel);
    }
    _playingSet = null;
  }

  void _abortClearFade() {
    _clearTimer?.cancel();
    _clearTimer = null;
    if (state.clearFadeActive) {
      _emitPedal(state.copyWith(clearFadeActive: false));
    }
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

  void _togglePlayingSet() {
    final playing = [
      for (final track in _tracks)
        if (track.state == TrackState.playing && !track.muted) track.channel,
    ];
    if (playing.isNotEmpty) {
      _playingSet = playing.toSet();
      for (final channel in playing) {
        _looper.setMute(muted: true, channel: channel);
      }
    } else {
      for (final channel in _playingSet ?? const <int>{}) {
        _looper.setMute(muted: false, channel: channel);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Outbound projection
  // ---------------------------------------------------------------------------

  void _onLooperState(LooperState looperState) {
    _looperState = looperState;
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
        _ledFor(_trackAtIn(s, channel), armed: channel == pedal.armedTrack),
    ];
    final recording = s.tracks.any((t) => t.isCapturing);
    final global = pedal.clearFadeActive
        ? GlobalColor.blue
        : pedal.isPlayMode
        ? GlobalColor.amber
        : recording
        ? GlobalColor.red
        : GlobalColor.green;
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
      clearFadeActive: pedal.clearFadeActive,
    );
  }

  PedalTrackLed _ledFor(Track? track, {required bool armed}) {
    if (track == null) return PedalTrackLed.off;
    if (track.isCapturing) return PedalTrackLed.red;
    if (armed) return PedalTrackLed.red;
    if (track.state == TrackState.playing && !track.muted) {
      return PedalTrackLed.green;
    }
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
    _ => 0,
  };

  @override
  Future<void> close() async {
    _undoTimer?.cancel();
    _clearTimer?.cancel();
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
