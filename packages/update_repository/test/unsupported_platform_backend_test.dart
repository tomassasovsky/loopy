import 'package:flutter_test/flutter_test.dart';
import 'package:update_repository/update_repository.dart';

void main() {
  group('UnsupportedPlatformBackend', () {
    const backend = UnsupportedPlatformBackend();

    test('reports itself unsupported with inert reads', () async {
      expect(backend.isSupported, isFalse);
      expect(backend.channel, '');
      expect(await backend.currentVersion(), 0);
      expect(await backend.stagedVersion(), 0);
      expect(await backend.fetchManifest(), isNull);
    });

    test(
      'downloadAndStage surfaces an error rather than pretending to work',
      () {
        expect(
          backend.downloadAndStage(
            const UpdateManifest(version: 1, bundle: 'b.raucb'),
          ),
          emitsError(isA<UnsupportedError>()),
        );
      },
    );

    test('applyAndRestart throws', () {
      expect(backend.applyAndRestart(), throwsUnsupportedError);
    });
  });
}
