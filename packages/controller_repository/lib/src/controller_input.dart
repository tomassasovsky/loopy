import 'package:equatable/equatable.dart';

/// The kind of hardware input that produced a [RawControllerInput].
enum ControllerSourceKind {
  /// A MIDI Note On/Off message.
  midiNote,

  /// A MIDI Control Change message.
  midiCc,
}

/// The value-agnostic identity of a control, used as a mapping key.
///
/// A footswitch is identified by its source kind and number (note/CC),
/// independent of the momentary value (velocity / CC value).
class MappingTrigger extends Equatable {
  /// Creates a [MappingTrigger].
  const MappingTrigger({required this.kind, required this.id});

  /// The source kind.
  final ControllerSourceKind kind;

  /// The control number: MIDI note or CC number.
  final int id;

  @override
  List<Object?> get props => [kind, id];

  @override
  String toString() => 'MappingTrigger(${kind.name}#$id)';
}

/// A single raw input from a controller source.
class RawControllerInput extends Equatable {
  /// Creates a [RawControllerInput].
  const RawControllerInput({
    required this.kind,
    required this.id,
    required this.value,
  });

  /// The source kind.
  final ControllerSourceKind kind;

  /// The control number: MIDI note or CC number.
  final int id;

  /// The momentary value: note velocity or CC value.
  final int value;

  /// The value-agnostic [MappingTrigger] identity of this input.
  MappingTrigger get trigger => MappingTrigger(kind: kind, id: id);

  /// Whether this input represents a press / active edge (`value > 0`).
  bool get isPress => value > 0;

  @override
  List<Object?> get props => [kind, id, value];

  @override
  String toString() => 'RawControllerInput(${kind.name}#$id = $value)';
}
