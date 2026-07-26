import 'package:pub_semver/pub_semver.dart';
import 'package:update_repository/src/platform_update_backend.dart';
import 'package:update_repository/src/update_manifest.dart';

/// The inert backend for platforms that do not offer in-app updates (a generic
/// dev Linux build, tests, or any host without an appliance/desktop backend
/// wired up). [isSupported] is `false`, so the UI hides its update surfaces;
/// the action members throw if ever called, since they must not be reachable.
class UnsupportedPlatformBackend implements PlatformUpdateBackend {
  /// Creates an [UnsupportedPlatformBackend].
  const UnsupportedPlatformBackend();

  @override
  bool get isSupported => false;

  @override
  String get channel => '';

  @override
  Future<Version> currentVersion() async => Version.none;

  @override
  Future<Version> stagedVersion() async => Version.none;

  @override
  Future<UpdateManifest?> fetchManifest() async => null;

  @override
  Stream<double> downloadAndStage(UpdateManifest manifest) =>
      Stream<double>.error(
        UnsupportedError('in-app updates are not supported on this platform'),
      );

  @override
  Future<void> applyAndRestart() async =>
      throw UnsupportedError('in-app updates are unsupported on this platform');
}
