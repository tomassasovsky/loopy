import 'package:wifi_client/src/wifi_client.dart';
import 'package:wifi_client/src/wifi_models.dart';

/// Compile-time flag: drive the radios from in-memory fakes instead of the
/// appliance helpers.
///
/// Enable with `--dart-define=SEGNO_FAKE_RADIOS=true`. Off by default, so a
/// shipped build can never present invented networks as real ones.
///
/// Exists because the Network face is the one console surface a desktop
/// machine cannot exercise at all: `segno-wifi-ctl` / `segno-bt-ctl` are
/// Linux-only appliance helpers, so on macOS every path below "this build has
/// no WiFi" is unreachable — including the ones with the most behaviour in
/// them (joining, wrong passphrases, pairing, forgetting).
const kFakeRadios = bool.fromEnvironment('SEGNO_FAKE_RADIOS');

/// An in-memory WiFi stack for desktop development.
///
/// Deliberately opinionated rather than empty: it starts associated, carries a
/// saved network that is out of range and one that is not, and an open
/// network — the four row states the mockups draw — and it takes its time, so
/// the scanning spinner and the joining banner are actually visible instead of
/// resolving between frames.
class FakeWifiClient implements WifiClient {
  /// Creates a [FakeWifiClient].
  FakeWifiClient({
    this.scanDelay = const Duration(milliseconds: 900),
    this.joinDelay = const Duration(milliseconds: 1400),
  });

  /// How long a scan takes.
  final Duration scanDelay;

  /// How long a join takes before it succeeds or fails.
  final Duration joinDelay;

  /// The passphrase [FakeWifiClient] accepts. Anything else fails the way a
  /// real supplicant does, so the failure banner and the sheet's retry are
  /// reachable without a radio.
  static const String passphrase = 'segno123';

  bool _enabled = true;
  String _connectedSsid = 'Studio-5G';
  final Set<String> _saved = {'Studio-5G', 'Studio-Backline'};

  static const _catalogue = <_FakeNetwork>[
    _FakeNetwork(ssid: 'Studio-5G', signal: -48, secured: true),
    _FakeNetwork(ssid: 'Studio-Guest', signal: -62, secured: true),
    _FakeNetwork(ssid: 'Cafe Free', signal: -71, secured: false),
    // Saved but never seen by a scan — the "not in range" row, which exists so
    // a profile that refuses to connect can still be forgotten.
    _FakeNetwork(
      ssid: 'Studio-Backline',
      signal: -80,
      secured: true,
      inRange: false,
    ),
  ];

  @override
  bool get isSupported => true;

  @override
  Future<WifiStatus> status() async => WifiStatus(
    supported: true,
    enabled: _enabled,
    connected: _enabled && _connectedSsid.isNotEmpty,
    ssid: _enabled ? _connectedSsid : '',
    ip: _enabled && _connectedSsid.isNotEmpty ? '192.168.50.212' : '',
    signal: -48,
  );

  @override
  Future<List<WifiNetwork>> scan() async {
    await Future<void>.delayed(scanDelay);
    if (!_enabled) return const [];
    return [
      for (final network in _catalogue)
        WifiNetwork(
          ssid: network.ssid,
          signal: network.signal,
          secured: network.secured,
          saved: _saved.contains(network.ssid),
          inRange: network.inRange,
        ),
    ];
  }

  @override
  Future<void> connect(String ssid, {String? psk}) async {
    await Future<void>.delayed(joinDelay);
    final network = _find(ssid);
    if (network == null) throw StateError('segno-wifi-ctl: no such network');
    if (!network.inRange) {
      throw StateError('segno-wifi-ctl: connection failed, not in range');
    }
    // A saved profile joins on its own; anything else has to match.
    final known = _saved.contains(ssid);
    if (network.secured && !known && psk != passphrase) {
      throw StateError('segno-wifi-ctl: authentication failed');
    }
    _connectedSsid = ssid;
    if (network.secured) _saved.add(ssid);
  }

  @override
  Future<void> disconnect() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _connectedSsid = '';
  }

  @override
  Future<void> forget(String ssid) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _saved.remove(ssid);
    if (_connectedSsid == ssid) _connectedSsid = '';
  }

  @override
  Future<void> setEnabled({required bool enabled}) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _enabled = enabled;
    if (!enabled) _connectedSsid = '';
  }

  _FakeNetwork? _find(String ssid) {
    for (final network in _catalogue) {
      if (network.ssid == ssid) return network;
    }
    return null;
  }
}

class _FakeNetwork {
  const _FakeNetwork({
    required this.ssid,
    required this.signal,
    required this.secured,
    this.inRange = true,
  });

  final String ssid;
  final int signal;
  final bool secured;
  final bool inRange;
}
