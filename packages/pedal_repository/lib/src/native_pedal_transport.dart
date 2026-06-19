// The native transport is the single FFI-touching pedal class. Its output path
// cannot be exercised without a real MIDI device, and the inbound path is just
// a pass-through of an injected stream, so the file is excluded from coverage
// (the package still meets its >= 90% bar). MidiOutClient itself is unit-tested
// in midi_client against fake bindings.
// coverage:ignore-file
import 'dart:typed_data';

import 'package:midi_client/midi_client.dart';
import 'package:pedal_repository/src/pedal_transport.dart';

/// The production [PedalTransport]: owns the MIDI **output** ([MidiOutClient])
/// and re-exposes the shared MIDI **input** capture as [input].
///
/// It deliberately does **not** create its own capture. The [input] stream is
/// injected by the wiring layer from the one `MidiControllerSource` the
/// device-selection feature owns (its recognized Note/CC traffic, reconstructed
/// to raw `(status, data1, data2)`), so there is exactly one inbound
/// subscription on the bound device.
class NativePedalTransport implements PedalTransport {
  /// Creates a [NativePedalTransport] over [input] (the shared inbound capture)
  /// and [out] (defaults to a real [MidiOutClient] on the platform library).
  NativePedalTransport({
    required Stream<PedalRawMessage> input,
    MidiOutClient? out,
  }) : _input = input,
       _out = out ?? MidiOutClient();

  final Stream<PedalRawMessage> _input;
  final MidiOutClient _out;

  @override
  Stream<PedalRawMessage> get input => _input;

  @override
  List<MidiDevice> enumerateOutputs() => _out.enumerate();

  @override
  int openOutput(String id) => _out.open(id);

  @override
  int closeOutput() => _out.close();

  @override
  int send(Uint8List bytes) => _out.send(bytes);

  @override
  Future<void> dispose() async => _out.dispose();
}
