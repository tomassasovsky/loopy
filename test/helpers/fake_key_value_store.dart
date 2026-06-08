import 'package:settings_repository/settings_repository.dart';

/// An in-memory [KeyValueStore] for tests.
class FakeKeyValueStore implements KeyValueStore {
  /// The backing map (inspect it in assertions).
  final Map<String, int> values = {};

  @override
  Future<int?> getInt(String key) async => values[key];

  @override
  Future<void> setInt(String key, int value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);
}
