import 'package:flutter_test/flutter_test.dart';
import 'package:update_repository/update_repository.dart';

void main() {
  group('UnsupportedPlatformBackend', () {
    const backend = UnsupportedPlatformBackend();

    test('reports itself unsupported with inert reads', () async {
      expect(backend.isSupported, isFalse);
      expect(backend.channel, '');
      expect(await backend.currentVersion(), Version.none);
      expect(await backend.stagedVersion(), Version.none);
      expect(await backend.fetchManifest(), isNull);
    });

    test(
      'downloadAndStage surfaces an error rather than pretending to work',
      () {
        expect(
          backend.downloadAndStage(
            UpdateManifest(version: Version(0, 1, 0), bundle: 'b.raucb'),
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
