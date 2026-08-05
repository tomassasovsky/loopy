part of 'wifi_cubit.dart';

/// State for [WifiCubit].
class WifiState extends Equatable {
  /// Creates a [WifiState].
  const WifiState({
    this.supported = false,
    this.status = WifiStatus.unsupported,
    this.networks = const [],
    this.scanning = false,
    this.busy = false,
    this.connectingSsid,
    this.failedSsid,
    this.disconnecting = false,
    this.errorMessage,
  });

  /// Whether the appliance WiFi helper is available.
  final bool supported;

  /// Latest association status.
  final WifiStatus status;

  /// Last scan results.
  final List<WifiNetwork> networks;

  /// True while a scan is in flight.
  final bool scanning;

  /// True while connect/disconnect/forget/load/radio is in flight.
  final bool busy;

  /// SSID currently being joined, if any.
  final String? connectingSsid;

  /// SSID whose last join attempt failed, if any. Kept so the failure banner's
  /// "Try again" can reopen the passphrase sheet for the network that failed
  /// rather than starting from the list again.
  final String? failedSsid;

  /// True while disconnect (or forget-of-active) is in flight.
  final bool disconnecting;

  /// Last error message, if any.
  final String? errorMessage;

  /// Returns a copy with the given fields replaced.
  WifiState copyWith({
    bool? supported,
    WifiStatus? status,
    List<WifiNetwork>? networks,
    bool? scanning,
    bool? busy,
    String? connectingSsid,
    String? failedSsid,
    bool? disconnecting,
    String? errorMessage,
    bool clearError = false,
    bool clearConnectingSsid = false,
  }) => WifiState(
    supported: supported ?? this.supported,
    status: status ?? this.status,
    networks: networks ?? this.networks,
    scanning: scanning ?? this.scanning,
    busy: busy ?? this.busy,
    connectingSsid: clearConnectingSsid
        ? null
        : (connectingSsid ?? this.connectingSsid),
    // Tied to the error it explains: clearing one clears the other, so a
    // stale SSID can never outlive the message that named it.
    failedSsid: clearError ? null : (failedSsid ?? this.failedSsid),
    disconnecting: disconnecting ?? this.disconnecting,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
  );

  @override
  List<Object?> get props => [
    supported,
    status,
    networks,
    scanning,
    busy,
    connectingSsid,
    failedSsid,
    disconnecting,
    errorMessage,
  ];
}
