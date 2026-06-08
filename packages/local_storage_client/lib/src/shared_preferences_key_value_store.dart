import 'package:local_storage_client/src/key_value_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A [KeyValueStore] backed by `shared_preferences` (the async, uncached API),
/// persisted to the platform's native preferences store.
class SharedPreferencesKeyValueStore implements KeyValueStore {
  /// Creates a [SharedPreferencesKeyValueStore], optionally with an injected
  /// [preferences] instance (useful for tests).
  SharedPreferencesKeyValueStore({SharedPreferencesAsync? preferences})
    : _prefs = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;

  @override
  Future<int?> getInt(String key) => _prefs.getInt(key);

  @override
  Future<void> setInt(String key, int value) => _prefs.setInt(key, value);

  @override
  Future<void> remove(String key) => _prefs.remove(key);
}
