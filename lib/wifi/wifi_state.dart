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

  /// True while connect/disconnect/forget/load is in flight.
  final bool busy;

  /// Last error message, if any.
  final String? errorMessage;

  /// Returns a copy with the given fields replaced.
  WifiState copyWith({
    bool? supported,
    WifiStatus? status,
    List<WifiNetwork>? networks,
    bool? scanning,
    bool? busy,
    String? errorMessage,
    bool clearError = false,
  }) => WifiState(
    supported: supported ?? this.supported,
    status: status ?? this.status,
    networks: networks ?? this.networks,
    scanning: scanning ?? this.scanning,
    busy: busy ?? this.busy,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
  );

  @override
  List<Object?> get props => [
    supported,
    status,
    networks,
    scanning,
    busy,
    errorMessage,
  ];
}
