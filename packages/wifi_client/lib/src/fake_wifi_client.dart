import 'package:wifi_client/src/wifi_client.dart';
import 'package:wifi_client/src/wifi_models.dart';

/// In-memory WiFi stack for driving the Network face off the appliance.
///
/// Selected by `--dart-define=SEGNO_FAKE_RADIOS=true`; off by default so a
/// shipped build can never present invented networks as real ones.
///
/// Opinionated rather than empty, because the point is to *reach* the states
/// the mockups draw: a saved network in range and associated, a saved one out
/// of range, a secured one to join, and an open one. Delays are deliberate —
/// a scan that resolves between frames never shows its spinner. Failure is
/// reachable on purpose: [workingPassphrase] is the only one that succeeds,
/// and anything else fails the way the supplicant does.
class FakeWifiClient implements WifiClient {
  /// Creates a [FakeWifiClient].
  FakeWifiClient();

  /// The one passphrase that joins a secured network.
  static const workingPassphrase = 'segno123';

  static const _scanDelay = Duration(milliseconds: 900);
  static const _actionDelay = Duration(milliseconds: 500);
  static const _joinDelay = Duration(milliseconds: 1600);

  bool _enabled = true;
  String _connected = 'MyHouseWTF_es';

  final List<WifiNetwork> _networks = [
    const WifiNetwork(
      ssid: 'MyHouseWTF_es',
      signal: -42,
      secured: true,
      saved: true,
    ),
    const WifiNetwork(
      ssid: 'MyHouseWTF_es_2.4G',
      signal: -80,
      secured: true,
      saved: true,
      inRange: false,
    ),
    const WifiNetwork(ssid: 'Studio 5G', signal: -48, secured: true),
    const WifiNetwork(ssid: 'Cafe Free', signal: -71, secured: false),
  ];

  @override
  bool get isSupported => true;

  @override
  Future<WifiStatus> status() async {
    final joined = _enabled && _connected.isNotEmpty;
    return WifiStatus(
      supported: true,
      enabled: _enabled,
      connected: joined,
      ssid: joined ? _connected : '',
      ip: joined ? '192.168.50.212' : '',
      signal: joined ? -42 : 0,
    );
  }

  @override
  Future<List<WifiNetwork>> scan() async {
    await Future<void>.delayed(_scanDelay);
    if (!_enabled) return const [];
    return List.unmodifiable(_networks);
  }

  @override
  Future<void> connect(String ssid, {String? psk}) async {
    await Future<void>.delayed(_joinDelay);
    final network = _networks.where((n) => n.ssid == ssid).firstOrNull;
    if (network == null) throw StateError('No such network.');
    if (!network.inRange) {
      throw StateError('segno-wifi-ctl: timed out waiting for association');
    }
    if (network.secured && !network.saved && psk != workingPassphrase) {
      throw StateError('segno-wifi-ctl: authentication failed');
    }
    _connected = ssid;
    _markSaved(ssid);
  }

  @override
  Future<void> disconnect() async {
    await Future<void>.delayed(_actionDelay);
    _connected = '';
  }

  @override
  Future<void> forget(String ssid) async {
    await Future<void>.delayed(_actionDelay);
    if (_connected == ssid) _connected = '';
    _networks.removeWhere((n) => n.ssid == ssid && !n.inRange);
    final index = _networks.indexWhere((n) => n.ssid == ssid);
    if (index < 0) return;
    final network = _networks[index];
    _networks[index] = WifiNetwork(
      ssid: network.ssid,
      signal: network.signal,
      secured: network.secured,
      inRange: network.inRange,
    );
  }

  @override
  Future<void> setEnabled({required bool enabled}) async {
    await Future<void>.delayed(_actionDelay);
    _enabled = enabled;
    if (!enabled) _connected = '';
  }

  void _markSaved(String ssid) {
    final index = _networks.indexWhere((n) => n.ssid == ssid);
    if (index < 0) return;
    final network = _networks[index];
    _networks[index] = WifiNetwork(
      ssid: network.ssid,
      signal: network.signal,
      secured: network.secured,
      saved: true,
      inRange: network.inRange,
    );
  }
}
