import 'package:meta/meta.dart';

/// A MIDI input port discovered by `MidiClient.enumerate`.
///
/// The pure-Dart projection of the native `le_midi_info` struct. [id] is the
/// per-OS stable token used to re-select the same device across replug (the
/// CoreMIDI unique id on macOS, the port name on ALSA/WinMM); [name] is the
/// human-readable label shown in the picker. Mirrors `AudioDevice` from
/// `loopy_engine`, scoped to the fields the MIDI seam reports.
@immutable
class MidiDevice {
  /// Creates a [MidiDevice].
  const MidiDevice({
    required this.id,
    required this.name,
    this.isDefault = false,
  });

  /// The per-OS stable id used to re-open this device (`le_midi_open`).
  final String id;

  /// The human-readable device label.
  final String name;

  /// Whether the OS marks this as the system-preferred MIDI input. Always
  /// `false` on ALSA/WinMM, which expose no default.
  final bool isDefault;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MidiDevice &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          isDefault == other.isDefault;

  @override
  int get hashCode => Object.hash(id, name, isDefault);

  @override
  String toString() =>
      'MidiDevice(id: $id, name: $name, isDefault: $isDefault)';
}
