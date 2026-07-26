import 'dart:convert';
import 'dart:io';

import 'package:bluetooth_client/src/bluetooth_client.dart';
import 'package:bluetooth_client/src/bluetooth_models.dart';
import 'package:bluetooth_client/src/unsupported_bluetooth_client.dart';

/// Production [BluetoothClient]: shells out to `/usr/bin/loopy-bt-ctl`.
class SystemBluetoothClient implements BluetoothClient {
  /// Creates a [SystemBluetoothClient].
  const SystemBluetoothClient({this.helperPath = '/usr/bin/loopy-bt-ctl'});

  /// Path to the Bluetooth helper.
  final String helperPath;

  @override
  bool get isSupported => File(helperPath).existsSync();

  @override
  Future<BluetoothStatus> status() async {
    if (!isSupported) return BluetoothStatus.unsupported;
    final json = await _runJson(['status']);
    if (json is Map<String, dynamic>) {
      return BluetoothStatus.fromJson(json);
    }
    return BluetoothStatus.unsupported;
  }

  @override
  Future<List<BluetoothDevice>> scan() async {
    if (!isSupported) return const [];
    final json = await _runJson(['scan']);
    if (json is! List) return const [];
    return [
      for (final item in json)
        if (item is Map<String, dynamic>) BluetoothDevice.fromJson(item),
    ];
  }

  @override
  Future<void> setPowered({required bool enabled}) {
    final args = <String>['power', if (enabled) 'on' else 'off'];
    return _run(args);
  }

  @override
  Future<void> setDiscoverable({required bool enabled}) {
    final args = <String>['discoverable', if (enabled) 'on' else 'off'];
    return _run(args);
  }

  @override
  Future<void> setAdvertising({required bool enabled}) {
    final args = <String>['advertise', if (enabled) 'on' else 'off'];
    return _run(args);
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
            ? 'bluetooth helper failed'
            : '${result.stderr}'.trim(),
        result.exitCode,
      );
    }
    return result;
  }
}

/// Factory: real helper on Linux when present, else unsupported.
BluetoothClient createBluetoothClient() {
  if (!Platform.isLinux) return const UnsupportedBluetoothClient();
  const system = SystemBluetoothClient();
  if (!File(system.helperPath).existsSync()) {
    return const UnsupportedBluetoothClient();
  }
  return system;
}
