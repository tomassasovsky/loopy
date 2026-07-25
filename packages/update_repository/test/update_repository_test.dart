import 'package:flutter_test/flutter_test.dart';
import 'package:update_repository/update_repository.dart';

/// A configurable in-memory backend for exercising [UpdateRepository]'s policy.
class _FakeBackend implements PlatformUpdateBackend {
  _FakeBackend({
    this.isSupported = true,
    this.channel = 'experimental',
    this.current = 1,
    this.staged = 0,
    this.manifest,
  });

  @override
  bool isSupported;
  @override
  String channel;
  int current;
  int staged;
  UpdateManifest? manifest;

  int fetchCount = 0;
  UpdateManifest? stagedArg;
  int applyCount = 0;

  @override
  Future<int> currentVersion() async => current;

  @override
  Future<int> stagedVersion() async => staged;

  @override
  Future<UpdateManifest?> fetchManifest() async {
    fetchCount++;
    return manifest;
  }

  @override
  Stream<double> downloadAndStage(UpdateManifest manifest) async* {
    stagedArg = manifest;
    yield 0.5;
    yield 1;
  }

  @override
  Future<void> applyAndRestart() async => applyCount++;
}

UpdateManifest _manifest(int version) =>
    UpdateManifest(version: version, bundle: 'b$version.raucb', sha256: 's');

void main() {
  group('UpdateRepository.checkForUpdate', () {
    test(
      'returns the manifest when strictly newer than current and staged',
      () async {
        final backend = _FakeBackend(manifest: _manifest(2));
        final repo = UpdateRepository(backend: backend);

        expect(await repo.checkForUpdate(), _manifest(2));
        expect(backend.fetchCount, 1);
      },
    );

    test(
      'returns null when the published build is not newer than current',
      () async {
        final repo = UpdateRepository(
          backend: _FakeBackend(current: 2, manifest: _manifest(2)),
        );
        expect(await repo.checkForUpdate(), isNull);
      },
    );

    test('returns null when the published build is already staged', () async {
      final repo = UpdateRepository(
        backend: _FakeBackend(staged: 2, manifest: _manifest(2)),
      );
      expect(await repo.checkForUpdate(), isNull);
    });

    test('returns null when nothing is published', () async {
      final repo = UpdateRepository(backend: _FakeBackend());
      expect(await repo.checkForUpdate(), isNull);
    });

    test(
      'returns null (and never fetches) on an unsupported platform',
      () async {
        final backend = _FakeBackend(
          isSupported: false,
          manifest: _manifest(9),
        );
        final repo = UpdateRepository(backend: backend);

        expect(await repo.checkForUpdate(), isNull);
        expect(backend.fetchCount, 0);
      },
    );
  });

  group('UpdateRepository delegation', () {
    test('exposes backend identity/version members', () async {
      final backend = _FakeBackend(
        channel: 'production',
        current: 5,
        staged: 6,
      );
      final repo = UpdateRepository(backend: backend);

      expect(repo.isSupported, isTrue);
      expect(repo.channel, 'production');
      expect(await repo.currentVersion(), 5);
      expect(await repo.stagedVersion(), 6);
    });

    test(
      'downloadAndStage forwards the manifest and streams progress',
      () async {
        final backend = _FakeBackend();
        final repo = UpdateRepository(backend: backend);

        final progress = await repo.downloadAndStage(_manifest(2)).toList();

        expect(progress, [0.5, 1.0]);
        expect(backend.stagedArg, _manifest(2));
      },
    );

    test('applyAndRestart forwards to the backend', () async {
      final backend = _FakeBackend();
      await UpdateRepository(backend: backend).applyAndRestart();
      expect(backend.applyCount, 1);
    });
  });
}
