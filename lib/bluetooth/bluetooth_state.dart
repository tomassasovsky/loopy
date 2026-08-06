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
    this.errorMessage,
    this.pairingAddress,
    this.failedAddress,
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

  /// Last error message, if any. Paired with [failedAddress] so a message can
  /// never outlive the device it was about.
  final String? errorMessage;

  /// Address currently being paired, if any.
  ///
  /// Deliberately NOT [busy]. Pairing waits on a human pressing a button on a
  /// device, which can take as long as it takes, and freezing the whole list
  /// on that would make every other row unusable while one device is thought
  /// about. The list stays live behind the pairing banner.
  final String? pairingAddress;

  /// Address the last failure was about, tied to [errorMessage] so a stale
  /// address can never outlive the message that named it.
  final String? failedAddress;

  /// Returns a copy with the given fields replaced.
  BluetoothState copyWith({
    bool? supported,
    BluetoothStatus? status,
    List<BluetoothDevice>? devices,
    bool? scanning,
    bool? busy,
    String? errorMessage,
    String? pairingAddress,
    String? failedAddress,
    bool clearError = false,
    bool clearPairing = false,
  }) => BluetoothState(
    supported: supported ?? this.supported,
    status: status ?? this.status,
    devices: devices ?? this.devices,
    scanning: scanning ?? this.scanning,
    busy: busy ?? this.busy,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    failedAddress: clearError ? null : (failedAddress ?? this.failedAddress),
    pairingAddress: clearPairing
        ? null
        : (pairingAddress ?? this.pairingAddress),
  );

  @override
  List<Object?> get props => [
    supported,
    status,
    devices,
    scanning,
    busy,
    errorMessage,
    pairingAddress,
    failedAddress,
  ];
}
