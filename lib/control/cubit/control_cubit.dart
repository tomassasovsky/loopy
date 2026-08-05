import 'dart:async';
import 'dart:developer' as dev;

import 'package:bloc/bloc.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/common/fx_chain_persistence.dart';
import 'package:segno/control/binding/control_value_resolver.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/controller_learn.dart';
import 'package:segno/control/binding/fx_binding_resolver.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/binding/pedal_binding.dart';
import 'package:segno/control/binding/pedal_binding_set.dart';
import 'package:segno/control/control_projection.dart';
import 'package:segno/logging/app_log.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:settings_repository/settings_repository.dart';

part 'control_state.dart';

/// The press/long-press state machine every gestural footswitch shares.
///
/// [press] arms a hold timer and remembers the tap action; holding past the
/// threshold runs `onHold` and RETIRES that action, so the matching [release]
/// stays silent. Releasing first runs it instead. Both callbacks are built at
/// press time, so anything a gesture must latch (the undo target channel) is
/// simply captured by the closures — a later on-screen change cannot retarget
/// the action the foot already committed to.
///
/// A gesture whose action fires on the press itself (the FX Stop panic) passes
/// no `onTap`: its release then only retires the pending hold, which is what
/// makes a synthetic release — the on-screen plate note-off'ing a held switch
/// as it leaves the tree — harmless.
///
/// The remembered tap action doubles as the armed flag: a release with nothing
/// pending is inert, so an unmatched release can never fire a stale gesture.
class _HoldGesture {
  Timer? _timer;
  void Function()? _onTap;

  void press({
    required Duration threshold,
    required void Function() onHold,
    void Function()? onTap,
  }) {
    _onTap = onTap;
    _timer?.cancel();
    _timer = Timer(threshold, () {
      _timer = null;
      _onTap = null; // handled as a hold: the release stays silent
      onHold();
    });
  }

  void release() {
    _timer?.cancel();
    _timer = null;
    final onTap = _onTap;
    _onTap = null;
    onTap?.call();
  }

  /// Drops the pending hold and tap without running either — cubit teardown.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _onTap = null;
  }
}

/// The ONE control-surface interpreter and the ONE owner of stored user
/// intent ([ControlState]) — a single business-logic-layer unit, per the
/// layered architecture: repositories are composed at the bloc level, so
/// there is no domain-service orphan between the repositories and the blocs,
/// and no cubit ever depends on another cubit.
///
/// Inputs arrive only through repository streams and its own methods:
/// - `LooperRepository.looperState` drives [_reduce] — the invalidation
///   table every stored bit obeys (cursor clamps; excluded/parkedResume
///   members drop when their track empties) — plus the loop-top pulse and
///   the frame re-projection.
/// - `PedalRepository.events` delivers the decoded footswitches, which call
///   the SAME intent methods the keyboard and on-screen widgets call — the
///   surfaces cannot diverge in the command sequences they issue.
///
/// Outputs leave only through repositories: engine commands via
/// [LooperRepository], and the projected LED frame (`projectFrame`, a pure
/// function of `(LooperState × ControlState)`) diff-pushed via
/// [PedalRepository]. Derived state is never stored, so it can never go
/// stale.
class ControlCubit extends Cubit<ControlState> {
  /// Creates a [ControlCubit] over the shared repositories.
  ///
  /// [performance] backs the MODE-footswitch long-press gesture
  /// (arm/disarm performance recording, D-PEDAL) and the clear-while-armed
  /// persist-before-clear ordering — composed here rather than routed
  /// through `PerformanceRecorderCubit`, since cubits never call cubits;
  /// that cubit observes this repository's own status stream, so it reflects
  /// a pedal-triggered arm/disarm too.
  ///
  /// [currentChains] resolves the live lane/monitor chains + master-limiter
  /// state to stamp into the arm snapshot, read fresh at each arm — the same
  /// narrow function dependency `PerformanceRecorderCubit` takes for the
  /// toolbar path, so both arm gestures record the same rig. It is injected
  /// rather than mapped here: the mapping lives in the session feature, and a
  /// feature never imports another feature. Defaults to the empty snapshot
  /// (what this call site passed before it was wired).
  /// [controller] is the external-MIDI seam (part 7): its resolved binding
  /// events land at the same dispatch point the pedal's do, so a discrete CC
  /// stomps exactly like a footswitch. [midiDevices] supplies the connectivity
  /// this cubit needs to honour the release-all rule when the MIDI source
  /// itself disappears (B1). Both are optional — a build or test with no MIDI
  /// seam simply never receives external control.
  ControlCubit({
    required LooperRepository looper,
    required PedalRepository pedal,
    required SettingsRepository settings,
    required PerformanceRepository performance,
    ControllerRepository? controller,
    MidiDeviceRepository? midiDevices,
    Duration keepAliveInterval = const Duration(seconds: 1),
    Duration learnTimeout = const Duration(seconds: 15),
    Duration mappingsWriteDebounce = const Duration(milliseconds: 400),
    PerformanceChains Function() currentChains = _noChains,
  }) : _looper = looper,
       _pedal = pedal,
       _settings = settings,
       _performance = performance,
       _controller = controller,
       _learnTimeout = learnTimeout,
       _mappingsWriteDebounce = mappingsWriteDebounce,
       _currentChains = currentChains,
       super(const ControlState()) {
    _looperSub = _looper.looperState.listen(_onLooperState);
    _eventsSub = _pedal.events.listen(_handleEvent);
    _statusSub = _pedal.statusChanges.listen(_onBindStatus);
    _perfStatusSub = _performance.captureStatus.listen(_onPerformanceStatus);
    _bindingSub = controller?.bindingEvents.listen(_onControllerBindingEvent);
    _midiSub = midiDevices?.connections.listen(_onMidiConnection);
    // Re-push the current frame on a slow heartbeat so the pedal can tell a
    // live link (frames still arriving) from a dropped one (USB unplugged / app
    // closed) and blank its LEDs. Only on-change pushes happen otherwise, so a
    // stopped, idle loop would look identical to a dead link without this.
    // Pass Duration.zero to disable (tests drive frames explicitly).
    if (keepAliveInterval > Duration.zero) {
      _keepAliveTimer = Timer.periodic(
        keepAliveInterval,
        (_) => _pushProjected(force: true),
      );
    }
  }

  /// The default `currentChains`: an empty rig, which is what
  /// [PerformanceRepository.arm] already assumes when given nothing.
  static PerformanceChains _noChains() => const PerformanceChains();

  final LooperRepository _looper;
  final PedalRepository _pedal;
  final SettingsRepository _settings;
  final PerformanceRepository _performance;
  final ControllerRepository? _controller;
  final Duration _learnTimeout;
  final Duration _mappingsWriteDebounce;
  final PerformanceChains Function() _currentChains;

  late final StreamSubscription<LooperState> _looperSub;
  late final StreamSubscription<PedalEvent> _eventsSub;
  late final StreamSubscription<PedalBindStatus> _statusSub;
  late final StreamSubscription<PerformanceCaptureStatus> _perfStatusSub;
  StreamSubscription<ControllerBindingEvent>? _bindingSub;
  StreamSubscription<MidiConnection>? _midiSub;

  // Encoder accumulator: the engine exposes no master-gain read-back, so the
  // control layer tracks the value it last sent (unity until the first turn).
  static const double _encoderStep = 1 / 64;
  double _masterGain = 1;

  // The hold threshold every gesture below arms with, read at press time so a
  // settings change lands on the next stomp.
  Duration _longPress = const Duration(milliseconds: 500);
  Timer? _keepAliveTimer;

  // Undo: tap = undo, long-press = redo. The target channel is LATCHED at
  // press time (captured by the callbacks) — an on-screen click mid-hold must
  // not retarget the action the foot already committed to.
  final _undoGesture = _HoldGesture();

  // MODE: tap = cycle the interaction mode, long-press = arm/disarm
  // performance recording (D-PEDAL). No spare footswitch/pin exists on the
  // physical pedal, so the gesture rides the existing MODE button rather than
  // a new one — mirrors the undo/redo split above.
  final _modeGesture = _HoldGesture();

  // The FX-mode Stop long-press (restore every Track chain). The panic half
  // fires on the press, so this one arms no tap action — only the hold.
  final _stopGesture = _HoldGesture();

  // The remap (part 6b) lives in ControlState — it is stored user intent, and
  // the surfaces that render it rebuild on emit. What stays here is only the
  // mid-gesture restore VALUES: the enabled state each held press captured,
  // which no surface renders and which must not survive a hot restart.
  //
  // Keyed by [PedalBindingKey] rather than by target, so two bindings on one
  // target each restore what THEY captured (last writer wins, per
  // [PedalBinding]'s doc). A button can only be held once, so the key is
  // unique for the lifetime of a press. Kept in lockstep with
  // `state.heldMomentary`, which is the same key set.
  final _heldRestore =
      <PedalBindingKey, ({FxBindingTarget target, bool prior})>{};

  // The mid-gesture restore values for MOMENTARY bindings held from an
  // external MIDI control: one entry per TARGET, carrying the state the first
  // press found and the set of controls currently holding it.
  //
  // Reference-counted rather than one slot per control, because two switches
  // can be mapped to one chain. A per-control capture would have the second
  // press record the state the FIRST press just enabled, and its release would
  // then write `true` back with no foot on either switch — a stuck momentary.
  // A per-target slot alone would let the first release end the second's hold.
  // Holding the first press's capture until the LAST control lets go is the
  // only reading with no stranded state and no early release.
  //
  // Kept apart from `_heldRestore` because their release-all triggers differ: a
  // MIDI momentary survives a mode change (external control is not mode-gated)
  // but must release when its device unplugs, which the pedal's own held
  // presses have no reason to care about.
  final _heldControllerRestore =
      <
        String,
        ({FxBindingTarget target, bool prior, Set<MappingTrigger> holders})
      >{};

  // The learn capture's timeout. A capture that nobody ever feeds must not
  // leave the MIDI stream swallowed forever — the repository suppresses ALL
  // events while learning.
  Timer? _learnTimer;

  // Which capture is current. Every `learnNext` future resolves — including
  // the null a SUPERSEDED one gets when the next capture replaces it — so a
  // callback has to prove it still speaks for the capture in flight. Without
  // that proof a stale null tore down the live capture's state and timeout
  // while the repository went on swallowing every controller event.
  int _learnGeneration = 0;

  // The mapping blob's pending write. A LO/HI knob reports continuously while
  // it is dragged, so the STATE and the repository follow every frame (the
  // sound has to track the finger) while the settings write is coalesced —
  // otherwise one drag costs ~60 JSON encodes and store writes a second.
  // Flushed by `close()`, so a quit mid-drag still persists.
  Timer? _mappingsWriteTimer;
  String? _pendingMappingsBlob;

  // Every controller binding's target, decoded ONCE per mapping-set change.
  // The dispatch path runs per smoothing tick, and re-parsing a canonical-JSON
  // string that only changes on an edit is pure waste on the hot path. A target
  // that does not decode is absent here, which reads as the same no-op a stale
  // one gets.
  final _controllerValueTargets = <String, ControlValueTarget>{};
  final _controllerSwitchTargets = <String, FxBindingTarget>{};

  // Whether the Clear footswitch is currently held down. Lights the Clear
  // LED (the `clearFadeActive` frame bit) for as long as it is pressed.
  bool _clearHeld = false;

  // Mirrors `PerformanceRepository.captureStatus` so the pedal frame can
  // render the armed LED without re-deriving it from the raw status stream on
  // every projection. Independent of `ControlState` (nothing routes through
  // stored intent), so a status change re-projects directly rather than
  // through `emit`.
  bool _performanceArmed = false;

  // Latest looper snapshot + diff state for the frame push.
  LooperState? _looperState;
  PedalStateFrame? _lastFrame;
  int? _lastPosition;

  Future<void>? _loadFuture;

  List<Track> get _tracks => _l.tracks;

  /// The looper truth every intent method reads: the last POLLED snapshot —
  /// the SAME one the frame projection and the invariant spec are defined
  /// over. `LooperRepository.state` is a live engine read; deciding intent
  /// from it while projecting from the polled copy let the two skew inside
  /// one emit whenever an engine change landed between polls (e.g. a record
  /// starting right before a mode toggle), tripping the projection-time
  /// invariant assert. Live read only before the first poll arrives.
  LooperState get _l => _looperState ?? _looper.state;

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

  /// Restores the persisted boot-default mode (applying it — a `mute`
  /// default runs the same entry side effects as a live toggle) and the
  /// undo long-press threshold.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    _longPress = Duration(milliseconds: await _settings.loadPedalLongPressMs());
    final storedBindings = PedalBindingSet.decode(
      await _settings.loadPedalBindings() ?? '',
    );
    final storedControllerBindings = ControllerBindingSet.decode(
      await _settings.loadControllerMappings() ?? '',
    );
    // bootDefaultFromToken, not fromToken: a stored `'fx'` (hand-edited or
    // corrupted — no build writes it) falls back to record rather than booting
    // the dead FX surface (R12).
    final defaultMode = InteractionMode.bootDefaultFromToken(
      await _settings.loadDefaultInteractionMode(),
    );
    if (isClosed) return;
    // The repository resolves inputs against the set, so it has to learn the
    // restored mappings too — otherwise external control stays dead until the
    // user happens to edit a row.
    _controller?.setBindings(storedControllerBindings);
    _cacheControllerTargets(storedControllerBindings);
    emit(
      state.copyWith(
        defaultMode: defaultMode,
        globalBindings: storedBindings,
        controllerBindings: storedControllerBindings,
      ),
    );
    setMode(defaultMode);
  }

  // ---------------------------------------------------------------------------
  // The looper reducer: the stored-intent invalidation table.
  // ---------------------------------------------------------------------------

  void _reduce(LooperState looper) {
    var next = state;

    // Cursor: always a valid channel.
    if (looper.tracks.isNotEmpty &&
        (state.cursor < 0 || state.cursor >= looper.tracks.length)) {
      final cursor = state.cursor.clamp(0, looper.tracks.length - 1);
      next = next.copyWith(
        cursor: cursor,
        activeBank: cursor ~/ ControlState.tracksPerBank,
      );
    }

    // Excluded / parkedResume: membership requires a track that still holds
    // (or is finishing) a loop. An emptied track (undo-to-empty, clear,
    // clear-all, session load) drops out, so no stored set can reference a
    // ghost.
    bool playable(int channel) {
      if (channel < 0 || channel >= looper.tracks.length) return false;
      final t = looper.tracks[channel];
      return t.hasContent || t.isCapturing;
    }

    if (state.excluded.any((c) => !playable(c))) {
      next = next.copyWith(excluded: state.excluded.where(playable).toSet());
    }
    if (state.parkedResume.any((c) => !playable(c))) {
      next = next.copyWith(
        parkedResume: state.parkedResume.where(playable).toSet(),
      );
    }

    if (next != state) emit(next);
  }

  // ---------------------------------------------------------------------------
  // Mode
  // ---------------------------------------------------------------------------

  /// Cycles Record -> Mute -> FX -> Record (identical from every surface).
  ///
  /// A three-stop cycle, not a toggle: FX mode joins the same MODE footswitch
  /// rather than claiming a switch the hardware does not have. Side effects
  /// fire for the LANDED mode only — cycling PAST a mode never runs its entry
  /// work (A5), which falls out of [setMode] being the single entry point.
  void toggleMode() => setMode(switch (state.mode) {
    InteractionMode.record => InteractionMode.mute,
    InteractionMode.mute => InteractionMode.fx,
    InteractionMode.fx => InteractionMode.record,
  });

  /// Applies [next] with its entry side effects; a no-op when already there.
  ///
  /// Entering Mute previews the whole content set: `parkedResume` = every
  /// track holding (or capturing) a loop, so Rec/Play resumes them all and
  /// the parked LEDs show it — including stopped and muted tracks, which
  /// pure `sounding` could never cover. A live capture survives THIS entry:
  /// the mode toggle is a view change, not a transport action.
  ///
  /// Entering FX cancels every PENDING record arm — quantized, sound-armed,
  /// or a Band section toggle. An arm is the one thing that could start a take
  /// the user never sees: it fires on its own, seconds later, in a mode whose
  /// transport controls are all inert. The cancel is unconditional
  /// (`LooperRepository.cancelArm`), so no engine setting can turn it into a
  /// press with different meaning.
  ///
  /// A LIVE capture, though, survives FX exactly as it survives Mute: the mode
  /// toggle stays a view change, not a transport action, and the take ends
  /// when the user cycles back to Rec and hits Rec/Play (or Stop). Ending it
  /// here was tried and withdrawn — the only tool available is a record press,
  /// which under quantize does not finalize at all but ARMS a loop-top
  /// finalize, so the take ran on past the mode change and FX was entered with
  /// a fresh arm, the exact state this entry clears. A finalize that ignores
  /// quantize needs an engine primitive that does not exist yet; until it
  /// does, "the capture survives" is the honest contract and matches Mute.
  ///
  /// Any mode entry clears the stored mute-mode intent (the invalidation
  /// table).
  void setMode(InteractionMode next) {
    if (next == state.mode) return;
    // Leaving the mode the bindings live in strands any held momentary — the
    // release will arrive with the foot in a mode that no longer dispatches
    // it, or not at all. Restore first (B1), before the emit re-projects.
    releaseAllMomentary();
    switch (next) {
      case InteractionMode.record:
        emit(
          state.copyWith(
            mode: InteractionMode.record,
            excluded: const <int>{},
            parkedResume: const <int>{},
          ),
        );
      case InteractionMode.mute:
        emit(
          state.copyWith(
            mode: InteractionMode.mute,
            excluded: const <int>{},
            parkedResume: {
              for (final track in _tracks)
                if (_playable(track)) track.channel,
            },
          ),
        );
      case InteractionMode.fx:
        // Cancel arms BEFORE the emit so the projection that rides it already
        // describes the post-entry intent (the engine's own state follows one
        // poll later, as it does for every other command).
        //
        // Read LIVE engine truth, not the polled snapshot: an arm cancelled or
        // fired moments ago still reads `pending` for up to one poll, and the
        // cancel is cheap enough that a stale read costs only a no-op.
        for (final track in _looper.state.tracks) {
          if (track.pending) _looper.cancelArm(channel: track.channel);
        }
        emit(
          state.copyWith(
            mode: InteractionMode.fx,
            excluded: const <int>{},
            parkedResume: const <int>{},
          ),
        );
    }
  }

  /// Sets and persists the default [mode] the system boots into, applying it
  /// to the live mode now.
  ///
  /// Ignores a mode outside [InteractionMode.bootDefaults] (R12): the settings
  /// picker never offers FX, and a boot into FX with no chains configured is a
  /// dead surface.
  Future<void> setDefaultMode(InteractionMode mode) async {
    // Loud in debug, defensive in release: a caller offering FX here has a
    // bug, but shipping a dead boot surface is the worse outcome.
    assert(
      InteractionMode.bootDefaults.contains(mode),
      '$mode is not a boot-eligible default mode',
    );
    if (!InteractionMode.bootDefaults.contains(mode)) return;
    emit(state.copyWith(defaultMode: mode));
    setMode(mode);
    await _settings.saveDefaultInteractionMode(mode.token);
  }

  // ---------------------------------------------------------------------------
  // Cursor / bank
  // ---------------------------------------------------------------------------

  /// Moves the shared cursor to [channel], following it into its bank (a
  /// cursor can never hide behind the other bank).
  void selectTrack(int channel) {
    if (channel < 0 || channel >= _channelCount) return;
    emit(
      state.copyWith(
        cursor: channel,
        activeBank: channel ~/ ControlState.tracksPerBank,
      ),
    );
  }

  /// Reveals [bank] WITHOUT moving the cursor — the browse flow (e.g. arming
  /// the other bank's tracks in mute mode).
  void browseBank(int bank) {
    if (bank < 0 || bank >= ControlState.bankCount) return;
    emit(state.copyWith(activeBank: bank));
  }

  /// Toggles the visible bank, moving the cursor to the new bank's first
  /// track — the pedal BANK footswitch / keyboard `B` semantics.
  void toggleBankWithCursor() =>
      selectTrack((state.activeBank == 0 ? 1 : 0) * ControlState.tracksPerBank);

  // ---------------------------------------------------------------------------
  // Rec/Play
  // ---------------------------------------------------------------------------

  /// The Rec/Play action under the current mode.
  ///
  /// INERT in FX mode (A4): the "act on the focused track" reading was
  /// rejected — focus has no on-pedal indicator, so an invisible target would
  /// be mis-stomped. The switch is reserved for a later part rather than given
  /// a guessable meaning.
  void recPlay() {
    switch (state.mode) {
      case InteractionMode.record:
        _recAdvance(state.cursor);
      case InteractionMode.mute:
        _muteRecPlay();
      case InteractionMode.fx:
        break;
    }
  }

  /// Rec mode: advance the cursor track through record / overdub / play. A
  /// muted track is first unmuted and brought back: overdub if its loop still
  /// runs, plain resume if it was parked (the engine unparks the rest of the
  /// loop with it — starting anything resumes everything).
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

  /// Mute mode Rec/Play: resume while parked; while running, expand to the
  /// whole content set (a no-op when everything audible is already in).
  void _muteRecPlay() {
    if (isParked(_l)) {
      final resume = state.parkedResume.isNotEmpty
          ? state.parkedResume
          : {
              for (final track in _tracks)
                if (_playable(track)) track.channel,
            };
      if (resume.isEmpty) return; // nothing recorded yet
      // The engine unparks the ENTIRE loop on the first play (starting
      // anything resumes everything), so a deselected member must be muted
      // BEFORE any play rides the ring: it comes back running-but-silent —
      // exactly what its dark parked LED promised — and stays in phase for a
      // later unmute, instead of staying frozen. A CAPTURING track is not a
      // deselected member — it is a live take (isParked ignores `recording`,
      // so one can be running under a parked transport) and muting it would
      // punch it out; leave it alone.
      for (final track in _tracks) {
        if (_playable(track) &&
            !track.isCapturing &&
            !resume.contains(track.channel) &&
            !track.muted) {
          _looper.setMute(muted: true, channel: track.channel);
        }
      }
      for (final channel in resume) {
        _looper
          ..setMute(muted: false, channel: channel)
          ..play(channel: channel);
      }
      // Consumed: the resumed tracks are now sounding, so the derived armed
      // set carries them from here.
      emit(state.copyWith(parkedResume: const <int>{}));
      return;
    }
    // Running: expand to every content track unless the full audible set is
    // already in the mix (then the press is a no-op).
    final armed = armedTracks(_l, state);
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

  /// The Stop action under the current mode (the pedal's Stop TAP; its
  /// long-press is [restoreAllTrackChains], handled at the press/release
  /// layer like undo/redo's).
  void stop() {
    switch (state.mode) {
      case InteractionMode.record:
        _recStop(state.cursor);
      case InteractionMode.mute:
        parkAll();
      case InteractionMode.fx:
        panicTrackChains();
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
    emit(
      state.copyWith(
        parkedResume: {...running}..removeWhere(state.excluded.contains),
      ),
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
    switch (state.mode) {
      case InteractionMode.record:
        _recTrackPressed(channel);
      case InteractionMode.mute:
        _muteTrackPressed(channel);
      case InteractionMode.fx:
        toggleTrackChain(channel);
    }
  }

  /// Rec mode: select the track, or hand off a live recording to it.
  void _recTrackPressed(int channel) {
    final capturing = _capturingChannel();
    if (capturing == null) {
      selectTrack(channel);
    } else if (capturing == channel) {
      _looper.record(channel: channel); // finish the loop
    } else {
      _looper
        ..record(channel: capturing) // finalize the running capture
        ..record(channel: channel); // start the pressed one
      selectTrack(channel);
    }
  }

  /// Mute mode: while parked, toggle resume membership (arming a muted track
  /// unmutes it so it reads green). While running, a live track toggles its
  /// mute — muting the last audible one parks everything with an empty
  /// resume set (Rec/Play then brings back ALL content) — and a track out of
  /// the mix joins it (un-exclude, unmute, play).
  void _muteTrackPressed(int channel) {
    final track = _trackAt(channel);
    if (!_playable(track)) return;
    final t = track!;
    if (isParked(_l)) {
      if (!state.parkedResume.contains(channel) && t.muted) {
        _looper.setMute(muted: false, channel: channel);
      }
      final next = {...state.parkedResume};
      if (!next.remove(channel)) next.add(channel);
      emit(state.copyWith(parkedResume: next));
      return;
    }
    final live =
        armedTracks(_l, state).contains(channel) &&
        t.state == TrackState.playing;
    if (live) {
      final muting = !t.muted;
      _looper.setMute(muted: muting, channel: channel);
      if (muting && _isLastAudibleArmed(channel)) {
        // Muting the last audible track parks the loop with nothing latched:
        // the next Rec/Play resumes the whole content set.
        for (final c in _running()) {
          _looper.stopTrack(channel: c);
        }
        emit(state.copyWith(parkedResume: const <int>{}));
      }
    } else {
      // Joining is the explicit un-exclude.
      if (state.excluded.contains(channel)) {
        emit(
          state.copyWith(excluded: {...state.excluded}..remove(channel)),
        );
      }
      _looper
        ..setMute(muted: false, channel: channel)
        ..play(channel: channel);
    }
  }

  // ---------------------------------------------------------------------------
  // FX mode (Track-stage chains)
  // ---------------------------------------------------------------------------

  /// Toggles track [channel]'s Track-stage chain (FX mode's track-button
  /// action, shared with the keyboard's digit keys).
  ///
  /// Per-CHAIN, not per-effect: a stomp is a whole-chain bypass (R15,
  /// "disabled == dry through the bus"); per-effect bits and remapped
  /// bindings are a later part.
  void toggleTrackChain(int channel) {
    if (channel < 0 || channel >= _channelCount) return;
    _setTrackChain(channel, enabled: !_looper.trackChainEnabled(channel));
  }

  /// FX panic: every Track-stage chain off in one gesture (Stop in FX mode) —
  /// the eyes-free way out of a chain that has run away mid-song. Restored by
  /// [restoreAllTrackChains] (Stop long-press).
  void panicTrackChains() => _sweepTrackChains(enabled: false);

  /// Puts every Track-stage chain back on (Stop LONG-PRESS in FX mode) — the
  /// undo for [panicTrackChains]. Deliberately "all on" rather than a restore
  /// of the pre-panic pattern: eyes-free on a dark stage, a known end state
  /// beats one the performer has to remember.
  void restoreAllTrackChains() => _sweepTrackChains(enabled: true);

  /// Flips Track-stage chains across every channel, ASYMMETRICALLY on empties.
  ///
  /// Disabling skips a track with no chain: its flag says nothing audible
  /// either way, and writing it would persist a bypass the boot restore
  /// replays forever, silently muting the effects the user adds to that track
  /// later. Skipping also keeps one Stop stomp proportional to the rig — the
  /// repository re-snapshots the engine and re-emits per call, so sweeping all
  /// eight channels cost eight engine snapshots, pedal frames and settings
  /// writes for a rig that usually has one or two chains.
  ///
  /// ENABLING sweeps everything, empties included. Clearing a bypass is always
  /// safe, and a chain-less track can genuinely be carrying a stale one — the
  /// FX dock can disable a chain and then empty it — which is exactly the
  /// silent-dry state this restore exists to undo. A "restore all" that could
  /// not reach it would leave the only pedal-side cure unreachable.
  void _sweepTrackChains({required bool enabled}) {
    for (var channel = 0; channel < _channelCount; channel++) {
      if (!enabled && _looper.trackEffects(channel).isEmpty) continue;
      _setTrackChain(channel, enabled: enabled);
    }
  }

  /// Applies one Track-chain flag and persists the envelope, skipping a no-op
  /// so a panic over already-off chains costs no settings writes.
  ///
  /// Reads the repository's remembered intent rather than the polled
  /// [LooperState]: chain-enabled is set synchronously here (no engine
  /// round-trip), so two fast stomps must not both see the same pre-poll
  /// value. The LEDs still follow the polled snapshot, exactly like mute.
  void _setTrackChain(int channel, {required bool enabled}) {
    if (_looper.trackChainEnabled(channel) == enabled) return;
    _looper.setTrackChainEnabled(channel: channel, enabled: enabled);
    // The same envelope `LooperBloc` writes for the on-screen path — a cubit
    // never calls a bloc, so both call the shared helper instead of one
    // routing through the other.
    persistTrackFxChain(settings: _settings, looper: _looper, channel: channel);
  }

  // ---------------------------------------------------------------------------
  // Clear-all / undo / redo / encoder
  // ---------------------------------------------------------------------------

  /// The whole-rig reset, unified across surfaces: every track holding
  /// content OR a redo history is cleared and re-armed (unmuted, persisted),
  /// and the overlay returns home (record mode, cursor 0). Undone-to-empty
  /// tracks must be included — only clear wipes their resurrect path, and the
  /// master grid resets once everything is empty.
  ///
  /// While performance recording is armed (D-CLEAR), awaits
  /// [PerformanceRepository.persistLiveLanes] first: a track mid-capture is
  /// skipped by the engine clear below (the audio thread still owns its
  /// buffer), so its performance-recording bundle would otherwise lose that
  /// pass entirely rather than the persisted-then-cleared PCM the repository
  /// itself already knows how to skip.
  Future<void> clearAll() async {
    if (_performanceArmed) await _performance.persistLiveLanes();
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
    emit(
      state.copyWith(
        mode: InteractionMode.record,
        cursor: 0,
        activeBank: 0,
        excluded: const <int>{},
        parkedResume: const <int>{},
      ),
    );
    // The clear may be a state no-op (already home) while the held-LED bit
    // still needs to reach the wire.
    _pushProjected();
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
    // Push a fresh frame so the pedal ring reflects the new gain (the volume
    // meter is driven by the frame value, not a local echo).
    _pushProjected();
  }

  // ---------------------------------------------------------------------------
  // Inbound pedal events -> the same intent methods (via PedalRepository)
  // ---------------------------------------------------------------------------

  void _handleEvent(PedalEvent event) {
    switch (event) {
      case ButtonPressed(:final button):
        _onPress(button);
      case ButtonReleased(:final button):
        if (button == PedalButton.undo) _undoGesture.release();
        if (button == PedalButton.clear) _onClearRelease();
        if (button == PedalButton.mode) _modeGesture.release();
        if (button == PedalButton.stop) _stopGesture.release();
        // Unconditional: a momentary is keyed to the button, so this finds
        // the held one (if any) whatever else that button's release did.
        _releaseBinding(button);
      case EncoderDelta(:final delta):
        _log('encoder $delta');
        encoderTurned(delta);
    }
  }

  void _onPress(PedalButton button) {
    _log(
      'press ${button.name}  [mode=${state.mode.name} '
      'cursor=${state.cursor}]',
    );
    final fx = state.mode == InteractionMode.fx;
    // A remap overrides its button's contextual DEFAULT, and only in FX mode —
    // the other two modes are transport surfaces a binding must never shadow.
    // MODE and Bank can never appear here: the binding model refuses to hold
    // one (B12), so their handling below is unreachable from a binding.
    if (fx) {
      final binding = state.bindings.lookup(button, bank: state.activeBank);
      if (binding != null) {
        _pressBinding(binding);
        // Stop keeps its restore-all HOLD even when bound: a remap overrides
        // contextual defaults but never the long-press system gestures, and
        // the panic's only undo must stay reachable from the plate whatever
        // the user mapped onto the tap.
        if (button == PedalButton.stop) _armStopRestore();
        return;
      }
    }
    switch (button) {
      case PedalButton.undo:
        // INERT in FX mode until the #219 toggle-undo contract exists: an
        // undo that silently means "the last overdub" while the foot is in a
        // chain-editing mode is the surprise this matrix exists to prevent.
        if (!fx) _armUndo();
      case PedalButton.recPlay:
        recPlay(); // inert in FX mode (A4)
      case PedalButton.stop:
        // FX mode splits Stop into tap = panic / long-press = restore, so the
        // action waits for the release; the other modes act on the press, as
        // they always have.
        if (fx) {
          _armStop();
        } else {
          stop();
        }
      case PedalButton.mode:
        _armMode();
      case PedalButton.bank:
        toggleBankWithCursor();
      case PedalButton.clear:
        // INERT in FX mode, LED included (A2): clear is the one irreversible
        // stomp on the plate, and a stray one must never erase the set.
        if (!fx) _onClear();
      case PedalButton.track1:
      case PedalButton.track2:
      case PedalButton.track3:
      case PedalButton.track4:
        trackPressed(state.bankBaseChannel + _trackIndex(button));
    }
  }

  void _onClear() {
    // Light the Clear LED while the footswitch is held (cleared on release).
    _clearHeld = true;
    unawaited(clearAll());
  }

  /// Clear footswitch released: darken the Clear LED (the clear itself
  /// already happened on press — this only ends the held-button light).
  void _onClearRelease() {
    if (!_clearHeld) return;
    _clearHeld = false;
    _pushProjected();
  }

  void _armUndo() {
    final channel = state.cursor; // latched at press by both closures
    _undoGesture.press(
      threshold: _longPress,
      onHold: () {
        _log('redo ch=$channel  (long-press)');
        redo(channel);
      },
      onTap: () {
        _log('undo ch=$channel  (tap)');
        undo(channel);
      },
    );
  }

  /// The FX-mode Stop gesture: the PANIC fires on the press itself, and a
  /// hold past the threshold follows it with the restore.
  ///
  /// Panic-on-press, not on release, for two reasons. A panic is an emergency
  /// control — a performer stomping it wants the chains out now, not when
  /// their foot comes up. And a release is not proof of a gesture: the
  /// on-screen plate injects a synthetic note-off for every held switch when
  /// it leaves the tree (so it never strands a note), which as a
  /// release-triggered action would have bypassed and PERSISTED every chain
  /// for a stomp the user never finished. Acting on the press makes the
  /// release inert, so a synthetic one can do no harm.
  ///
  /// The hold therefore reads as panic-then-restore, which lands on the same
  /// end state the restore promises on its own: every chain on.
  void _armStop() {
    _log('fx panic (press)');
    panicTrackChains();
    _armStopRestore();
  }

  /// Arms the Stop restore-all hold on its own, without the panic.
  ///
  /// Split out because a BOUND Stop runs its binding on the press instead of
  /// the panic, but still owes the performer the restore gesture (B12): the
  /// remap overrides the contextual default, never the long-press system
  /// gesture layered above it.
  void _armStopRestore() {
    // No `onTap`: whatever fired on the press already did, so the release is
    // inert.
    _stopGesture.press(
      threshold: _longPress,
      onHold: () {
        // Only while the foot is still in the mode it committed to: cycling
        // MODE mid-hold leaves the pedal showing cursor/armed LEDs, where a
        // silent rewrite of every chain would be invisible.
        if (state.mode != InteractionMode.fx) return;
        _log('fx chains restored (long-press)');
        restoreAllTrackChains();
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Performance recording (D-PEDAL)
  // ---------------------------------------------------------------------------

  /// Arms or disarms performance recording, mirroring the toolbar's own
  /// dispatch (`PerformanceRecorderCubit.toggleArm` calls the same
  /// repository methods, including the guarded `disarm()` — not
  /// `disarmAndFinalize()`, which is reserved for `SessionCubit`'s
  /// unguarded auto-disarm-before-load) — the repository's own double-press
  /// guard covers a rapid re-press identically here, so it is not
  /// duplicated in this cubit.
  void togglePerformanceRecord() {
    if (_performanceArmed) {
      unawaited(_performance.disarm());
    } else {
      unawaited(_performance.arm(chains: _currentChains()));
    }
  }

  void _onPerformanceStatus(PerformanceCaptureStatus status) {
    final armed = status == PerformanceCaptureStatus.armed;
    if (armed == _performanceArmed) return;
    _performanceArmed = armed;
    _pushProjected();
  }

  void _armMode() {
    _modeGesture.press(
      threshold: _longPress,
      onHold: () {
        _log('performance record toggled (long-press)');
        togglePerformanceRecord();
      },
      onTap: () {
        _log('mode toggled (tap)');
        toggleMode();
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Pedal remap (part 6b): bindings, momentary hold, release-all
  // ---------------------------------------------------------------------------

  // The remap is READ off `state` (`state.bindings` / `.globalBindings` /
  // `.sessionBindings` / `.stompFor`) — the cubit exposes only the writers
  // below. No pass-through getters: a cubit's public surface is its commands,
  // and the state object is already the read surface every widget watches.

  /// Replaces the global remap and persists it (the assignment screen's edit
  /// path).
  ///
  /// Releases every held momentary FIRST: the binding the foot is holding may
  /// not survive the edit, and a target left enabled with no binding to
  /// release it is exactly the wedge (B1) the release-all rule exists to
  /// prevent.
  Future<void> setGlobalBindings(PedalBindingSet next) async {
    if (next == state.globalBindings) return;
    releaseAllMomentary();
    emit(state.copyWith(globalBindings: next));
    await _settings.savePedalBindings(next.encode());
  }

  /// Applies the remap carried by a loaded session (or clears it when the
  /// bundle has none). Called from the session apply seam; releases held
  /// momentaries on the same rule as [setGlobalBindings].
  void applySessionBindings(PedalBindingSet next) {
    if (next == state.sessionBindings) return;
    releaseAllMomentary();
    emit(state.copyWith(sessionBindings: next));
  }

  /// Restores every held momentary to the state its press captured — the ONE
  /// enforcement point (B1).
  ///
  /// Every path that can strand a press without its release funnels here:
  /// mode exit ([setMode]), a binding-set change ([setGlobalBindings] /
  /// [applySessionBindings], which covers the assignment screen's live edits
  /// AND a session load), and pedal disconnect ([_onBindStatus]). A physical
  /// release goes through [_releaseBinding] instead, which restores just that
  /// one — but both write the captured state, so no target can be left
  /// enabled by a press whose release never arrived.
  void releaseAllMomentary() {
    if (_heldRestore.isEmpty) return;
    for (final held in _heldRestore.values) {
      _looper.setBindingEnabled(held.target, enabled: held.prior);
    }
    _log('released ${_heldRestore.length} held momentary binding(s)');
    _heldRestore.clear();
    emit(state.copyWith(heldMomentary: const <PedalBindingKey>{}));
  }

  /// Runs [binding] instead of its button's contextual FX-mode default.
  ///
  /// A stale binding — one whose target string no longer parses, or names a
  /// chain/slot the rig no longer has — is a NO-OP (R25). It writes nothing
  /// and lights nothing; the assignment screen is where the user learns it is
  /// broken, not a mid-song stomp that silently bypasses the wrong thing.
  void _pressBinding(PedalBinding binding) {
    final target = binding.decodeTarget();
    final prior = target == null ? null : _looper.bindingEnabled(target);
    if (target == null || prior == null) {
      _log('binding on ${binding.key.button.name} is stale — no-op');
      return;
    }
    switch (binding.behavior) {
      case BindingBehavior.toggle:
        _log('binding toggle ${binding.key.button.name} -> ${!prior}');
        _looper.setBindingEnabled(target, enabled: !prior);
      case BindingBehavior.momentary:
        _log('binding momentary ${binding.key.button.name} (was $prior)');
        // Capture on the FIRST press only. A repeated press with no release
        // between them — a dropped NoteOff, or the on-screen plate re-emitting
        // a down — would otherwise re-capture the state THIS binding just
        // enabled, and the eventual release would restore `true` and strand
        // the target on: the stuck momentary (B1) with no foot on the switch.
        _heldRestore.putIfAbsent(
          binding.key,
          () => (target: target, prior: prior),
        );
        _looper.setBindingEnabled(target, enabled: true);
        emit(
          state.copyWith(heldMomentary: {...state.heldMomentary, binding.key}),
        );
    }
    _pushProjected();
  }

  /// Restores the momentary [button] is holding, if any.
  ///
  /// Matched by BUTTON rather than by the live bank's key: the performer can
  /// stomp Bank while a track momentary is down, and the release must still
  /// find the binding that was actually pressed. A button holds at most one
  /// momentary at a time, so the match is unambiguous.
  void _releaseBinding(PedalButton button) {
    for (final key in _heldRestore.keys) {
      if (key.button != button) continue;
      final held = _heldRestore.remove(key)!;
      _log('binding momentary ${button.name} released -> ${held.prior}');
      _looper.setBindingEnabled(held.target, enabled: held.prior);
      emit(
        state.copyWith(heldMomentary: {...state.heldMomentary}..remove(key)),
      );
      return;
    }
  }

  // ---------------------------------------------------------------------------
  // External MIDI control (part 7): mappings, learn, dispatch, release-all
  // ---------------------------------------------------------------------------

  /// Replaces the external-MIDI mapping set, applies it to the repository, and
  /// persists it to the GLOBAL `controller.mappings` blob (R19 — no session
  /// carries a copy).
  ///
  /// Releases every held MIDI momentary FIRST, on the same rule the pedal remap
  /// obeys: the binding a foot is holding may not survive the edit, and a
  /// target left enabled with nothing able to release it is exactly the wedge
  /// (B1) the release-all rule exists to prevent.
  Future<void> setControllerBindings(ControllerBindingSet next) async {
    if (next == state.controllerBindings) return;
    // A capture relearning a row this edit removes has nothing left to render
    // it: its row is gone, and the add-row only shows a capture that is not
    // relearning anything. Ending it here is what keeps the repository from
    // swallowing every controller event behind a UI that shows nothing.
    // Before the emit below, since cancelling emits on its own.
    final learn = state.controllerLearn;
    final relearning = learn?.replacingKey;
    if (relearning != null &&
        !next.bindings.any((binding) => binding.key == relearning)) {
      _log('midi learn cancelled: the row it was relearning was removed');
      cancelControllerLearn();
    }
    _releaseControllerMomentariesMissingFrom(next);
    _controller?.setBindings(next);
    _cacheControllerTargets(next);
    emit(state.copyWith(controllerBindings: next));
    _scheduleMappingsWrite(next.encode());
  }

  /// Releases the held momentaries [next] no longer carries — the edit half of
  /// the release-all rule (B1).
  ///
  /// Scoped to the holds the edit actually strands: a control whose mapping is
  /// gone, whose target moved, or which is no longer momentary at all. A
  /// mapping that survived the edit keeps its hold, because an unrelated row's
  /// range says nothing about the switch under someone's foot — and a LO/HI
  /// drag runs this once per pointer frame, so releasing everything here would
  /// drop a held chain mid-song the moment any knob moved.
  void _releaseControllerMomentariesMissingFrom(ControllerBindingSet next) {
    if (_heldControllerRestore.isEmpty) return;
    final live = <(MappingTrigger, String)>{
      for (final binding in next.bindings)
        if (binding is DiscreteBinding &&
            binding.behavior == BindingBehavior.momentary)
          binding.key,
    };
    var released = 0;
    for (final entry in _heldControllerRestore.entries.toList()) {
      entry.value.holders.removeWhere(
        (trigger) => !live.contains((trigger, entry.key)),
      );
      if (entry.value.holders.isNotEmpty) continue;
      _heldControllerRestore.remove(entry.key);
      _looper.setBindingEnabled(entry.value.target, enabled: entry.value.prior);
      released++;
    }
    if (released == 0) return;
    _log('released $released held MIDI momentary(s) the edit stranded');
    _pushProjected();
  }

  /// Decodes every binding's target once, for the dispatch path to look up.
  void _cacheControllerTargets(ControllerBindingSet bindings) {
    _controllerValueTargets.clear();
    _controllerSwitchTargets.clear();
    for (final binding in bindings.bindings) {
      switch (binding) {
        case ContinuousBinding():
          final target = ControlValueTarget.tryParse(binding.target);
          if (target != null) _controllerValueTargets[binding.target] = target;
        case DiscreteBinding():
          final target = FxBindingTarget.tryParse(binding.target);
          if (target != null) _controllerSwitchTargets[binding.target] = target;
      }
    }
  }

  /// Coalesces the settings write for [blob] (see [_mappingsWriteTimer]).
  ///
  /// A zero debounce writes straight through and arms no timer at all — what
  /// tests pass so a pumped frame does not have to outlive a pending write.
  void _scheduleMappingsWrite(String blob) {
    _pendingMappingsBlob = blob;
    _mappingsWriteTimer?.cancel();
    if (_mappingsWriteDebounce <= Duration.zero) {
      _flushMappingsWrite();
      return;
    }
    _mappingsWriteTimer = Timer(_mappingsWriteDebounce, _flushMappingsWrite);
  }

  void _flushMappingsWrite() {
    _mappingsWriteTimer?.cancel();
    _mappingsWriteTimer = null;
    final blob = _pendingMappingsBlob;
    if (blob == null) return;
    _pendingMappingsBlob = null;
    unawaited(_settings.saveControllerMappings(blob));
  }

  /// Replaces one mapping in place (an edited range, threshold, behavior or
  /// target), preserving its row position.
  Future<void> updateControllerBinding(
    ControllerBinding binding,
    ControllerBinding next,
  ) => setControllerBindings(state.controllerBindings.replace(binding, next));

  /// Removes one mapping.
  Future<void> removeControllerBinding(ControllerBinding binding) =>
      setControllerBindings(state.controllerBindings.without(binding));

  /// Starts a MIDI-learn capture for [target].
  ///
  /// [continuous] picks the trigger shape a NEW mapping takes; when
  /// [replacing] is given the shape and ranges of that mapping are carried
  /// over instead, so relearning which control drives a parameter never resets
  /// the travel the user dialed in.
  ///
  /// The capture ends in one of four ways: a control moves and binds; a control
  /// moves onto a CC that is already mapped, which parks the capture on
  /// [ControllerLearn.awaitingConfirm] until [confirmControllerLearn]; the user
  /// cancels; or the learn timeout elapses. The repository swallows ALL
  /// controller input while a capture is pending, which is why every one of
  /// those paths ends it.
  void learnControllerBinding({
    required String target,
    bool continuous = true,
    ControllerBinding? replacing,
  }) {
    final controller = _controller;
    if (controller == null) return;
    // A pending capture SWALLOWS every controller input, the release edge of a
    // held momentary included — so a foot still on a switch when a learn starts
    // would never be released, and the target would stay enabled with nothing
    // able to turn it off. Release first: the same B1 rule every other
    // stranding path obeys.
    releaseAllControllerMomentary();
    _learnTimer?.cancel();
    _learnTimer = Timer(_learnTimeout, cancelControllerLearn);
    emit(
      state.copyWith(
        controllerLearn: ControllerLearn(
          target: target,
          // A relearn keeps the shape it already has; only a NEW mapping is
          // free to take the caller's.
          continuous: switch (replacing) {
            ContinuousBinding() => true,
            DiscreteBinding() => false,
            null => continuous,
          },
          replacingKey: replacing?.key,
        ),
      ),
    );
    final generation = ++_learnGeneration;
    unawaited(
      controller.learnNext().then(
        (input) => _onLearnCaptured(generation, input),
      ),
    );
  }

  /// Confirms replacing the existing mapping(s) on the captured control (R28).
  /// A no-op unless a capture is parked on the confirmation.
  Future<void> confirmControllerLearn() async {
    final learn = state.controllerLearn;
    final captured = learn?.captured;
    if (learn == null || captured == null) return;
    await _applyLearn(learn, captured, replaceExisting: true);
  }

  /// Ends a capture without binding anything — the row's cancel action, the
  /// timeout, and the "keep what I had" half of the replace confirmation.
  void cancelControllerLearn() {
    _learnTimer?.cancel();
    _learnTimer = null;
    // Retire the capture BEFORE cancelling it, so the null completion this
    // triggers cannot act on whatever comes next.
    _learnGeneration++;
    _controller?.cancelLearn();
    if (isClosed || state.controllerLearn == null) return;
    emit(state.copyWith(clearControllerLearn: true));
  }

  /// The mapping [key] names in the LIVE set, or `null` when the row it
  /// pointed at has since been removed.
  ControllerBinding? _liveBinding((MappingTrigger, String)? key) {
    if (key == null) return null;
    return state.controllerBindings.bindings
        .where((binding) => binding.key == key)
        .firstOrNull;
  }

  void _onLearnCaptured(int generation, RawControllerInput? input) {
    // A superseded or cancelled capture completes with null too, and its
    // callback must not touch the capture that replaced it — nor cancel the
    // timeout that is the only thing rescuing a capture nobody feeds.
    if (isClosed || generation != _learnGeneration) return;
    final learn = state.controllerLearn;
    if (learn == null) return;
    _learnTimer?.cancel();
    _learnTimer = null;
    if (input == null) {
      emit(state.copyWith(clearControllerLearn: true));
      return;
    }
    // The CHANNEL-scoped identity: the same CC number on two channels is two
    // controls, so the capture records which one it heard (B8).
    final trigger = input.channelTrigger;
    // Exempt the row being relearned as it stands NOW: against a stale value,
    // re-teaching a row the control it already has would read as a conflict
    // with itself.
    if (state.controllerBindings.isTriggerBound(
      trigger,
      except: _liveBinding(learn.replacingKey),
    )) {
      _log('midi learn caught an already-mapped control: $trigger');
      emit(state.copyWith(controllerLearn: learn.withCaptured(trigger)));
      return;
    }
    unawaited(_applyLearn(learn, trigger, replaceExisting: false));
  }

  Future<void> _applyLearn(
    ControllerLearn learn,
    MappingTrigger trigger, {
    required bool replaceExisting,
  }) async {
    // Resolve the row being relearned from the LIVE set: its knobs and its
    // Remove button stay usable while a capture listens, so it may have been
    // edited or deleted outright since the capture started. Rebuilding from
    // what is there now is what keeps a relearn from resurrecting a removed
    // mapping — `replace` would silently fall back to adding one — or from
    // writing back the ranges the user just dialed away.
    final replacing = _liveBinding(learn.replacingKey);
    if (learn.replacingKey != null && replacing == null) {
      _log('midi learn dropped: the row it was relearning is gone');
      emit(state.copyWith(clearControllerLearn: true));
      return;
    }
    final next = switch (replacing) {
      ContinuousBinding(:final lo, :final hi) => ContinuousBinding(
        trigger: trigger,
        target: learn.target,
        lo: lo,
        hi: hi,
      ),
      DiscreteBinding(:final threshold, :final behavior) => DiscreteBinding(
        trigger: trigger,
        target: learn.target,
        threshold: threshold,
        behavior: behavior,
      ),
      null =>
        learn.continuous
            ? ContinuousBinding(trigger: trigger, target: learn.target)
            : DiscreteBinding(trigger: trigger, target: learn.target),
    };
    var bindings = state.controllerBindings;
    if (replaceExisting) {
      bindings = bindings.withoutTrigger(trigger, except: replacing);
    }
    bindings = replacing == null
        ? bindings.withBinding(next)
        : bindings.replace(replacing, next);
    _log('midi learn bound $trigger -> ${learn.target}');
    emit(state.copyWith(clearControllerLearn: true));
    await setControllerBindings(bindings);
  }

  /// Applies one resolved external-MIDI binding event.
  ///
  /// The SAME enforcement point the pedal's own bindings pass through (VGV):
  /// no second control-surface interpreter grows inside a repository package,
  /// so a discrete CC means here exactly what a footswitch binding means.
  ///
  /// Unlike a pedal binding, external control is NOT gated on FX mode: a
  /// mapping the user made explicitly, on hardware whose only job is that
  /// mapping, has no contextual default it could be shadowing.
  void _onControllerBindingEvent(ControllerBindingEvent event) {
    switch (event) {
      case ControllerValueEvent(:final target, :final value):
        _applyControllerValue(target, value);
      case ControllerSwitchEvent(
        :final target,
        :final trigger,
        :final behavior,
        :final pressed,
      ):
        _applyControllerSwitch(target, trigger, behavior, pressed: pressed);
    }
  }

  /// Writes a continuous binding's value. Last-writer-wins against the
  /// on-screen controls and against any other mapping on the same target — the
  /// CC simply writes, exactly as a knob drag does.
  void _applyControllerValue(String target, double value) {
    final decoded = _controllerValueTargets[target];
    if (decoded == null) return; // undecodable string: inert, never a guess
    if (!_looper.writeValueTarget(decoded, value)) return;
    if (decoded is MasterGainTarget) {
      // Keep the accumulator the encoder and the pedal's ring meter read in
      // step with what MIDI just wrote, or the next detent turn would jump
      // back to the value the encoder last set.
      _masterGain = value.clamp(0.0, 1.0);
      _pushProjected();
    }
  }

  void _applyControllerSwitch(
    String target,
    MappingTrigger trigger,
    BindingBehavior behavior, {
    required bool pressed,
  }) {
    final decoded = _controllerSwitchTargets[target];
    final prior = decoded == null ? null : _looper.bindingEnabled(decoded);
    if (decoded == null || prior == null) {
      // Stale mapping: a no-op, like a stale pedal binding (R25). Its row is
      // where the user learns it is broken, not a mid-song stomp.
      // A target that went stale WHILE held still has to be put back: the
      // capture is the only record of what it was before the press.
      final captured = _heldControllerRestore.remove(target);
      if (captured == null) return;
      _looper.setBindingEnabled(captured.target, enabled: captured.prior);
      _pushProjected();
      return;
    }
    switch (behavior) {
      case BindingBehavior.toggle:
        // Latching: only the ON edge acts, so the control's release does not
        // undo the stomp it just made.
        if (!pressed) return;
        _log('midi toggle -> ${!prior}');
        _looper.setBindingEnabled(decoded, enabled: !prior);
      case BindingBehavior.momentary:
        final entry = _heldControllerRestore[target];
        if (pressed) {
          // Capture on the FIRST hold only — a repeated ON edge with no release
          // between them, or a second control joining the hold, must not
          // re-capture the state the hold itself enabled.
          if (entry == null) {
            _heldControllerRestore[target] = (
              target: decoded,
              prior: prior,
              holders: {trigger},
            );
          } else {
            entry.holders.add(trigger);
          }
          _looper.setBindingEnabled(decoded, enabled: true);
        } else {
          if (entry == null) return;
          entry.holders.remove(trigger);
          // Another control is still holding this target down.
          if (entry.holders.isNotEmpty) return;
          _heldControllerRestore.remove(target);
          _log('midi momentary released -> ${entry.prior}');
          _looper.setBindingEnabled(entry.target, enabled: entry.prior);
        }
    }
    _pushProjected();
  }

  /// Restores every MIDI-held momentary to the state its press captured — the
  /// external-control half of the ONE release-all rule (B1).
  ///
  /// Reached from MIDI-source disconnect ([_onMidiConnection]) and from the
  /// start of a learn capture, which swallows the release edge. A mapping EDIT
  /// releases only what it strands — see
  /// [_releaseControllerMomentariesMissingFrom].
  ///
  /// A held momentary whose device unplugs will never see its OFF edge, so
  /// without this the target would stay enabled with no control able to
  /// release it. CONTINUOUS bindings are deliberately
  /// the opposite: an unplug mid-song leaves the value exactly where the last
  /// sweep put it, because snapping a filter back to a stored value the moment
  /// a cable wobbles is the louder failure.
  void releaseAllControllerMomentary() {
    if (_heldControllerRestore.isEmpty) return;
    for (final held in _heldControllerRestore.values) {
      _looper.setBindingEnabled(held.target, enabled: held.prior);
    }
    _log('released ${_heldControllerRestore.length} held MIDI momentary(s)');
    _heldControllerRestore.clear();
    _pushProjected();
  }

  void _onMidiConnection(MidiConnection connection) {
    if (connection.status == MidiConnectionStatus.connected) return;
    releaseAllControllerMomentary();
  }

  int _trackIndex(PedalButton button) => switch (button) {
    PedalButton.track1 => 0,
    PedalButton.track2 => 1,
    PedalButton.track3 => 2,
    PedalButton.track4 => 3,
    _ => throw ArgumentError('not a track button: $button'),
  };

  // ---------------------------------------------------------------------------
  // Outbound frame projection (via PedalRepository)
  // ---------------------------------------------------------------------------

  void _onLooperState(LooperState looperState) {
    _looperState = looperState;
    _reduce(looperState);
    _detectLoopTop(looperState);
    _pushProjected();
  }

  void _onBindStatus(PedalBindStatus status) {
    // A fresh bind has no last frame on the pedal — force the next push (it
    // reads the CURRENT state, so a mode/cursor changed while unplugged
    // shows correctly on replug).
    if (status == PedalBindStatus.bound) {
      _lastFrame = null;
      _pushProjected();
      return;
    }
    // Unplugged mid-hold: the release note-off is never coming, so a held
    // momentary would leave its target enabled forever (B1). Restore now.
    releaseAllMomentary();
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

  /// Projects and pushes the current LED frame. Diffs against the last push so
  /// steady state is silent; [force] re-sends unchanged (the keep-alive uses it
  /// so the pedal's link watchdog keeps seeing frames while idle).
  void _pushProjected({bool force = false}) {
    // Project from `_l` — the last streamed state, or the repository's current
    // snapshot when no LooperState has streamed in yet. Reading `_l` (not the
    // raw `_looperState`) lets the keep-alive light the pedal on bind even
    // before the first stream event: an idle engine emits no LooperState, so
    // gating on a null `_looperState` left the LEDs dark until some audio
    // activity happened to push a state.
    final looperState = _l;
    final frame = projectFrame(
      looperState,
      state,
      clearFadeActive: _clearHeld,
      performanceArmed: _performanceArmed,
      masterGain: _masterGain,
    );
    if (!force && frame == _lastFrame) return; // diff: only push on change
    _lastFrame = frame;
    _pedal.pushState(frame);
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
    final armed = armedTracks(_l, state);
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

  int get _channelCount => ControlState.tracksPerBank * ControlState.bankCount;

  void _log(String message) {
    dev.log(message, name: 'control');
    // Skip high-frequency encoder deltas — they would flood the rotating log.
    if (!message.startsWith('encoder ')) {
      AppLog.info('control: $message');
    }
  }

  @override
  void emit(ControlState state) {
    super.emit(state);
    // Every stored-intent change re-projects the pedal frame (the diff in
    // [_pushProjected] keeps the wire quiet when the LEDs are unaffected).
    // After super.emit — onChange fires BEFORE the state field updates, and
    // a projection of the outgoing state trips the invariant assert.
    _pushProjected();
  }

  @override
  Future<void> close() async {
    _keepAliveTimer?.cancel();
    _learnTimer?.cancel();
    // A capture outlives this cubit otherwise: the controller repository is
    // app-scoped, and while it is learning it swallows EVERY input — including
    // the transport events another bloc consumes — with the timeout that would
    // have rescued it already cancelled above.
    _controller?.cancelLearn();
    // Commit whatever the debounce was still holding, so a quit mid-edit does
    // not lose the mapping the user just made.
    _flushMappingsWrite();
    _undoGesture.cancel();
    _modeGesture.cancel();
    _stopGesture.cancel();
    await _looperSub.cancel();
    await _eventsSub.cancel();
    await _statusSub.cancel();
    await _perfStatusSub.cancel();
    await _bindingSub?.cancel();
    await _midiSub?.cancel();
    return super.close();
  }
}
