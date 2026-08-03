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

  /// Last error message, if any.
  final String? errorMessage;

  /// Returns a copy with the given fields replaced.
  BluetoothState copyWith({
    bool? supported,
    BluetoothStatus? status,
    List<BluetoothDevice>? devices,
    bool? scanning,
    bool? busy,
    String? errorMessage,
    bool clearError = false,
  }) => BluetoothState(
    supported: supported ?? this.supported,
    status: status ?? this.status,
    devices: devices ?? this.devices,
    scanning: scanning ?? this.scanning,
    busy: busy ?? this.busy,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
  );

  @override
  List<Object?> get props => [
    supported,
    status,
    devices,
    scanning,
    busy,
    errorMessage,
  ];
}
