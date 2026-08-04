import 'dart:async';

import 'package:controller_repository/src/controller_binding.dart';
import 'package:controller_repository/src/controller_binding_event.dart';
import 'package:controller_repository/src/controller_binding_set.dart';
import 'package:controller_repository/src/controller_event.dart';
import 'package:controller_repository/src/controller_input.dart';
import 'package:controller_repository/src/controller_mapping.dart';
import 'package:controller_repository/src/controller_source.dart';
import 'package:controller_repository/src/looper_action.dart';

/// Combines one or more [ControllerSource]s, applies the active mapping and
/// binding set, and emits hardware-agnostic [ControllerEvent]s and
/// [ControllerBindingEvent]s. Also drives MIDI-learn capture.
///
/// This is the single controller-truth boundary: the bloc layer subscribes to
/// [events] / [bindingEvents] and never touches MIDI clients directly.
///
/// ## Two trigger shapes (A10)
///
/// Raw CC VALUES flow through here — the pre-part-7 repository dropped
/// everything that was not a press. A [ContinuousBinding] maps `0..127` onto
/// its LO/HI range and rides the smoothing ramp below; a [DiscreteBinding]
/// emits on/off edges at its threshold, in the same behavior vocabulary a
/// footswitch binding uses. Targets stay opaque strings throughout (VGV): this
/// package gains no looper/engine dependency, and the app decodes them at its
/// one dispatch point.
///
/// ## Smoothing and takeover (B9)
///
/// A 7-bit CC step is an audible jump on a filter cutoff, so a binding's FIRST
/// move jumps straight to its mapped value (jump-on-first-move takeover — no
/// pickup/catch in v1) and every move after it RAMPS from the value that
/// binding last emitted, over [smoothing], in [smoothingTick] steps. The ticker
/// runs only while a ramp is in flight and is cancelled by [dispose], so a
/// disposed repository leaves no pending timer.
class ControllerRepository {
  /// Creates a [ControllerRepository] over [sources], with an optional initial
  /// action [mapping] (defaults to [ControllerMapping.defaults]) and
  /// [bindings].
  ///
  /// [learnIgnore] filters MIDI-learn capture: an input it accepts is ignored
  /// while learning, as if it had never arrived. The app passes the Segno
  /// pedal's own protocol traffic (B8), so learning with the pedal connected
  /// captures the controller the user is actually moving rather than pedal
  /// chatter. Dispatch is unaffected — the filter is about what a capture may
  /// CATCH.
  ///
  /// [smoothing] is how long a ramp takes to reach a new value and
  /// [smoothingTick] the interval it advances on; both are injected so tests
  /// drive them under a fake clock instead of sleeping.
  ControllerRepository({
    required List<ControllerSource> sources,
    ControllerMapping? mapping,
    ControllerBindingSet bindings = ControllerBindingSet.empty,
    bool Function(RawControllerInput input)? learnIgnore,
    this.smoothing = const Duration(milliseconds: 60),
    this.smoothingTick = const Duration(milliseconds: 10),
  }) : _sources = sources,
       _mapping = mapping ?? ControllerMapping.defaults(),
       _bindings = bindings,
       _learnIgnore = learnIgnore {
    for (final source in sources) {
      _subscriptions.add(source.inputs.listen(_onInput));
    }
  }

  final List<ControllerSource> _sources;
  final List<StreamSubscription<RawControllerInput>> _subscriptions = [];
  final StreamController<ControllerEvent> _events =
      StreamController<ControllerEvent>.broadcast();
  final StreamController<ControllerMapping> _mappings =
      StreamController<ControllerMapping>.broadcast();
  final StreamController<ControllerBindingEvent> _bindingEvents =
      StreamController<ControllerBindingEvent>.broadcast();
  final bool Function(RawControllerInput input)? _learnIgnore;

  /// How long a continuous binding takes to ramp to a newly received value.
  final Duration smoothing;

  /// How often a ramp in flight advances.
  final Duration smoothingTick;

  ControllerMapping _mapping;
  ControllerBindingSet _bindings;
  Completer<RawControllerInput?>? _learnCompleter;

  /// The value each continuous binding last EMITTED, keyed by binding. Absent
  /// until that binding's first move — which is what makes the first move a
  /// jump rather than a ramp from an assumed starting point (B9).
  final Map<(MappingTrigger, String), double> _values = {};

  /// The ramps currently in flight, keyed by binding.
  final Map<(MappingTrigger, String), _Ramp> _ramps = {};

  /// The on/off reading each discrete binding last emitted, keyed by binding.
  /// Absent means off — a mapping that has never fired.
  final Map<(MappingTrigger, String), bool> _switches = {};

  Timer? _rampTimer;

  /// Resolved controller events (after the action mapping). Suppressed while
  /// learning.
  Stream<ControllerEvent> get events => _events.stream;

  /// Resolved binding events — continuous values and discrete edges.
  /// Suppressed while learning.
  Stream<ControllerBindingEvent> get bindingEvents => _bindingEvents.stream;

  /// Emits the action mapping whenever it changes (binding / replacement).
  Stream<ControllerMapping> get mappingChanges => _mappings.stream;

  /// The active action mapping.
  ControllerMapping get mapping => _mapping;

  /// The active binding set.
  ControllerBindingSet get bindings => _bindings;

  /// Whether a MIDI-learn capture is in progress.
  bool get isLearning => _learnCompleter != null;

  void _onInput(RawControllerInput input) {
    final learn = _learnCompleter;
    if (learn != null) {
      // The pedal's own protocol traffic can never be captured (B8): the pedal
      // and the controller being learned share one MIDI input stream, so a
      // stomp during a capture would otherwise bind a footswitch the app
      // already owns.
      if (_learnIgnore?.call(input) ?? false) return;
      // A CC is captured at ANY value: an expression pedal's rest position is
      // a real position, and refusing value 0 would make a heel-down sweep
      // uncapturable. A note still needs a press — notes arrive in press /
      // release pairs, and capturing the release would bind the wrong edge.
      if (input.kind == ControllerSourceKind.midiCc || input.isPress) {
        _learnCompleter = null;
        learn.complete(input);
      }
      return;
    }
    final event = _mapping.resolve(input);
    if (event != null) _events.add(event);
    _dispatchBindings(input);
  }

  /// Drives every binding this input matches — fan-out is deliberate (B8): one
  /// expression pedal can sweep several parameters at once.
  void _dispatchBindings(RawControllerInput input) {
    for (final binding in _bindings.matching(input)) {
      switch (binding) {
        case ContinuousBinding():
          _driveContinuous(binding, input.value);
        case DiscreteBinding():
          _driveDiscrete(binding, input.value);
      }
    }
  }

  void _driveContinuous(ContinuousBinding binding, int value) {
    final key = binding.key;
    final goal = binding.valueFor(value);
    final current = _values[key];
    if (current == null) {
      // Takeover: the first move jumps (B9). No pickup/catch in v1 — the
      // parameter goes wherever the control already is.
      _emitValue(key, binding.target, goal);
      return;
    }
    if (current == goal) {
      // A repeat of the value already in force: nothing to ramp toward. Drop
      // any ramp still heading elsewhere, so the control's own position wins.
      _ramps.remove(key);
      _stopRampTimerIfIdle();
      return;
    }
    _ramps[key] = _Ramp(
      target: binding.target,
      from: current,
      to: goal,
      steps: _rampSteps,
    );
    _rampTimer ??= Timer.periodic(smoothingTick, (_) => _advanceRamps());
  }

  void _driveDiscrete(DiscreteBinding binding, int value) {
    final key = binding.key;
    final previous = _switches[key] ?? false;
    final next = binding.isOn(value, previous: previous);
    if (next == previous) return; // no edge: no event (and no double-fire)
    _switches[key] = next;
    _bindingEvents.add(
      ControllerSwitchEvent(
        target: binding.target,
        trigger: binding.trigger,
        behavior: binding.behavior,
        pressed: next,
      ),
    );
  }

  /// How many ticks a ramp takes — at least one, so a smoothing window shorter
  /// than a tick still lands on the goal instead of stalling.
  int get _rampSteps {
    final steps = smoothingTick.inMicroseconds <= 0
        ? 1
        : (smoothing.inMicroseconds / smoothingTick.inMicroseconds).round();
    return steps < 1 ? 1 : steps;
  }

  void _advanceRamps() {
    for (final entry in _ramps.entries.toList()) {
      final ramp = entry.value;
      ramp.step++;
      final done = ramp.step >= ramp.steps;
      if (done) _ramps.remove(entry.key);
      _emitValue(entry.key, ramp.target, done ? ramp.to : ramp.valueNow);
    }
    _stopRampTimerIfIdle();
  }

  void _stopRampTimerIfIdle() {
    if (_ramps.isNotEmpty) return;
    _rampTimer?.cancel();
    _rampTimer = null;
  }

  void _emitValue((MappingTrigger, String) key, String target, double value) {
    _values[key] = value;
    if (!_bindingEvents.isClosed) {
      _bindingEvents.add(ControllerValueEvent(target: target, value: value));
    }
  }

  /// Captures the next input for MIDI-learn. Completes with the input, or
  /// `null` if superseded by another [learnNext] or [cancelLearn]. While a
  /// capture is pending, inputs produce neither [events] nor [bindingEvents].
  Future<RawControllerInput?> learnNext() {
    _learnCompleter?.complete(null);
    final completer = Completer<RawControllerInput?>();
    _learnCompleter = completer;
    return completer.future;
  }

  /// Cancels an in-progress [learnNext] capture.
  void cancelLearn() {
    _learnCompleter?.complete(null);
    _learnCompleter = null;
  }

  /// Binds [trigger] to [action] on [channel], replacing any existing entry.
  void bind(MappingTrigger trigger, LooperAction action, {int channel = 0}) {
    _mapping = _mapping.withBinding(trigger, action, channel: channel);
    _mappings.add(_mapping);
  }

  /// Replaces the entire action mapping.
  void setMapping(ControllerMapping mapping) {
    _mapping = mapping;
    _mappings.add(mapping);
  }

  /// Replaces the entire binding set (the app's persisted `controller.mappings`
  /// blob, applied at boot and on every edit).
  ///
  /// Per-binding runtime state — the smoothing ramps and the discrete on/off
  /// readings — is dropped for bindings the new set does not carry: an edited
  /// binding starts fresh, so its next move jumps (B9) rather than ramping from
  /// a value whose control has since moved. A momentary still HELD across an
  /// edit is released app-side, at `ControlCubit`'s one enforcement point (B1).
  void setBindings(ControllerBindingSet bindings) {
    _bindings = bindings;
    final live = {for (final binding in bindings.bindings) binding.key};
    _values.removeWhere((key, _) => !live.contains(key));
    _switches.removeWhere((key, _) => !live.contains(key));
    _ramps.removeWhere((key, _) => !live.contains(key));
    _stopRampTimerIfIdle();
  }

  /// Releases subscriptions, sources, timers, and streams.
  Future<void> dispose() async {
    cancelLearn();
    _rampTimer?.cancel();
    _rampTimer = null;
    _ramps.clear();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    for (final source in _sources) {
      await source.dispose();
    }
    await _events.close();
    await _mappings.close();
    await _bindingEvents.close();
  }
}

/// One continuous binding's in-flight ramp: a straight line from [from] to [to]
/// over [steps] ticks.
class _Ramp {
  _Ramp({
    required this.target,
    required this.from,
    required this.to,
    required this.steps,
  });

  final String target;
  final double from;
  final double to;
  final int steps;
  int step = 0;

  /// The value at the current [step] — linear, so the trajectory a test asserts
  /// is the one the ear expects: even motion between two CC positions.
  double get valueNow => from + (to - from) * (step / steps);
}
