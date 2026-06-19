// The platform shared-library loader cannot be exercised in a unit test (it
// resolves a real native library by name / process namespace). Excluded from
// coverage, like the generated FFI bindings.
// coverage:ignore-file
import 'dart:ffi';
import 'dart:io';

/// Opens the bundled `loopy_engine` native library for the current platform.
///
/// Shared by every MIDI FFI wrapper in this package (`MidiClient` for input,
/// `MidiOutClient` for output): the MIDI symbols (`le_midi_*` / `le_midi_out_*`)
/// are exported from the same library as the audio engine. On Apple platforms
/// they live in the process's global namespace (static-linked into the Runner),
/// so [DynamicLibrary.process] resolves them; on Linux/Windows the engine is a
/// separate shared library opened by name.
DynamicLibrary openLoopyEngineLibrary() {
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.process();
  }
  if (Platform.isWindows) return DynamicLibrary.open('loopy_engine.dll');
  return DynamicLibrary.open('libloopy_engine.so');
}
