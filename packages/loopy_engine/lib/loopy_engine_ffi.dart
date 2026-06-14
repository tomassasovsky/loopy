/// Low-level FFI surface of the Loopy engine.
///
/// Most consumers should depend on the typed `loopy_engine.dart` API and its
/// value objects instead. This secondary entrypoint deliberately exposes the
/// generated bindings and the native fixed-size string helpers for the few
/// sibling packages that drive a native seam directly — currently
/// `midi_client`, which opens the MIDI capture surface (`le_midi_*`) over the
/// generated `LoopyEngineBindings`.
///
/// Importing this from another package is intentional and avoids reaching into
/// `loopy_engine/src` (which would trip the `implementation_imports` lint).
library;

export 'src/ffi_strings.dart'
    show kNativeStringCapacity, readNativeString, writeNativeString;
export 'src/generated/loopy_engine_bindings.dart';
