import 'package:pub_semver/pub_semver.dart';
import 'package:update_repository/src/platform_update_backend.dart';
import 'package:update_repository/src/update_manifest.dart';

/// App-facing entry point to the update system. Thin orchestration over a
/// [PlatformUpdateBackend]: it owns the "is this actually newer?" policy so the
/// backends stay dumb and the presentation layer stays platform-agnostic.
class UpdateRepository {
  /// Creates an [UpdateRepository] over [backend].
  const UpdateRepository({required PlatformUpdateBackend backend})
    : _backend = backend;

  final PlatformUpdateBackend _backend;

  /// Whether in-app updates are offered on this platform.
  bool get isSupported => _backend.isSupported;

  /// The channel this device follows, for display.
  String get channel => _backend.channel;

  /// The running semantic version ([Version.none] when unknown).
  Future<Version> currentVersion() => _backend.currentVersion();

  /// The version staged and awaiting a restart ([Version.none] if none).
  Future<Version> stagedVersion() => _backend.stagedVersion();

  /// Read-only availability check. Returns the manifest only when it advertises
  /// a version with strictly greater semver precedence than both the running
  /// and any already-staged version; otherwise (up to date, already staged, or
  /// nothing published) `null`.
  ///
  /// Safe to call automatically — it never downloads or installs.
  Future<UpdateManifest?> checkForUpdate() async {
    if (!_backend.isSupported) return null;
    final manifest = await _backend.fetchManifest();
    if (manifest == null) return null;
    final current = await _backend.currentVersion();
    final staged = await _backend.stagedVersion();
    if (manifest.version <= current || manifest.version <= staged) return null;
    return manifest;
  }

  /// Downloads, verifies, and stages [manifest] to the inactive slot, emitting
  /// progress in `[0, 1]`. Opt-in: only call in response to a user action.
  Stream<double> downloadAndStage(UpdateManifest manifest) =>
      _backend.downloadAndStage(manifest);

  /// Restarts into the staged update (reboot on the appliance, relaunch on
  /// desktop). Opt-in: only call in response to a user action.
  Future<void> applyAndRestart() => _backend.applyAndRestart();
}
