import 'package:controller_repository/src/controller_event.dart';
import 'package:controller_repository/src/controller_input.dart';
import 'package:controller_repository/src/looper_action.dart';
import 'package:equatable/equatable.dart';

/// Binds a controller [trigger] to a looper [action] on a [channel].
class MappingEntry extends Equatable {
  /// Creates a [MappingEntry].
  const MappingEntry({
    required this.trigger,
    required this.action,
    this.channel = 0,
  });

  /// The control that fires this entry.
  final MappingTrigger trigger;

  /// The action to perform.
  final LooperAction action;

  /// The target channel for channel-scoped actions.
  final int channel;

  @override
  List<Object?> get props => [trigger, action, channel];
}

/// An immutable set of [MappingEntry]s resolving raw inputs into events.
class ControllerMapping extends Equatable {
  /// Creates a [ControllerMapping] from [entries].
  const ControllerMapping({this.name = 'Default', this.entries = const []});

  /// A built-in mapping for a single-pedal MIDI foot controller sending CCs,
  /// covering the core transport actions on channel 0.
  factory ControllerMapping.defaults() {
    const kind = ControllerSourceKind.midiCc;
    return const ControllerMapping(
      entries: [
        MappingEntry(
          trigger: MappingTrigger(kind: kind, id: 80),
          action: LooperAction.recordOverdub,
        ),
        MappingEntry(
          trigger: MappingTrigger(kind: kind, id: 81),
          action: LooperAction.stop,
        ),
        MappingEntry(
          trigger: MappingTrigger(kind: kind, id: 82),
          action: LooperAction.undo,
        ),
        MappingEntry(
          trigger: MappingTrigger(kind: kind, id: 83),
          action: LooperAction.clear,
        ),
      ],
    );
  }

  /// A human-readable mapping name.
  final String name;

  /// The mapping entries.
  final List<MappingEntry> entries;

  /// Resolves [input] into a [ControllerEvent], or `null` when the input is not
  /// a press or has no mapping entry.
  ControllerEvent? resolve(RawControllerInput input) {
    if (!input.isPress) return null;
    for (final entry in entries) {
      if (entry.trigger == input.trigger) {
        return ControllerEvent(action: entry.action, channel: entry.channel);
      }
    }
    return null;
  }

  /// Returns a copy with the entry for [trigger] replaced (or added) so it maps
  /// to [action] on [channel]. Used by MIDI-learn.
  ControllerMapping withBinding(
    MappingTrigger trigger,
    LooperAction action, {
    int channel = 0,
  }) {
    final next = [
      for (final entry in entries)
        if (entry.trigger != trigger) entry,
      MappingEntry(trigger: trigger, action: action, channel: channel),
    ];
    return ControllerMapping(name: name, entries: next);
  }

  @override
  List<Object?> get props => [name, entries];
}
