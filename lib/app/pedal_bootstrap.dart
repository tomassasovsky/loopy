import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:midi_client/midi_client.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// Builds the [PedalRepository] for the bidirectional foot pedal, kept separate
/// from `midi_bootstrap` / `audio_bootstrap` so the pedal's output lifecycle is
/// independent of both audio and MIDI input.
///
/// The pedal's **input** reuses the single capture owned by [midiSource] (the
/// device-selection feature's `MidiControllerSource`): its recognized Note/CC
/// activity is reconstructed to raw `(status, data1, data2)` and fed to the
/// repository, so there is no second native capture on the device. The pedal's
/// **output** is opened by [NativePedalTransport] (a fresh `MidiOutClient`).
///
/// Returns `null` when there is no MIDI input source, or when constructing the
/// native output handle throws (a build/platform with no MIDI backend) — the
/// looper stays fully usable and the picker shows its empty state.
PedalRepository? createPedalRepository(
  MidiControllerSource? midiSource, {
  PedalTransport Function(Stream<PedalRawMessage> input)? transportFactory,
}) {
  if (midiSource == null) return null;
  try {
    final input = midiSource.activity.expand<PedalRawMessage>((raw) {
      switch (raw.kind) {
        case ControllerSourceKind.midiNote:
          return [
            (
              status: raw.value > 0 ? 0x90 : 0x80,
              data1: raw.id,
              data2: raw.value,
            ),
          ];
        case ControllerSourceKind.midiCc:
          return [(status: 0xB0, data1: raw.id, data2: raw.value)];
        case ControllerSourceKind.gpio:
          return const [];
      }
    });
    final transport =
        transportFactory?.call(input) ?? NativePedalTransport(input: input);
    return PedalRepository(transport);
  } on Object catch (error, stackTrace) {
    // A missing/unsupported native MIDI output backend is non-fatal.
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'loopy',
        context: ErrorDescription('creating the pedal output repository'),
      ),
    );
    return null;
  }
}
