import 'package:flutter_test/flutter_test.dart';
import 'package:segno/update/appliance/appliance_env.dart';
import 'package:segno/update/appliance/appliance_platform_backend.dart';
import 'package:update_repository/update_repository.dart';

class _FakeEnv implements ApplianceEnv {
  _FakeEnv({
    Map<String, String> files = const {},
    this.body,
    this.stageProgress = const [0.5, 1.0],
    this.stageError,
    this.rebootError,
  }) : files = Map.of(files);

  final Map<String, String> files;
  final String? body;
  final List<double> stageProgress;
  final Object? stageError;
  final Exception? rebootError;

  Uri? fetchedUrl;
  String? stagedVersionArg;
  int rebootCalls = 0;

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

  String? pendingVersion;
  int flashCalls = 0;

  @override
  Future<String?> pedalPending() async => pendingVersion;

  @override
  Stream<double> flashPedal() {
    flashCalls++;
    return Stream.fromIterable(const [0.5, 1.0]);
  }

  @override
  Stream<double> stage(String version) {
    stagedVersionArg = version;
    if (stageError != null) return Stream.error(stageError!);
    return Stream.fromIterable(stageProgress);
  }

  @override
  Future<void> reboot() async {
    rebootCalls++;
    if (rebootError != null) throw rebootError!;
  }

  int reconcileCalls = 0;

  @override
  Future<void> reconcileStaged() async {
    reconcileCalls++;
  }
}

const _version = '/etc/segno/build-version';
const _channel = '/etc/segno/update-channel';
const _channelOverride = '/data/segno/update-channel';
const _staged = '/data/.ota-staged-version';
const _helper = '/usr/bin/segno-update-ctl';

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
        final env = _FakeEnv(files: {_version: '0.2.0\n', _staged: '0.3.0'});
        final b = backend(env);
        expect(await b.currentVersion(), Version.parse('0.2.0'));
        expect(await b.stagedVersion(), Version.parse('0.3.0'));
        expect(env.reconcileCalls, 1);
      },
    );

    test('stagedVersion reconciles before reading the marker', () async {
      final env = _FakeEnv(files: {_staged: '0.3.0'});
      await backend(env).stagedVersion();
      expect(env.reconcileCalls, 1);
    });

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
  const version = '/etc/segno/build-version';
  const helper = '/usr/bin/segno-update-ctl';

  UpdateManifest manifest({PedalFirmwareManifest? firmware}) => UpdateManifest(
    version: Version.parse('0.3.0'),
    bundle: 'b.raucb',
    pedalFirmware: firmware,
  );

  PedalFirmwareManifest firmware() => PedalFirmwareManifest(
    version: Version.parse('0.3.0'),
    hex: 'segno-pedal-0.3.0.hex',
  );

  group('downloadAndStage with pedal firmware', () {
    // Staging runs inside the image being replaced, so a flash started here
    // would run the OUTGOING flasher — which is why a flash-pedal fix could
    // never apply on the update carrying it (#444). The published firmware is
    // now flashed after the reboot by segno-pedal-flash.service, so a manifest
    // that advertises firmware must stage exactly like one that does not.
    test('stages identically whether or not firmware is published', () async {
      final withFirmware = _FakeEnv(files: {version: '0.2.0\n', helper: ''});
      final without = _FakeEnv(files: {version: '0.2.0\n', helper: ''});

      final a = await AppliancePlatformBackend(
        env: withFirmware,
      ).downloadAndStage(manifest(firmware: firmware())).toList();
      final b = await AppliancePlatformBackend(
        env: without,
      ).downloadAndStage(manifest()).toList();

      expect(a, b);
      expect(withFirmware.stagedVersionArg, '0.3.0');
    });

    test('a staging failure surfaces', () async {
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
