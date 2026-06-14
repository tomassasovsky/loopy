/// Native USB MIDI input for Loopy.
///
/// Wraps the `le_midi_*` capture seam (in `loopy_engine`) behind a small typed
/// Dart API (`MidiClient` + `MidiDevice`) and adapts it to the controller
/// abstraction as a `MidiControllerSource` (implements `ControllerSource`), so
/// a foot pedal can drive the looper hands-free.
library;

export 'src/midi_client_base.dart' show MidiClient, MidiException;
export 'src/midi_controller_source.dart' show MidiControllerSource;
export 'src/midi_device.dart' show MidiDevice;
