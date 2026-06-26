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

  /// A built-in mapping for the Raspberry Pi floor console's footswitches,
  /// mirroring the [ControllerMapping.defaults] transport actions on channel 0
  /// but bound to GPIO pins (BCM offsets) instead of MIDI CCs. Seeded at
  /// construction on the Pi so the console has working footswitches on first
  /// boot with zero config.
  factory ControllerMapping.gpioDefaults() {
    const kind = ControllerSourceKind.gpio;
    return const ControllerMapping(
      name: 'GPIO defaults',
      entries: [
        MappingEntry(
          trigger: MappingTrigger(kind: kind, id: 17),
          action: LooperAction.recordOverdub,
        ),
        MappingEntry(
          trigger: MappingTrigger(kind: kind, id: 27),
          action: LooperAction.stop,
        ),
        MappingEntry(
          trigger: MappingTrigger(kind: kind, id: 22),
          action: LooperAction.undo,
        ),
        MappingEntry(
          trigger: MappingTrigger(kind: kind, id: 23),
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

  /// Returns a mapping combining this mapping's entries with [other]'s, with
  /// [other] winning on any shared trigger. The result keeps this mapping's
  /// [name] (not [other]'s), and assumes [other] has no internally duplicated
  /// triggers (its entries are appended verbatim).
  ///
  /// Used to seed both [ControllerMapping.defaults] (MIDI) and
  /// [ControllerMapping.gpioDefaults] (GPIO) on the console so footswitches and
  /// a laptop MIDI pedal coexist; the two never
  /// collide in practice since their triggers differ by [ControllerSourceKind].
  ControllerMapping merge(ControllerMapping other) {
    final overridden = {for (final entry in other.entries) entry.trigger};
    return ControllerMapping(
      name: name,
      entries: [
        for (final entry in entries)
          if (!overridden.contains(entry.trigger)) entry,
        ...other.entries,
      ],
    );
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
