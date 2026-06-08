import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage_client/local_storage_client.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('persists, reads, and removes an int', () async {
    final store = SharedPreferencesKeyValueStore();

    expect(await store.getInt('offset'), isNull);

    await store.setInt('offset', 480);
    expect(await store.getInt('offset'), 480);

    await store.remove('offset');
    expect(await store.getInt('offset'), isNull);
  });
}
