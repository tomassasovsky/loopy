import 'dart:typed_data';

import 'package:led_client/led_client.dart';

/// A hardware-free [LedTransport] for tests: records lifecycle calls and sent
/// frames, and returns a configurable [pingAck].
class FakeLedTransport implements LedTransport {
  /// Creates a [FakeLedTransport] whose [ping] resolves [pingAck].
  FakeLedTransport({this.pingAck = true});

  /// The result [ping] resolves to.
  bool pingAck;

  /// Ordered log of lifecycle calls: `open`, `close`, `ping`.
  final List<String> calls = [];

  /// Every frame passed to [send], in order.
  final List<Uint8List> sent = [];

  @override
  void open() => calls.add('open');

  @override
  void send(Uint8List frame) => sent.add(frame);

  @override
  Future<bool> ping({Duration timeout = const Duration(seconds: 2)}) async {
    calls.add('ping');
    return pingAck;
  }

  @override
  void close() => calls.add('close');
}
