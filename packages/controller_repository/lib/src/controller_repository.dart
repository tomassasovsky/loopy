import 'dart:async';

import 'package:controller_repository/src/controller_event.dart';
import 'package:controller_repository/src/controller_input.dart';
import 'package:controller_repository/src/controller_mapping.dart';
import 'package:controller_repository/src/controller_source.dart';
import 'package:controller_repository/src/looper_action.dart';

/// Combines one or more [ControllerSource]s, applies the active mapping, and
/// emits hardware-agnostic [ControllerEvent]s. Also drives MIDI-learn capture.
///
/// This is the single controller-truth boundary: the bloc subscribes to
/// [events] and never touches MIDI/GPIO clients directly.
class ControllerRepository {
  /// Creates a [ControllerRepository] over [sources], with an optional initial
  /// [mapping] (defaults to [ControllerMapping.defaults]).
  ControllerRepository({
    required List<ControllerSource> sources,
    ControllerMapping? mapping,
  }) : _sources = sources,
       _mapping = mapping ?? ControllerMapping.defaults() {
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

  ControllerMapping _mapping;
  Completer<RawControllerInput?>? _learnCompleter;

  /// Resolved controller events (after mapping). Suppressed while learning.
  Stream<ControllerEvent> get events => _events.stream;

  /// Emits the mapping whenever it changes (binding / replacement).
  Stream<ControllerMapping> get mappingChanges => _mappings.stream;

  /// The active mapping.
  ControllerMapping get mapping => _mapping;

  /// Whether a MIDI-learn capture is in progress.
  bool get isLearning => _learnCompleter != null;

  void _onInput(RawControllerInput input) {
    final learn = _learnCompleter;
    if (learn != null) {
      // While learning, the next press is captured and not emitted as an event.
      if (input.isPress) {
        _learnCompleter = null;
        learn.complete(input);
      }
      return;
    }
    final event = _mapping.resolve(input);
    if (event != null) _events.add(event);
  }

  /// Captures the next pressed input for MIDI-learn. Completes with the input,
  /// or `null` if superseded by another [learnNext] or [cancelLearn]. While a
  /// capture is pending, inputs do not produce [events].
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

  /// Replaces the entire mapping.
  void setMapping(ControllerMapping mapping) {
    _mapping = mapping;
    _mappings.add(mapping);
  }

  /// Releases subscriptions, sources, and streams.
  Future<void> dispose() async {
    cancelLearn();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    for (final source in _sources) {
      await source.dispose();
    }
    await _events.close();
    await _mappings.close();
  }
}
