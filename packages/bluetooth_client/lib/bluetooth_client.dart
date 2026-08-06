/// Data client for appliance Bluetooth (`segno-bt-ctl`).
library;

export 'src/bluetooth_client.dart' show BluetoothClient;
export 'src/bluetooth_models.dart'
    show
        BluetoothDevice,
        BluetoothDeviceKind,
        BluetoothStatus,
        bluetoothDeviceKindFromIcon;
export 'src/fake_bluetooth_client.dart' show FakeBluetoothClient;
export 'src/system_bluetooth_client.dart'
    show SystemBluetoothClient, createBluetoothClient;
export 'src/unsupported_bluetooth_client.dart' show UnsupportedBluetoothClient;
