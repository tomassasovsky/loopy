part of 'wifi_cubit.dart';

/// What the Wi-Fi picker is showing.
class WifiState extends Equatable {
  /// Creates a [WifiState].
  const WifiState({
    required this.supported,
    this.networks = const [],
    this.busy = false,
    this.message,
  });

  /// Whether this build manages Wi-Fi at all. `false` hides the whole surface
  /// rather than showing an empty list that can never fill.
  final bool supported;

  /// Visible networks, connected first then by signal strength.
  final List<WifiNetwork> networks;

  /// Whether a scan, join or forget is in flight.
  final bool busy;

  /// A failure worth showing, or `null`. Carries nmcli's own wording, which
  /// names the real reason (bad password, timeout, no such network) better
  /// than anything invented here.
  final String? message;

  /// The network currently connected, or `null`.
  WifiNetwork? get active => networks.where((n) => n.active).firstOrNull;

  /// Copies with the given fields replaced. [clearMessage] drops [message],
  /// which a `null` argument cannot express.
  WifiState copyWith({
    bool? supported,
    List<WifiNetwork>? networks,
    bool? busy,
    String? message,
    bool clearMessage = false,
  }) => WifiState(
    supported: supported ?? this.supported,
    networks: networks ?? this.networks,
    busy: busy ?? this.busy,
    message: clearMessage ? null : (message ?? this.message),
  );

  @override
  List<Object?> get props => [supported, networks, busy, message];
}
