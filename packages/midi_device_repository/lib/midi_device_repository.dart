/// Repository layer for Loopy's MIDI input (foot-controller) device.
///
/// Owns the device lifecycle (enumerate / open / close), hotplug supervision,
/// and selection persistence, and projects a `MidiConnection` stream for the
/// presentation layer — mirroring the `LooperRepository` seam for audio. It
/// **borrows** the long-lived `MidiControllerSource` (owned and disposed by the
/// `ControllerRepository`) and never disposes it. Deliberately holds no audio
/// dependency, so switching or losing a MIDI device can never restart audio.
library;

export 'package:midi_client/midi_client.dart' show MidiDevice;

export 'src/midi_device_repository.dart';
export 'src/models/midi_connection.dart';
export 'src/native_midi_source.dart';
