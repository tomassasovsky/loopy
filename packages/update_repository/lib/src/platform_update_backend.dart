import 'package:update_repository/src/update_manifest.dart';

/// The per-platform half of the update system, behind a single interface so the
/// app-facing `UpdateRepository` and `UpdateCubit` stay platform-agnostic.
///
/// Implementations:
///   * appliance (Raspberry Pi) — reads `/etc/loopy/build-version`, fetches the
///     channel manifest over HTTPS, stages the signed bundle to the inactive
///     RAUC slot via a privileged helper, and reboots to apply;
///   * desktop (macOS/Windows) — drives Sparkle / WinSparkle;
///   * `UnsupportedPlatformBackend` — the inert fallback where in-app updates
///     are not offered (e.g. a generic dev Linux build).
///
/// The backend deals only in raw data and side effects; the newer-than-current
/// decision lives in `UpdateRepository`.
abstract interface class PlatformUpdateBackend {
  /// Whether this platform offers in-app updates at all. When `false`, the UI
  /// hides the update surfaces and the other members are not exercised.
  bool get isSupported;

  /// The channel this device follows (`experimental` / `production`), for
  /// display. Empty when [isSupported] is `false`.
  String get channel;

  /// The running build number. `0` when unknown.
  Future<int> currentVersion();

  /// The build number already staged to the inactive slot and awaiting a
  /// restart to apply, or `0` if nothing is staged.
  Future<int> stagedVersion();

  /// Fetches and parses the channel manifest. Read-only — no download, no
  /// install — so it is safe to call automatically. Returns `null` when the
  /// server is unreachable or publishes nothing parseable.
  Future<UpdateManifest?> fetchManifest();

  /// Downloads [manifest]'s bundle, verifies it, and stages it to the inactive
  /// slot (appliance) or downloads it in the background (desktop). Emits
  /// progress in `[0, 1]`; completes when the update is fully staged. Throws on
  /// verification or transport failure.
  Stream<double> downloadAndStage(UpdateManifest manifest);

  /// Applies the staged update by restarting into it: reboot on the appliance,
  /// relaunch on desktop. Meaningful only after [downloadAndStage] completes.
  Future<void> applyAndRestart();
}
