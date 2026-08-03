/// The operating-system boundary the appliance update backend depends on,
/// injected so the backend is fully testable without real files, network, or a
/// device. The production implementation is `SystemApplianceEnv`.
abstract interface class ApplianceEnv {
  /// Reads [path] synchronously, or `null` if absent/unreadable. Used for the
  /// tiny local marker files (`build-version`, `update-channel`, the staged
  /// marker) — sync keeps `PlatformUpdateBackend.channel` (a sync getter) and
  /// the support check simple.
  String? readTextSync(String path);

  /// Creates parent directories as needed and writes [contents] to [path].
  /// Used for the user-selected channel override on `/data`.
  void writeTextSync(String path, String contents);

  /// Whether [path] exists.
  bool existsSync(String path);

  /// GETs [url] and returns the response body, or `null` on any failure
  /// (non-200, transport error). Never throws.
  Future<String?> httpGetText(Uri url);

  /// Runs the privileged helper to download + verify + stage semver [version]
  /// (e.g. `"0.2.0"` or `"0.2.0-experimental.7"`) to the inactive slot,
  /// emitting progress in `[0, 1]`. Throws if the helper fails.
  Stream<double> stage(String version);

  /// Runs the privileged helper to reboot into the staged slot. Throws on
  /// failure.
  Future<void> reboot();

  /// Clears a staged-version marker that cannot be applied (failed tryboot /
  /// already running). No-op when the helper is absent. Never throws.
  Future<void> reconcileStaged();
}
