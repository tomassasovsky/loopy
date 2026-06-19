import 'dart:typed_data';

import 'package:midi_client/midi_client.dart' show MidiDevice;
import 'package:pedal_repository/src/pedal_transport.dart';

/// A do-nothing [PedalTransport] for when no MIDI backend / output is available
/// (the mock flavor, or a platform with no MIDI), so a `PedalRepository` and
/// its cubit can always be constructed and the settings picker shows its empty
/// state. It enumerates no outputs, never opens, and drops sends.
class NoopPedalTransport implements PedalTransport {
  /// Creates a const [NoopPedalTransport].
  const NoopPedalTransport();

  @override
  Stream<PedalRawMessage> get input => const Stream.empty();

  @override
  List<MidiDevice> enumerateOutputs() => const [];

  @override
  int openOutput(String id) => 1; // never succeeds (no backend)

  @override
  int closeOutput() => 0;

  @override
  int send(Uint8List bytes) => 1;

  @override
  Future<void> dispose() async {}
}
