/// Repository for appliance Bluetooth.
library;

export 'package:bluetooth_client/bluetooth_client.dart'
    show
        BluetoothClient,
        BluetoothDevice,
        BluetoothStatus,
        SystemBluetoothClient,
        UnsupportedBluetoothClient,
        createBluetoothClient;

export 'src/bluetooth_repository.dart' show BluetoothRepository;
