import 'dart:async';
import 'dart:typed_data';

import 'package:midi_client/midi_client.dart' show MidiDevice;
import 'package:pedal_repository/pedal_repository.dart';

/// A controllable [PedalTransport] for driving `PedalCubit` tests through a
/// real `PedalRepository`: push inbound messages with [emit] and inspect
/// outbound traffic in [sent].
class FakePedalTransport implements PedalTransport {
  /// Creates a [FakePedalTransport].
  FakePedalTransport({this.outputs = const [], this.openResult = 0});

  /// Devices returned by [enumerateOutputs].
  List<MidiDevice> outputs;

  /// The code [openOutput] returns (`0` = success).
  int openResult;

  final StreamController<PedalRawMessage> _input =
      StreamController<PedalRawMessage>.broadcast();

  /// Every payload passed to [send], in order.
  final List<Uint8List> sent = [];

  /// Whether [dispose] has been called.
  bool disposed = false;

  /// Pushes one inbound message as if it arrived from the native capture.
  void emit(int status, int data1, int data2) =>
      _input.add((status: status, data1: data1, data2: data2));

  @override
  Stream<PedalRawMessage> get input => _input.stream;

  @override
  List<MidiDevice> enumerateOutputs() => outputs;

  @override
  int openOutput(String id) => openResult;

  @override
  int closeOutput() => 0;

  @override
  int send(Uint8List bytes) {
    sent.add(bytes);
    return 0;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _input.close();
  }
}
