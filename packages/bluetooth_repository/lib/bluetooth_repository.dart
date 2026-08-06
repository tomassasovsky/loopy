/// Repository for appliance Bluetooth.
library;

export 'package:bluetooth_client/bluetooth_client.dart'
    show
        BluetoothClient,
        BluetoothDevice,
        BluetoothDeviceKind,
        BluetoothStatus,
        FakeBluetoothClient,
        SystemBluetoothClient,
        UnsupportedBluetoothClient,
        bluetoothDeviceKindFromIcon,
        createBluetoothClient;

export 'src/bluetooth_repository.dart' show BluetoothRepository;
