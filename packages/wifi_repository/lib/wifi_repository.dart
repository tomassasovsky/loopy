/// Repository for appliance WiFi.
library;

export 'package:wifi_client/wifi_client.dart'
    show
        SystemWifiClient,
        UnsupportedWifiClient,
        WifiClient,
        WifiNetwork,
        WifiStatus,
        createWifiClient;

export 'src/wifi_repository.dart' show WifiRepository;
