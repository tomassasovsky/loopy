import 'package:equatable/equatable.dart';
import 'package:meta/meta.dart';

/// Adapter status from `loopy-bt-ctl status`.
@immutable
class BluetoothStatus extends Equatable {
  /// Creates a [BluetoothStatus].
  const BluetoothStatus({
    required this.supported,
    required this.powered,
    required this.discoverable,
    required this.advertising,
    this.alias = '',
    this.connected = false,
    this.device = '',
  });

  /// Parses the helper's JSON status object.
  factory BluetoothStatus.fromJson(Map<String, dynamic> json) =>
      BluetoothStatus(
        supported: json['supported'] == true,
        powered: json['powered'] == true,
        discoverable: json['discoverable'] == true,
        advertising: json['advertising'] == true,
        alias: '${json['alias'] ?? ''}',
        connected: json['connected'] == true,
        device: '${json['device'] ?? ''}',
      );

  /// Unsupported placeholder.
  static const unsupported = BluetoothStatus(
    supported: false,
    powered: false,
    discoverable: false,
    advertising: false,
  );

  /// Whether bluez / the helper is available.
  final bool supported;

  /// Adapter powered.
  final bool powered;

  /// Classic discoverable.
  final bool discoverable;

  /// LE advertising active.
  final bool advertising;

  /// Adapter alias (e.g. "Loopy").
  final String alias;

  /// Whether at least one peer is Connected.
  final bool connected;

  /// Display name of the first connected peer (empty when none).
  final String device;

  @override
  List<Object?> get props => [
    supported,
    powered,
    discoverable,
    advertising,
    alias,
    connected,
    device,
  ];
}

/// One discovered device from `loopy-bt-ctl scan`.
@immutable
class BluetoothDevice extends Equatable {
  /// Creates a [BluetoothDevice].
  const BluetoothDevice({required this.name, required this.address});

  /// Parses one device object.
  factory BluetoothDevice.fromJson(Map<String, dynamic> json) =>
      BluetoothDevice(
        name: '${json['name'] ?? ''}',
        address: '${json['address'] ?? ''}',
      );

  /// Display name (falls back to address in the helper).
  final String name;

  /// Bluetooth address.
  final String address;

  @override
  List<Object?> get props => [name, address];
}
