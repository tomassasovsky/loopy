import 'dart:typed_data';

/// The health of the LED driver link, as resolved by a boot-time ping.
enum LedHealth {
  /// Not yet checked.
  unknown,

  /// The driver acknowledged the ping — link is up.
  ok,

  /// No acknowledgement within the timeout — the driver is missing/unflashed.
  missing,
}

/// The minimal serial link to the WS2812 driver MCU, behind an interface so the
/// LED repository is testable headless (there is no MCU in CI).
///
/// The real implementation (`UartLedTransport`) talks to the Pi's UART; tests
/// inject a `FakeLedTransport`, and the off-Pi default is a `NoopLedTransport`.
abstract interface class LedTransport {
  /// Opens the link. Idempotent.
  void open();

  /// Sends a serialised frame to the driver.
  void send(Uint8List frame);

  /// Sends a health ping and resolves `true` if the driver acknowledges within
  /// [timeout], else `false`.
  Future<bool> ping({Duration timeout});

  /// Closes the link. Idempotent.
  void close();
}

/// A do-nothing transport for hosts with no LED driver (every desktop, and
/// tests). Reports healthy so no fault banner is shown where no driver is
/// expected.
class NoopLedTransport implements LedTransport {
  /// Creates a [NoopLedTransport].
  const NoopLedTransport();

  @override
  void open() {}

  @override
  void send(Uint8List frame) {}

  @override
  Future<bool> ping({Duration timeout = const Duration(seconds: 2)}) async =>
      true;

  @override
  void close() {}
}
