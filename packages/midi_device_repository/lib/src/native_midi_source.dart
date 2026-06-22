import 'package:flutter/foundation.dart';
import 'package:midi_client/midi_client.dart';

/// Builds the long-lived [MidiControllerSource] for the controller pipeline,
/// kept deliberately separate from audio bootstrap so the MIDI lifecycle is
/// fully independent of the audio engine ("switching MIDI never restarts
/// audio").
///
/// Construction opens the native MIDI library; on a build/platform with no MIDI
/// backend (or a flavor where the native library is absent) it can throw, so
/// this returns `null` rather than aborting launch — the looper stays fully
/// usable without MIDI and the picker shows its empty state.
///
/// The saved device is *reconnected* by `MidiSetupCubit` (created eagerly at
/// the shell), so all open/close lives on one path; this helper only builds it.
MidiControllerSource? createNativeMidiSource({
  MidiControllerSource Function()? factory,
}) {
  try {
    return (factory ?? MidiControllerSource.new)();
  } on Object catch (error, stackTrace) {
    // A missing/unsupported native MIDI backend is non-fatal: log and run on.
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'loopy',
        context: ErrorDescription('creating the native MIDI source'),
      ),
    );
    return null;
  }
}
