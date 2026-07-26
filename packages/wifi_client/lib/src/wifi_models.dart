import 'package:equatable/equatable.dart';
import 'package:meta/meta.dart';

/// Live WiFi association status from `loopy-wifi-ctl status`.
@immutable
class WifiStatus extends Equatable {
  /// Creates a [WifiStatus].
  const WifiStatus({
    required this.supported,
    required this.enabled,
    required this.connected,
    this.ssid = '',
    this.ip = '',
    this.signal = 0,
  });

  /// Parses the helper's JSON status object.
  factory WifiStatus.fromJson(Map<String, dynamic> json) => WifiStatus(
    supported: json['supported'] == true,
    enabled: json['enabled'] == true,
    connected: json['connected'] == true,
    ssid: '${json['ssid'] ?? ''}',
    ip: '${json['ip'] ?? ''}',
    signal: _asInt(json['signal']),
  );

  /// Unsupported / unavailable placeholder.
  static const unsupported = WifiStatus(
    supported: false,
    enabled: false,
    connected: false,
  );

  /// Whether the appliance WiFi stack is present.
  final bool supported;

  /// Whether the radio/iface is administratively up (Control Center toggle).
  final bool enabled;

  /// Whether associated (wpa_state COMPLETED).
  final bool connected;

  /// Associated SSID (empty when disconnected).
  final String ssid;

  /// IPv4 address when leased (may be empty briefly after connect).
  final String ip;

  /// RSSI / signal hint from wpa (more negative = weaker).
  final int signal;

  @override
  List<Object?> get props => [supported, enabled, connected, ssid, ip, signal];
}

/// One scanned network from `loopy-wifi-ctl scan`.
@immutable
class WifiNetwork extends Equatable {
  /// Creates a [WifiNetwork].
  const WifiNetwork({
    required this.ssid,
    required this.signal,
    required this.secured,
  });

  /// Parses one scan-result object.
  factory WifiNetwork.fromJson(Map<String, dynamic> json) => WifiNetwork(
    ssid: '${json['ssid'] ?? ''}',
    signal: _asInt(json['signal']),
    secured: json['secured'] == true,
  );

  /// Network name.
  final String ssid;

  /// Signal level from scan_results (dBm-ish).
  final int signal;

  /// Whether the network requires a password.
  final bool secured;

  @override
  List<Object?> get props => [ssid, signal, secured];
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? 0;
}
