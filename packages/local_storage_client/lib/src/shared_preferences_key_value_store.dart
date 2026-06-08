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
  Future<String?> getString(String key) => _prefs.getString(key);

  @override
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);

  @override
  Future<bool?> getBool(String key) => _prefs.getBool(key);

  @override
  Future<void> setBool(String key, {required bool value}) =>
      _prefs.setBool(key, value);

  @override
  Future<double?> getDouble(String key) => _prefs.getDouble(key);

  @override
  Future<void> setDouble(String key, double value) =>
      _prefs.setDouble(key, value);

  @override
  Future<void> remove(String key) => _prefs.remove(key);
}
