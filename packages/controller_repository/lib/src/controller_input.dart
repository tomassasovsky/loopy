import 'package:equatable/equatable.dart';

/// The kind of hardware input that produced a [RawControllerInput].
enum ControllerSourceKind {
  /// A MIDI Note On/Off message.
  midiNote,

  /// A MIDI Control Change message.
  midiCc;

  /// Maps a persisted [name] back to a kind, or `null` when it names none.
  static ControllerSourceKind? fromName(String? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// The value-agnostic identity of a control, used as a mapping key.
///
/// A footswitch is identified by its source kind and number (note/CC),
/// independent of the momentary value (velocity / CC value).
///
/// [midiChannel] narrows that identity to one MIDI channel. `null` is OMNI —
/// the control matches on every channel, which is what the built-in action
/// mappings use and what every capture that predates channel-scoping recorded.
/// A MIDI-learn capture for a controller binding records the channel it saw, so
/// the same CC number arriving from two devices on two channels stays two
/// distinct controls.
class MappingTrigger extends Equatable {
  /// Creates a [MappingTrigger].
  const MappingTrigger({
    required this.kind,
    required this.id,
    this.midiChannel,
  });

  /// Rebuilds a trigger from its [toJson] map, or `null` when the map does not
  /// describe one (unknown kind, missing/out-of-range control number, or an
  /// out-of-range channel).
  static MappingTrigger? fromJson(Map<String, dynamic> json) {
    final kind = ControllerSourceKind.fromName(json['kind'] as String?);
    if (kind == null) return null;
    final rawId = json['id'];
    if (rawId is! num) return null;
    final id = rawId.toInt();
    if (id < 0 || id > 127) return null;
    final rawChannel = json['channel'];
    if (rawChannel != null && rawChannel is! num) return null;
    final channel = (rawChannel as num?)?.toInt();
    // An out-of-range channel is corruption, not omni: silently widening a
    // channel-scoped binding would fire it on traffic the user never bound.
    if (channel != null && (channel < 0 || channel > 15)) return null;
    return MappingTrigger(kind: kind, id: id, midiChannel: channel);
  }

  /// The source kind.
  final ControllerSourceKind kind;

  /// The control number: MIDI note or CC number.
  final int id;

  /// The MIDI channel this trigger is scoped to, or `null` for omni.
  final int? midiChannel;

  /// Whether [input] is this control — same kind and number, and (unless this
  /// trigger is omni) the same MIDI channel.
  bool matches(RawControllerInput input) =>
      kind == input.kind &&
      id == input.id &&
      (midiChannel == null || midiChannel == input.midiChannel);

  /// Serializes this trigger to a JSON map with a fixed key order; the channel
  /// is omitted when omni, never written as null.
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'id': id,
    if (midiChannel != null) 'channel': midiChannel,
  };

  @override
  List<Object?> get props => [kind, id, midiChannel];

  @override
  String toString() =>
      'MappingTrigger(${kind.name}#$id'
      '${midiChannel == null ? '' : '@$midiChannel'})';
}

/// A single raw input from a controller source.
class RawControllerInput extends Equatable {
  /// Creates a [RawControllerInput].
  const RawControllerInput({
    required this.kind,
    required this.id,
    required this.value,
    this.midiChannel = 0,
  });

  /// The source kind.
  final ControllerSourceKind kind;

  /// The control number: MIDI note or CC number.
  final int id;

  /// The momentary value: note velocity or CC value.
  final int value;

  /// The MIDI channel this message arrived on (`0..15`).
  final int midiChannel;

  /// The OMNI [MappingTrigger] identity of this input — channel-agnostic.
  ///
  /// What the built-in action mappings key on: a transport footswitch has to
  /// work whatever channel the controller is set to, and every action mapping
  /// learned before channel-scoping existed was stored this way.
  MappingTrigger get trigger => MappingTrigger(kind: kind, id: id);

  /// The CHANNEL-SCOPED identity of this input — what a MIDI-learn capture for
  /// a controller binding records (part 7).
  MappingTrigger get channelTrigger =>
      MappingTrigger(kind: kind, id: id, midiChannel: midiChannel);

  /// Whether this input represents a press / active edge (`value > 0`).
  bool get isPress => value > 0;

  @override
  List<Object?> get props => [kind, id, value, midiChannel];

  @override
  String toString() =>
      'RawControllerInput(${kind.name}#$id@$midiChannel = $value)';
}
