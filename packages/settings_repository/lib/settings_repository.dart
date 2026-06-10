/// Persists Loopy settings (per-device latency calibration, audio config, UI).
library;

export 'package:local_storage_client/local_storage_client.dart'
    show KeyValueStore, SharedPreferencesKeyValueStore;

export 'src/settings_repository.dart'
    show SettingsRepository, StoredAudioConfig;
