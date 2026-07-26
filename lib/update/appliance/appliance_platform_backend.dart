import 'dart:convert';

import 'package:loopy/update/appliance/appliance_env.dart';
import 'package:loopy/update/appliance/system_appliance_env.dart';
import 'package:update_repository/update_repository.dart';

/// The Raspberry Pi appliance update backend. Reads the running semantic
/// version and channel from the baked-in marker files, fetches the channel
/// manifest over HTTPS, and delegates the privileged download/stage and
/// reboot to the `loopy-update-ctl` helper (via the injected [ApplianceEnv]).
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
    this.stagedFile = '/data/.ota-staged-version',
    this.helperPath = '/usr/bin/loopy-update-ctl',
  }) : _env = env ?? const SystemApplianceEnv();

  final ApplianceEnv _env;

  /// Base URL of the per-channel update tree (`<baseUrl>/<channel>/…`).
  final String baseUrl;

  /// Path to the running semantic version, baked by CI.
  final String versionFile;

  /// Path to the pinned channel (`experimental` / `production`).
  final String channelFile;

  /// Path (on `/data`, surviving OS updates) to the staged semantic version.
  final String stagedFile;

  /// Path to the privileged update helper; its presence gates [isSupported].
  final String helperPath;

  @override
  bool get isSupported =>
      _env.existsSync(versionFile) && _env.existsSync(helperPath);

  @override
  String get channel {
    final value = _env.readTextSync(channelFile)?.trim();
    return (value == null || value.isEmpty) ? 'production' : value;
  }

  @override
  Future<Version> currentVersion() async => _readVersion(versionFile);

  @override
  Future<Version> stagedVersion() async => _readVersion(stagedFile);

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

  @override
  Stream<double> downloadAndStage(UpdateManifest manifest) =>
      _env.stage(manifest.version.toString());

  @override
  Future<void> applyAndRestart() => _env.reboot();
}
