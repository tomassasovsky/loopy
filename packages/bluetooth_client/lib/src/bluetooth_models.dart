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

/// What kind of thing a paired device is, mapped from bluez's `Icon:` field.
///
/// A closed set rather than the raw bluez string: the face prints this as a
/// row subtitle, so it has to be translatable, and bluez's icon names are
/// freedesktop icon-theme identifiers rather than user-facing words.
enum BluetoothDeviceKind {
  /// `audio-headphones` / `audio-headset`.
  headphones,

  /// `audio-card` / `audio-speakers`.
  speaker,

  /// `phone`.
  phone,

  /// `computer`.
  computer,

  /// `input-keyboard`.
  keyboard,

  /// `input-mouse` / `input-tablet`.
  mouse,

  /// `input-gaming`.
  gamepad,

  /// bluez reported no `Icon:`, or one outside the set above. Drawn as an
  /// absent fact rather than guessed at — see the IA's "things the app cannot
  /// know are not drawn as zeroes".
  unknown,
}

/// Maps a bluez `Icon:` value onto a [BluetoothDeviceKind].
BluetoothDeviceKind bluetoothDeviceKindFromIcon(String icon) =>
    switch (icon.trim().toLowerCase()) {
      'audio-headphones' || 'audio-headset' => BluetoothDeviceKind.headphones,
      'audio-card' || 'audio-speakers' => BluetoothDeviceKind.speaker,
      'phone' => BluetoothDeviceKind.phone,
      'computer' => BluetoothDeviceKind.computer,
      'input-keyboard' => BluetoothDeviceKind.keyboard,
      'input-mouse' || 'input-tablet' => BluetoothDeviceKind.mouse,
      'input-gaming' => BluetoothDeviceKind.gamepad,
      _ => BluetoothDeviceKind.unknown,
    };

/// One device from `segno-bt-ctl scan`.
///
/// The list is not only what the last discovery saw: a **paired** device is
/// reported even when it is out of range, for the same reason a saved WiFi
/// network is — a pairing you cannot see is still a pairing you may want to
/// drop. [inRange] carries that distinction.
@immutable
class BluetoothDevice extends Equatable {
  /// Creates a [BluetoothDevice].
  const BluetoothDevice({
    required this.name,
    required this.address,
    this.paired = false,
    this.connected = false,
    this.inRange = true,
    this.kind = BluetoothDeviceKind.unknown,
  });

  /// Parses one device object.
  factory BluetoothDevice.fromJson(Map<String, dynamic> json) =>
      BluetoothDevice(
        name: '${json['name'] ?? ''}',
        address: '${json['address'] ?? ''}',
        paired: json['paired'] == true,
        connected: json['connected'] == true,
        inRange: json['inRange'] != false,
        kind: bluetoothDeviceKindFromIcon('${json['icon'] ?? ''}'),
      );

  /// Display name (falls back to address in the helper).
  final String name;

  /// Bluetooth address.
  final String address;

  /// Whether bluez holds a pairing for this device.
  final bool paired;

  /// Whether a link is currently up.
  final bool connected;

  /// Whether the last discovery actually saw this device.
  final bool inRange;

  /// What the device is, from bluez's `Icon:`.
  final BluetoothDeviceKind kind;

  @override
  List<Object?> get props => [name, address, paired, connected, inRange, kind];
}
