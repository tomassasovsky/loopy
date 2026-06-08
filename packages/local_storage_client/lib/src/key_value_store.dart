/// A minimal asynchronous key-value persistence boundary.
///
/// Repositories depend on this interface and inject a fake in tests; the
/// production implementation is `SharedPreferencesKeyValueStore`.
abstract interface class KeyValueStore {
  /// Reads the integer stored at [key], or `null` if absent.
  Future<int?> getInt(String key);

  /// Persists [value] at [key].
  Future<void> setInt(String key, int value);

  /// Removes any value stored at [key].
  Future<void> remove(String key);
}
