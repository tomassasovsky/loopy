/// Persists Loopy settings (per-device latency calibration, audio config, UI).
library;

export 'package:local_storage_client/local_storage_client.dart'
    show KeyValueStore, SharedPreferencesKeyValueStore;
// AudioBackend is part of StoredAudioConfig's public API, so re-export it.
export 'package:loopy_engine/loopy_engine.dart' show AudioBackend;

export 'src/settings_repository.dart'
    show SettingsRepository, StoredAudioConfig;
