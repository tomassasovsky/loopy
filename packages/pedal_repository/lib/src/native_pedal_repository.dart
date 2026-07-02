import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:midi_client/midi_client.dart';
import 'package:pedal_repository/src/native_pedal_transport.dart';
import 'package:pedal_repository/src/noop_pedal_transport.dart';
import 'package:pedal_repository/src/pedal_repository.dart';
import 'package:pedal_repository/src/pedal_transport.dart';
import 'package:pedal_repository/src/simulator_pedal_transport.dart';

/// Builds the [PedalRepository] for the bidirectional foot pedal, kept separate
/// from the MIDI / audio bootstrap so the pedal's output lifecycle is
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
PedalRepository? createNativePedalRepository(
  MidiControllerSource? midiSource, {
  PedalTransport Function(Stream<PedalRawMessage> input)? transportFactory,
}) {
  final transport = _nativeTransport(midiSource, transportFactory);
  return transport == null ? null : PedalRepository(transport);
}

/// Builds a [PedalRepository] wrapped in a [SimulatorPedalTransport], returning
/// both the repository and the simulator handle (they share one transport
/// graph — the repository is built over the simulator).
///
/// The simulator decorates the native transport when MIDI is available, or a
/// [NoopPedalTransport] otherwise, so the on-screen faceplate is **always**
/// available — even with no MIDI backend, or on the mock flavor. The faceplate
/// injects presses into, and reads decoded frames from, the returned `sim`.
({PedalRepository repo, SimulatorPedalTransport sim})
createSimAwarePedalRepository(
  MidiControllerSource? midiSource, {
  PedalTransport Function(Stream<PedalRawMessage> input)? transportFactory,
}) {
  final inner =
      _nativeTransport(midiSource, transportFactory) ??
      const NoopPedalTransport();
  final sim = SimulatorPedalTransport(inner: inner);
  return (repo: PedalRepository(sim), sim: sim);
}

/// Builds the native (or [transportFactory]-supplied) transport over the
/// [midiSource] capture, or `null` when there is no source or the native output
/// handle cannot be constructed (a build/platform with no MIDI backend).
PedalTransport? _nativeTransport(
  MidiControllerSource? midiSource,
  PedalTransport Function(Stream<PedalRawMessage> input)? transportFactory,
) {
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
      }
    });
    return transportFactory?.call(input) ?? NativePedalTransport(input: input);
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
