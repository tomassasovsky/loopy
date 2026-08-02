import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/update/appliance/appliance_env.dart';
import 'package:loopy/update/appliance/appliance_platform_backend.dart';
import 'package:update_repository/update_repository.dart';

class _FakeEnv implements ApplianceEnv {
  _FakeEnv({
    Map<String, String> files = const {},
    this.body,
    this.stageProgress = const [0.5, 1.0],
    this.stageError,
    this.rebootError,
    this.flashError,
  }) : files = Map.of(files);

  final Map<String, String> files;
  final String? body;
  final List<double> stageProgress;
  final Object? stageError;
  final Exception? rebootError;
  final Object? flashError;

  Uri? fetchedUrl;
  String? stagedVersionArg;
  int rebootCalls = 0;
  int flashCalls = 0;

  @override
  String? readTextSync(String path) => files[path];

  @override
  void writeTextSync(String path, String contents) {
    files[path] = contents;
  }

  @override
  bool existsSync(String path) => files.containsKey(path);

  @override
  Future<String?> httpGetText(Uri url) async {
    fetchedUrl = url;
    return body;
  }

  @override
  Stream<double> stage(String version) {
    stagedVersionArg = version;
    if (stageError != null) return Stream.error(stageError!);
    return Stream.fromIterable(stageProgress);
  }

  @override
  Stream<double> flashPedal() {
    flashCalls++;
    if (flashError != null) return Stream.error(flashError!);
    return Stream.fromIterable(const [0.5, 1.0]);
  }

  @override
  Future<void> reboot() async {
    rebootCalls++;
    if (rebootError != null) throw rebootError!;
  }
}

const _version = '/etc/loopy/build-version';
const _channel = '/etc/loopy/update-channel';
const _channelOverride = '/data/loopy/update-channel';
const _staged = '/data/.ota-staged-version';
const _helper = '/usr/bin/loopy-update-ctl';

AppliancePlatformBackend backend(ApplianceEnv env) =>
    AppliancePlatformBackend(env: env);

void main() {
  group('isSupported', () {
    test('true only when both the version file and the helper exist', () {
      expect(
        backend(_FakeEnv(files: {_version: '0.2.0', _helper: ''})).isSupported,
        isTrue,
      );
      expect(
        backend(_FakeEnv(files: {_version: '0.2.0'})).isSupported,
        isFalse,
      );
      expect(backend(_FakeEnv(files: {_helper: ''})).isSupported, isFalse);
      expect(backend(_FakeEnv()).isSupported, isFalse);
    });
  });

  group('channel', () {
    test('reads and trims the baked channel file', () {
      expect(
        backend(_FakeEnv(files: {_channel: 'experimental\n'})).channel,
        'experimental',
      );
    });

    test('defaults to production when unset or empty', () {
      expect(backend(_FakeEnv()).channel, 'production');
      expect(backend(_FakeEnv(files: {_channel: '  '})).channel, 'production');
    });

    test('prefers the /data override over the baked marker', () {
      expect(
        backend(
          _FakeEnv(
            files: {
              _channel: 'production',
              _channelOverride: 'experimental\n',
            },
          ),
        ).channel,
        'experimental',
      );
    });

    test(
      'setChannel writes the override and normalizes unknown values',
      () async {
        final env = _FakeEnv(files: {_channel: 'production'});
        final b = backend(env);

        await b.setChannel('experimental');
        expect(b.channel, 'experimental');
        expect(env.files[_channelOverride], 'experimental\n');

        await b.setChannel('nightly');
        expect(b.channel, 'production');
        expect(env.files[_channelOverride], 'production\n');
      },
    );
  });

  group('version reads', () {
    test(
      'parses the marker files as semver, defaulting to Version.none',
      () async {
        final b = backend(
          _FakeEnv(files: {_version: '0.2.0\n', _staged: '0.3.0'}),
        );
        expect(await b.currentVersion(), Version.parse('0.2.0'));
        expect(await b.stagedVersion(), Version.parse('0.3.0'));
      },
    );

    test('parses a prerelease (experimental) semver', () async {
      final b = backend(_FakeEnv(files: {_version: '0.2.0-experimental.7'}));
      expect(await b.currentVersion(), Version.parse('0.2.0-experimental.7'));
    });

    test('treats missing/garbage as Version.none', () async {
      final b = backend(_FakeEnv(files: {_version: 'x'}));
      expect(await b.currentVersion(), Version.none);
      expect(await b.stagedVersion(), Version.none);
    });
  });

  group('fetchManifest', () {
    test('parses the manifest and hits the per-channel URL', () async {
      final env = _FakeEnv(
        files: {_channel: 'experimental'},
        body: '{"version":"0.2.0","bundle":"b.raucb","sha256":"s"}',
      );

      final manifest = await backend(env).fetchManifest();

      expect(manifest?.version, Version.parse('0.2.0'));
      expect(
        env.fetchedUrl.toString(),
        'https://segno.aquiles.dev/updates/appliance/experimental/manifest.json',
      );
    });

    test('returns null when the server is unreachable', () async {
      expect(await backend(_FakeEnv()).fetchManifest(), isNull);
    });

    test('returns null on malformed or non-object JSON', () async {
      expect(
        await backend(_FakeEnv(body: 'not json')).fetchManifest(),
        isNull,
      );
      expect(await backend(_FakeEnv(body: '[1,2]')).fetchManifest(), isNull);
    });
  });

  group('stage and reboot', () {
    test(
      'downloadAndStage forwards the version string and streams progress',
      () async {
        final env = _FakeEnv(stageProgress: const [0.25, 1.0]);
        final manifest = UpdateManifest(
          version: Version.parse('0.7.0'),
          bundle: 'b.raucb',
        );

        final progress = await backend(env).downloadAndStage(manifest).toList();

        expect(progress, [0.25, 1.0]);
        expect(env.stagedVersionArg, '0.7.0');
      },
    );

    test('downloadAndStage surfaces a helper failure', () {
      final env = _FakeEnv(stageError: Exception('rauc failed'));
      final manifest = UpdateManifest(
        version: Version.parse('0.7.0'),
        bundle: 'b.raucb',
      );
      expect(
        backend(env).downloadAndStage(manifest),
        emitsError(isA<Exception>()),
      );
    });

    test('applyAndRestart calls reboot', () async {
      final env = _FakeEnv();
      await backend(env).applyAndRestart();
      expect(env.rebootCalls, 1);
    });

    test('applyAndRestart surfaces a reboot failure', () {
      final env = _FakeEnv(rebootError: Exception('reboot denied'));
      expect(backend(env).applyAndRestart(), throwsA(isA<Exception>()));
    });
  });

  _pedalFirmwareStagingTests();
}

void _pedalFirmwareStagingTests() {
  const version = '/etc/loopy/build-version';
  const helper = '/usr/bin/loopy-update-ctl';

  UpdateManifest manifest({PedalFirmwareManifest? firmware}) => UpdateManifest(
    version: Version.parse('0.3.0'),
    bundle: 'b.raucb',
    pedalFirmware: firmware,
  );

  PedalFirmwareManifest firmware() => PedalFirmwareManifest(
    version: Version.parse('0.3.0'),
    hex: 'loopy-pedal-0.3.0.hex',
  );

  group('downloadAndStage with pedal firmware', () {
    test('does not flash when the release publishes no firmware', () async {
      final env = _FakeEnv(files: {version: '0.2.0\n', helper: ''});
      final backend = AppliancePlatformBackend(env: env);

      final progress = await backend.downloadAndStage(manifest()).toList();

      expect(env.flashCalls, 0);
      expect(progress.last, 1.0);
    });

    test('flashes after staging when firmware is published', () async {
      final env = _FakeEnv(files: {version: '0.2.0\n', helper: ''});
      final backend = AppliancePlatformBackend(env: env);

      final progress = await backend
          .downloadAndStage(manifest(firmware: firmware()))
          .toList();

      expect(env.stagedVersionArg, '0.3.0');
      expect(env.flashCalls, 1);
      // One user gesture, one monotonic bar: the OS takes 0..0.9 and the
      // firmware the tail, rather than the bar resetting for a second phase.
      expect(progress, orderedEquals(<double>[...progress]..sort()));
      expect(progress.last, 1.0);
      expect(progress.any((p) => p > 0 && p <= 0.9), isTrue);
    });

    test('a firmware failure does not fail the staged OS update', () async {
      // The bundle is already staged by the time the flash runs, so throwing
      // would push the user to redo a ~100 MB download for a pedal that can be
      // reflashed on its own.
      final env = _FakeEnv(
        files: {version: '0.2.0\n', helper: ''},
        flashError: Exception('avrdude failed'),
      );
      final backend = AppliancePlatformBackend(env: env);

      final progress = await backend
          .downloadAndStage(manifest(firmware: firmware()))
          .toList();

      expect(env.flashCalls, 1);
      expect(progress.last, 1.0);
    });

    test('a staging failure still surfaces', () async {
      // Only the firmware half is forgiven; the OS half must still report.
      final env = _FakeEnv(
        files: {version: '0.2.0\n', helper: ''},
        stageError: Exception('rauc failed'),
      );
      final backend = AppliancePlatformBackend(env: env);

      expect(
        backend.downloadAndStage(manifest(firmware: firmware())).toList(),
        throwsException,
      );
    });
  });
}
