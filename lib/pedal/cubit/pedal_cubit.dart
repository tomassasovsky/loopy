import 'dart:async';
import 'dart:developer' as dev;

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:settings_repository/settings_repository.dart';

part 'pedal_state.dart';

/// The pedal's transport layer: binds the MIDI output, decodes inbound
/// [PedalEvent]s into [ControlIntents] calls, and diff-pushes the projected
/// [PedalStateFrame] to the LEDs.
///
/// This cubit stores NOTHING about looper or control state — the overlay
/// (mode / cursor / bank / play intent) lives in the [ControlOverlay] DOMAIN
/// store (never another cubit — no bloc-to-bloc dependency), the behavior in
/// [ControlIntents] (shared verbatim with the keyboard and on-screen
/// surfaces), and every LED is the pure projection
/// `projectFrame(LooperState, overlay)`. What remains here is the pedal
/// LINK: output binding + hotplug, press timing (the undo tap/long-press
/// split, the held Clear LED), and the frame/loop-top wire push.
class PedalCubit extends Cubit<PedalState> {
  /// Creates a [PedalCubit].
  PedalCubit({
    required PedalRepository pedal,
    required LooperRepository looper,
    required ControlOverlay overlay,
    required ControlIntents intents,
    required SettingsRepository settings,
    Duration pollInterval = const Duration(seconds: 2),
  }) : _pedal = pedal,
       _looper = looper,
       _overlay = overlay,
       _intents = intents,
       _settings = settings,
       super(const PedalState()) {
    _eventsSub = _pedal.events.listen(_handleEvent);
    _statusSub = _pedal.statusChanges.listen(_onBindStatus);
    _looperSub = _looper.looperState.listen(_onLooperState);
    _overlay.addListener(_onOverlayChanged);
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
  final ControlOverlay _overlay;
  final ControlIntents _intents;
  final SettingsRepository _settings;

  late final StreamSubscription<PedalEvent> _eventsSub;
  late final StreamSubscription<PedalBindStatus> _statusSub;
  late final StreamSubscription<LooperState> _looperSub;

  // Loaded settings (defaults until [load] resolves them).
  Duration _longPress = const Duration(milliseconds: 500);

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

  /// Loads persisted pedal settings (long-press threshold, saved output) and
  /// auto-binds the saved output device. The boot-default MODE restore lives
  /// in [ControlIntents.load] — it is control state, not pedal state.
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
    if (!isClosed) emit(state.copyWith(boundOutputId: null));
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

  /// The pedal-track LED color for [channel] — the pure projection, exposed
  /// for the on-screen emulation and tests.
  // ignore: prefer_void_public_cubit_methods
  PedalTrackLed trackLedFor(int channel) {
    final looperState = _looperState;
    if (looperState == null) return PedalTrackLed.off;
    return projectTrackLed(looperState, _overlay.state, channel);
  }

  // ---------------------------------------------------------------------------
  // Inbound events -> intents
  // ---------------------------------------------------------------------------

  void _handleEvent(PedalEvent event) {
    switch (event) {
      case ButtonPressed(:final button):
        _onPress(button);
      case ButtonReleased(:final button):
        if (button == PedalButton.undo) _onUndoRelease();
        if (button == PedalButton.clear) _onClearRelease();
      case EncoderDelta(:final delta):
        _log('encoder $delta');
        _intents.encoderTurned(delta);
    }
  }

  void _onPress(PedalButton button) {
    _log(
      'press ${button.name}  [mode=${_overlay.state.mode.name} '
      'cursor=${_overlay.state.cursor}]',
    );
    switch (button) {
      case PedalButton.undo:
        _armUndo();
      case PedalButton.recPlay:
        _intents.recPlay();
      case PedalButton.stop:
        _intents.stop();
      case PedalButton.mode:
        _intents.toggleMode();
      case PedalButton.bank:
        _intents.toggleBankWithCursor();
      case PedalButton.clear:
        _onClear();
      case PedalButton.track1:
      case PedalButton.track2:
      case PedalButton.track3:
      case PedalButton.track4:
        _intents.trackPressed(
          _overlay.state.bankBaseChannel + _trackIndex(button),
        );
    }
  }

  void _onClear() {
    // Light the Clear LED while the footswitch is held (cleared on release).
    _clearHeld = true;
    _intents.clearAll();
    _pushProjected();
  }

  /// Clear footswitch released: darken the Clear LED (the clear itself already
  /// happened on press — this only ends the held-button light).
  void _onClearRelease() {
    if (!_clearHeld) return;
    _clearHeld = false;
    _pushProjected();
  }

  void _armUndo() {
    _undoArmed = true;
    _undoHandled = false;
    _undoChannel = _overlay.state.cursor; // latch the target at press
    _undoTimer?.cancel();
    _undoTimer = Timer(_longPress, () {
      _undoHandled = true; // long-press = redo
      _log('redo ch=$_undoChannel  (long-press)');
      _intents.redo(_undoChannel);
    });
  }

  void _onUndoRelease() {
    if (!_undoArmed) return;
    _undoArmed = false;
    _undoTimer?.cancel();
    _undoTimer = null;
    if (!_undoHandled) {
      _log('undo ch=$_undoChannel  (tap)');
      _intents.undo(_undoChannel);
    }
  }

  int _trackIndex(PedalButton button) => switch (button) {
    PedalButton.track1 => 0,
    PedalButton.track2 => 1,
    PedalButton.track3 => 2,
    PedalButton.track4 => 3,
    _ => throw ArgumentError('not a track button: $button'),
  };

  // ---------------------------------------------------------------------------
  // Outbound projection
  // ---------------------------------------------------------------------------

  void _onOverlayChanged(ControlOverlayState _) => _pushProjected();

  void _onLooperState(LooperState looperState) {
    _looperState = looperState;
    _detectLoopTop(looperState);
    _pushProjected();
  }

  void _onBindStatus(PedalBindStatus status) {
    if (isClosed) return;
    emit(state.copyWith(bindStatus: status));
    // A fresh bind has no last frame on the pedal — force the next push (it
    // reads the CURRENT overlay, so a mode/cursor changed while unplugged
    // shows correctly on replug).
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

  void _pushProjected() {
    final looperState = _looperState;
    if (looperState == null) return;
    final frame = projectFrame(
      looperState,
      _overlay.state,
      clearFadeActive: _clearHeld,
    );
    if (frame == _lastFrame) return; // diff: only push on change
    _lastFrame = frame;
    _pedal.pushState(frame);
  }

  void _log(String message) => dev.log(message, name: 'pedal');

  @override
  Future<void> close() async {
    _undoTimer?.cancel();
    _pollTimer?.cancel();
    _overlay.removeListener(_onOverlayChanged);
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
