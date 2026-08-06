import 'dart:convert';
import 'dart:io';

import 'package:wifi_client/src/fake_wifi_client.dart';
import 'package:wifi_client/src/unsupported_wifi_client.dart';
import 'package:wifi_client/src/wifi_client.dart';
import 'package:wifi_client/src/wifi_models.dart';

/// Production [WifiClient]: shells out to `/usr/bin/segno-wifi-ctl`.
class SystemWifiClient implements WifiClient {
  /// Creates a [SystemWifiClient].
  const SystemWifiClient({this.helperPath = '/usr/bin/segno-wifi-ctl'});

  /// Path to the WiFi helper.
  final String helperPath;

  @override
  bool get isSupported => File(helperPath).existsSync();

  @override
  Future<WifiStatus> status() async {
    if (!isSupported) return WifiStatus.unsupported;
    final json = await _runJson(['status']);
    if (json is Map<String, dynamic>) {
      return WifiStatus.fromJson(json);
    }
    return WifiStatus.unsupported;
  }

  @override
  Future<List<WifiNetwork>> scan() async {
    if (!isSupported) return const [];
    final json = await _runJson(['scan']);
    if (json is! List) return const [];
    return [
      for (final item in json)
        if (item is Map<String, dynamic>) WifiNetwork.fromJson(item),
    ];
  }

  @override
  Future<void> connect(String ssid, {String? psk}) async {
    final args = ['connect', ssid];
    if (psk != null && psk.isNotEmpty) args.add(psk);
    await _run(args);
  }

  @override
  Future<void> disconnect() => _run(const ['disconnect']);

  @override
  Future<void> forget(String ssid) => _run(['forget', ssid]);

  @override
  Future<void> setEnabled({required bool enabled}) {
    return _run(['radio', if (enabled) 'on' else 'off']);
  }

  Future<Object?> _runJson(List<String> args) async {
    final result = await _run(args);
    final text = result.stdout.toString().trim();
    if (text.isEmpty) return null;
    return jsonDecode(text);
  }

  Future<ProcessResult> _run(List<String> args) async {
    final result = await Process.run(helperPath, args);
    if (result.exitCode != 0) {
      throw ProcessException(
        helperPath,
        args,
        '${result.stderr}'.trim().isEmpty
            ? 'wifi helper failed'
            : '${result.stderr}'.trim(),
        result.exitCode,
      );
    }
    return result;
  }
}

/// Whether `--dart-define=SEGNO_FAKE_RADIOS=true` swapped the radios for
/// in-memory stacks.
///
/// Read here rather than at a call site so **every** entry point picks it up
/// with no app wiring change, and read *before* the platform test so the fake
/// is reachable on the desktop — which is the whole point, since both radios
/// are Linux-only appliance helpers and the domain with the richest
/// interaction is otherwise the one surface that cannot be exercised while
/// building it.
const kFakeRadios = bool.fromEnvironment('SEGNO_FAKE_RADIOS');

/// Factory: fake stack when [kFakeRadios], else the real helper on Linux when
/// present, else unsupported.
WifiClient createWifiClient() {
  if (kFakeRadios) return FakeWifiClient();
  if (!Platform.isLinux) return const UnsupportedWifiClient();
  const system = SystemWifiClient();
  if (!File(system.helperPath).existsSync()) {
    return const UnsupportedWifiClient();
  }
  return system;
}
