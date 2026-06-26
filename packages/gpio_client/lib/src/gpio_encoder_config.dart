/// The two quadrature pins of a rotary encoder wired to the console.
///
/// Only the A/B rotation pins live here; the encoder's push-switch is just a
/// normal `gpio` press line (it flows through `gpioDefaults()` like a
/// footswitch), so it is part of `GpioControllerSource.lines`, not this config.
class GpioEncoderConfig {
  /// Creates a [GpioEncoderConfig] for the encoder's [pinA] / [pinB] (BCM
  /// offsets).
  const GpioEncoderConfig({required this.pinA, required this.pinB});

  /// The encoder's A (BCM offset).
  final int pinA;

  /// The encoder's B (BCM offset).
  final int pinB;

  /// The A/B lines, for the source to request alongside the press lines.
  List<int> get lines => [pinA, pinB];
}
