import 'package:led_client/src/led_frame.dart';
import 'package:led_client/src/led_transport.dart';
import 'package:meta/meta.dart';

/// Owns the LED driver link: opens it, runs the boot-time health handshake, and
/// pushes [LedFrame]s (diffed, so unchanged state costs no bytes on the wire).
///
/// Mirrors `PedalRepository`: transport-only, no projection — the app layer
/// maps `LooperState` to a [LedFrame] and calls [pushFrame]. The default off-Pi
/// transport is a [NoopLedTransport], so this is always safe to construct.
class LedRepository {
  /// Creates a [LedRepository] over [transport] (defaults to a no-op).
  LedRepository([LedTransport transport = const NoopLedTransport()])
    : _transport = transport;

  final LedTransport _transport;

  LedFrame? _lastFrame;
  LedHealth _health = LedHealth.unknown;
  var _started = false;

  /// The last resolved driver health.
  LedHealth get health => _health;

  /// Opens the link and pings the driver once. Returns the resolved [health]
  /// (`ok` on ack, `missing` on timeout). Idempotent.
  Future<LedHealth> start({
    Duration pingTimeout = const Duration(seconds: 2),
  }) async {
    if (_started) return _health;
    _started = true;
    _transport.open();
    final acked = await _transport.ping(timeout: pingTimeout);
    return _health = acked ? LedHealth.ok : LedHealth.missing;
  }

  /// Serialises and sends [frame], skipping the write when it is identical to
  /// the previously sent frame.
  void pushFrame(LedFrame frame) {
    if (frame == _lastFrame) return;
    _lastFrame = frame;
    _transport.send(frame.toBytes());
  }

  /// The last frame sent, for tests.
  @visibleForTesting
  LedFrame? get lastFrame => _lastFrame;

  /// Closes the link.
  void dispose() => _transport.close();
}
