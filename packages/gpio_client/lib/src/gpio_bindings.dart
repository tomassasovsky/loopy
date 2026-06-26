/// Delivers a single GPIO edge: the [line] offset (BCM pin), the electrical
/// [level] after the edge (`0` = low, `1` = high), and a capture timestamp in
/// microseconds ([tsUs]) used for debounce windows.
///
/// The level is the raw physical line state. With the pull-up bias this seam
/// requests, an idle (open) footswitch reads `1` and a pressed (to-ground)
/// switch reads `0`; `GpioControllerSource` applies that active-low inversion,
/// so this callback stays a faithful report of the wire.
typedef GpioEdgeCallback = void Function(int line, int level, int tsUs);

/// The minimal libgpiod surface `GpioControllerSource` needs, behind an
/// interface so the source is 100% testable headless (there is no GPIO hardware
/// in CI, and the package must clear the 90% coverage gate).
///
/// The real implementation (`LibGpiodBindings`) is only constructed on a Pi;
/// tests inject a `FakeGpioBindings`.
abstract interface class GpioBindings {
  /// Requests [lines] as pull-up inputs and starts delivering their edges to
  /// [onEdge]. Called exactly once, from the source constructor.
  void open(List<int> lines, GpioEdgeCallback onEdge);

  /// Stops edge delivery and releases the line request. Idempotent.
  void close();

  /// Releases the chip and any native resources. Idempotent.
  void dispose();
}
