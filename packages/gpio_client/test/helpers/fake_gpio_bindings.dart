import 'package:gpio_client/gpio_client.dart';

/// A hardware-free stand-in for [GpioBindings].
///
/// Records the requested lines and lifecycle calls so the source's wiring and
/// dispose ordering are testable, and exposes [emit] to drive edges through the
/// callback the source registered in [open] (the path a real libgpiod poll
/// would take), complementing the source's direct `pushForTest`.
class FakeGpioBindings implements GpioBindings {
  /// The lines passed to [open], or `null` before it is called.
  List<int>? requestedLines;

  /// The edge callback registered by the source in [open].
  GpioEdgeCallback? onEdge;

  /// Ordered log of lifecycle calls: `open`, `close`, `dispose`.
  final List<String> calls = [];

  /// Drives an edge through the registered [onEdge] callback.
  void emit(int line, int level, {int tsUs = 0}) =>
      onEdge?.call(line, level, tsUs);

  @override
  void open(List<int> lines, GpioEdgeCallback onEdge) {
    calls.add('open');
    requestedLines = List.of(lines);
    this.onEdge = onEdge;
  }

  @override
  void close() => calls.add('close');

  @override
  void dispose() => calls.add('dispose');
}
