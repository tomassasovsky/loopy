/// I/O boundary for appliance display brightness (`loopy-brightness-ctl`).
abstract class BrightnessClient {
  /// Whether DDC/CI brightness control is available.
  Future<bool> isSupported();

  /// Current brightness in `0..1`.
  Future<double> get();

  /// Sets brightness in `0..1` (no-op when unsupported).
  Future<void> set(double value);
}

/// No-op client used on desktop / when the helper is absent.
class UnsupportedBrightnessClient implements BrightnessClient {
  /// Creates an [UnsupportedBrightnessClient].
  const UnsupportedBrightnessClient();

  @override
  Future<bool> isSupported() async => false;

  @override
  Future<double> get() async => 0.8;

  @override
  Future<void> set(double value) async {}
}
