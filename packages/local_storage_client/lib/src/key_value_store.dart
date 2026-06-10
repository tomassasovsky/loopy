/// A minimal asynchronous key-value persistence boundary.
///
/// Repositories depend on this interface and inject a fake in tests; the
/// production implementation is `SharedPreferencesKeyValueStore`.
abstract interface class KeyValueStore {
  /// Reads the integer stored at [key], or `null` if absent.
  Future<int?> getInt(String key);

  /// Persists the integer [value] at [key].
  Future<void> setInt(String key, int value);

  /// Reads the string stored at [key], or `null` if absent.
  Future<String?> getString(String key);

  /// Persists the string [value] at [key].
  Future<void> setString(String key, String value);

  /// Reads the boolean stored at [key], or `null` if absent.
  Future<bool?> getBool(String key);

  /// Persists the boolean [value] at [key].
  Future<void> setBool(String key, {required bool value});

  /// Reads the double stored at [key], or `null` if absent.
  Future<double?> getDouble(String key);

  /// Persists the double [value] at [key].
  Future<void> setDouble(String key, double value);

  /// Removes any value stored at [key].
  Future<void> remove(String key);

  /// Removes all values.
  Future<void> clear();
}
