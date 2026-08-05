part of 'bluetooth_cubit.dart';

/// State for [BluetoothCubit].
class BluetoothState extends Equatable {
  /// Creates a [BluetoothState].
  const BluetoothState({
    this.supported = false,
    this.status = BluetoothStatus.unsupported,
    this.devices = const [],
    this.scanning = false,
    this.busy = false,
    this.pairingAddress,
    this.errorMessage,
  });

  /// Whether the appliance Bluetooth helper is available.
  final bool supported;

  /// Latest adapter status.
  final BluetoothStatus status;

  /// Last scan results.
  final List<BluetoothDevice> devices;

  /// True while a scan is in flight.
  final bool scanning;

  /// True while a toggle/load is in flight.
  final bool busy;

  /// Address of the device being paired, if any. Pairing is the one action
  /// the console cannot finish on its own — bluez waits on the device — so it
  /// gets its own in-flight marker rather than hiding inside [busy].
  final String? pairingAddress;

  /// Last error message, if any.
  final String? errorMessage;

  /// Returns a copy with the given fields replaced.
  BluetoothState copyWith({
    bool? supported,
    BluetoothStatus? status,
    List<BluetoothDevice>? devices,
    bool? scanning,
    bool? busy,
    String? pairingAddress,
    String? errorMessage,
    bool clearError = false,
    bool clearPairing = false,
  }) => BluetoothState(
    supported: supported ?? this.supported,
    status: status ?? this.status,
    devices: devices ?? this.devices,
    scanning: scanning ?? this.scanning,
    busy: busy ?? this.busy,
    pairingAddress: clearPairing
        ? null
        : (pairingAddress ?? this.pairingAddress),
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
  );

  @override
  List<Object?> get props => [
    supported,
    status,
    devices,
    scanning,
    busy,
    pairingAddress,
    errorMessage,
  ];
}
