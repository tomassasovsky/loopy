import 'dart:async';
import 'dart:typed_data';

import 'package:midi_client/midi_client.dart' show MidiDevice;
import 'package:pedal_repository/pedal_repository.dart';

/// A hardware-free [PedalTransport] for testing `PedalRepository`.
///
/// Records outbound traffic in [sent] and the call order in [calls], lets a
/// test push inbound messages with [emit], and reports [outputs] from
/// `enumerateOutputs`. `openOutput` returns [openResult] (non-zero simulates a
/// failed bind).
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

  /// Ordered log of seam calls (`enumerate`, `open`, `close`, `send`).
  final List<String> calls = [];

  /// The id passed to the most recent [openOutput].
  String? openedId;

  /// Whether [dispose] has been called.
  bool disposed = false;

  /// Pushes one inbound message as if it arrived from the native capture.
  void emit(int status, int data1, int data2) =>
      _input.add((status: status, data1: data1, data2: data2));

  @override
  Stream<PedalRawMessage> get input => _input.stream;

  @override
  List<MidiDevice> enumerateOutputs() {
    calls.add('enumerate');
    return outputs;
  }

  @override
  int openOutput(String id) {
    calls.add('open');
    openedId = id;
    return openResult;
  }

  @override
  int closeOutput() {
    calls.add('close');
    return 0;
  }

  @override
  int send(Uint8List bytes) {
    calls.add('send');
    sent.add(bytes);
    return 0;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _input.close();
  }
}
