import 'package:equatable/equatable.dart';
import 'package:meta/meta.dart';

/// Adapter status from `segno-bt-ctl status`.
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

  /// Adapter alias (e.g. "Segno").
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

/// One discovered device from `segno-bt-ctl scan`.
@immutable
class BluetoothDevice extends Equatable {
  /// Creates a [BluetoothDevice].
  const BluetoothDevice({
    required this.name,
    required this.address,
    this.paired = false,
    this.connected = false,
    this.inRange = true,
    this.kind = '',
  });

  /// Parses one device object.
  factory BluetoothDevice.fromJson(Map<String, dynamic> json) =>
      BluetoothDevice(
        name: '${json['name'] ?? ''}',
        address: '${json['address'] ?? ''}',
        paired: json['paired'] == true,
        connected: json['connected'] == true,
        inRange: json['inRange'] != false,
        kind: '${json['kind'] ?? ''}',
      );

  /// Display name (falls back to address in the helper).
  final String name;

  /// Bluetooth address.
  final String address;

  /// Whether this console holds a pairing for the device, so it can connect
  /// without the device being put back into pairing mode — and so forgetting
  /// it is a destructive act worth confirming.
  final bool paired;

  /// Whether the device is connected right now.
  final bool connected;

  /// Whether the last scan saw the device.
  ///
  /// Paired devices are listed even when they are out of range, for the same
  /// reason saved WiFi networks are: a pairing you cannot see is still a
  /// pairing you may want to drop.
  final bool inRange;

  /// bluez device class hint ("headphones", "keyboard", …), shown as the row's
  /// subtitle. Empty when the helper reports none.
  final String kind;

  @override
  List<Object?> get props => [name, address, paired, connected, inRange, kind];
}
