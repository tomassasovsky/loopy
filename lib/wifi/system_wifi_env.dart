import 'dart:io';

import 'package:loopy/common/console_mode.dart';
import 'package:loopy/wifi/wifi_env.dart';

/// Drives NetworkManager through `nmcli`.
///
/// The console runs the app as root (see `loopy-kiosk-launch`), so `nmcli`
/// needs no privilege plumbing — unlike the update helper, which is invoked
/// through pkexec.
///
/// Console-only by construction: on desktop the host OS owns the radio, and a
/// second UI competing with it would be worse than none.
class SystemWifiEnv implements WifiEnv {
  /// Creates a [SystemWifiEnv].
  const SystemWifiEnv({this.nmcli = 'nmcli', this.supported = kConsoleMode});

  /// Path to the `nmcli` binary; overridable for tests.
  final String nmcli;

  /// Whether this build manages Wi-Fi. Defaults to [kConsoleMode].
  final bool supported;

  @override
  bool get isSupported => supported;

  @override
  Future<List<WifiNetwork>> scan() async {
    if (!supported) return const [];
    // `--rescan auto` lets NetworkManager decide whether the cached scan is
    // fresh enough. Forcing a rescan on every open makes the list jump around
    // while the user is trying to tap a row.
    final list = await _run([
      '-t',
      '-f',
      'IN-USE,SSID,SIGNAL,SECURITY',
      'device',
      'wifi',
      'list',
      '--rescan',
      'auto',
    ]);
    if (list == null) return const [];
    final saved = await _run(['-t', '-f', 'NAME', 'connection', 'show']);
    return parseWifiList(
      list,
      savedSsids: saved == null ? const {} : parseSavedConnections(saved),
    );
  }

  @override
  Future<String?> connect({required String ssid, String? password}) async {
    if (!supported) return 'Wi-Fi is not managed on this build';
    // A saved network is brought up by name; `device wifi connect` would
    // demand the password again for one we already hold.
    final args = password == null || password.isEmpty
        ? ['device', 'wifi', 'connect', ssid]
        : ['device', 'wifi', 'connect', ssid, 'password', password];
    return _runForError(args);
  }

  @override
  Future<String?> forget(String ssid) async {
    if (!supported) return 'Wi-Fi is not managed on this build';
    return _runForError(['connection', 'delete', ssid]);
  }

  /// Runs nmcli and returns stdout, or `null` when it could not run at all.
  Future<String?> _run(List<String> args) async {
    try {
      final result = await Process.run(nmcli, args);
      if (result.exitCode != 0) return null;
      return '${result.stdout}';
    } on ProcessException {
      // No nmcli on this image: the feature is simply absent, not broken.
      return null;
    }
  }

  /// Runs nmcli and returns `null` on success, or a message worth showing.
  Future<String?> _runForError(List<String> args) async {
    try {
      final result = await Process.run(nmcli, args);
      if (result.exitCode == 0) return null;
      final stderr = '${result.stderr}'.trim();
      // nmcli's own wording is better than anything invented here — it names
      // the actual reason (bad password, timeout, no such network).
      return stderr.isEmpty ? 'Failed (exit ${result.exitCode})' : stderr;
    } on ProcessException catch (error) {
      return error.message;
    }
  }
}
