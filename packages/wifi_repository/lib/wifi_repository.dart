/// Repository for appliance WiFi.
library;

export 'package:wifi_client/wifi_client.dart'
    show
        FakeWifiClient,
        SystemWifiClient,
        UnsupportedWifiClient,
        WifiClient,
        WifiNetwork,
        WifiStatus,
        createWifiClient,
        kFakeRadios;

export 'src/wifi_repository.dart' show WifiRepository;
