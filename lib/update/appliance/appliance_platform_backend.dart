import 'dart:convert';
import 'dart:developer';

import 'package:loopy/update/appliance/appliance_env.dart';
import 'package:loopy/update/appliance/system_appliance_env.dart';
import 'package:update_repository/update_repository.dart';

/// The Raspberry Pi appliance update backend. Reads the running semantic
/// version and channel from marker files, fetches the channel manifest over
/// HTTPS, and delegates the privileged download/stage and reboot to the
/// `loopy-update-ctl` helper (via the injected [ApplianceEnv]).
///
/// Channel resolution (same order as the shell helpers):
///   1. [channelOverrideFile] on `/data` (user toggle; survives OS updates)
///   2. [channelFile] baked into the image (`/etc/loopy/update-channel`)
///   3. `production`
///
/// [isSupported] additionally requires the helper to be present, so on a build
/// that hasn't shipped it the update UI stays hidden rather than offering a
/// stage/reboot that would fail.
class AppliancePlatformBackend implements PlatformUpdateBackend {
  /// Creates an [AppliancePlatformBackend]. All paths and the base URL are
  /// overridable for tests; [env] defaults to the real [SystemApplianceEnv].
  AppliancePlatformBackend({
    ApplianceEnv? env,
    this.baseUrl = 'https://segno.aquiles.dev/updates/appliance',
    this.versionFile = '/etc/loopy/build-version',
    this.channelFile = '/etc/loopy/update-channel',
    this.channelOverrideFile = '/data/loopy/update-channel',
    this.stagedFile = '/data/.ota-staged-version',
    this.helperPath = '/usr/bin/loopy-update-ctl',
  }) : _env = env ?? const SystemApplianceEnv();

  final ApplianceEnv _env;

  /// Base URL of the per-channel update tree (`<baseUrl>/<channel>/…`).
  final String baseUrl;

  /// Path to the running semantic version, baked by CI.
  final String versionFile;

  /// Path to the image-baked channel (`experimental` / `production`).
  final String channelFile;

  /// Writable channel override (Settings toggle). Survives A/B OS updates.
  final String channelOverrideFile;

  /// Path (on `/data`, surviving OS updates) to the staged semantic version.
  final String stagedFile;

  /// Path to the privileged update helper; its presence gates [isSupported].
  final String helperPath;

  @override
  bool get isSupported =>
      _env.existsSync(versionFile) && _env.existsSync(helperPath);

  @override
  String get channel {
    final override = _env.readTextSync(channelOverrideFile)?.trim();
    if (override != null && override.isNotEmpty) {
      return normalizeUpdateChannel(override);
    }
    final baked = _env.readTextSync(channelFile)?.trim();
    if (baked == null || baked.isEmpty) return 'production';
    return normalizeUpdateChannel(baked);
  }

  @override
  Future<void> setChannel(String channel) async {
    final normalized = normalizeUpdateChannel(channel);
    _env.writeTextSync(channelOverrideFile, '$normalized\n');
  }

  @override
  Future<Version> currentVersion() async => _readVersion(versionFile);

  @override
  Future<Version> stagedVersion() async {
    // Drop a staged marker left behind by a failed tryboot / rollback so
    // Check Now can re-offer the published build.
    await _env.reconcileStaged();
    return _readVersion(stagedFile);
  }

  Version _readVersion(String path) {
    final text = _env.readTextSync(path)?.trim();
    if (text == null || text.isEmpty) return Version.none;
    try {
      return Version.parse(text);
    } on FormatException {
      return Version.none;
    }
  }

  @override
  Future<UpdateManifest?> fetchManifest() async {
    final body = await _env.httpGetText(
      Uri.parse('$baseUrl/$channel/manifest.json'),
    );
    if (body == null) return null;
    try {
      final json = jsonDecode(body);
      return json is Map<String, dynamic>
          ? UpdateManifest.fromJson(json)
          : null;
    } on FormatException {
      return null;
    }
  }

  /// Stages the OS bundle and, when the release publishes pedal firmware,
  /// flashes it in the same action — so "update available" and "restart to
  /// apply" cover both artifacts as one user gesture rather than two.
  ///
  /// The OS bundle takes the first 90% of the progress band and the firmware
  /// the last 10%, which is roughly their relative cost (a ~100 MB signed
  /// bundle against a 32 KB `.hex`).
  ///
  /// **A firmware failure does not fail the update.** By the time it runs, the
  /// bundle is staged and the helper has written the staged marker, so the
  /// pedal is the non-essential half: throwing here would report the whole
  /// update as failed and push the user to re-run a ~100 MB download for a
  /// pedal that can be reflashed on its own. The helper leaves its failure
  /// marker behind either way.
  @override
  Stream<double> downloadAndStage(UpdateManifest manifest) async* {
    final firmware = manifest.pedalFirmware;
    if (firmware == null) {
      yield* _env.stage(manifest.version.toString());
      return;
    }

    await for (final progress in _env.stage(manifest.version.toString())) {
      yield (progress * 0.9).clamp(0.0, 0.9);
    }
    try {
      await for (final progress in _env.flashPedal()) {
        yield (0.9 + progress * 0.1).clamp(0.9, 1.0);
      }
    } on Exception catch (error) {
      log('pedal firmware flash failed (OS update stays staged): $error');
    }
    yield 1;
  }

  @override
  Future<void> applyAndRestart() => _env.reboot();
}
