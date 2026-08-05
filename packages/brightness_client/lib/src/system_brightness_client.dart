import 'dart:convert';
import 'dart:io';

import 'package:brightness_client/src/brightness_client.dart';

/// Production [BrightnessClient]: shells out to `/usr/bin/segno-brightness-ctl`.
class SystemBrightnessClient implements BrightnessClient {
  /// Creates a [SystemBrightnessClient].
  const SystemBrightnessClient({
    this.helperPath = '/usr/bin/segno-brightness-ctl',
  });

  /// Path to the brightness helper.
  final String helperPath;

  bool get _helperPresent => File(helperPath).existsSync();

  @override
  Future<bool> isSupported() async {
    if (!_helperPresent) return false;
    final json = await _runJson(['supported']);
    return json is Map && json['supported'] == true;
  }

  @override
  Future<double> get() async {
    if (!_helperPresent) return 0.8;
    final json = await _runJson(['get']);
    if (json is Map) {
      final pct = json['percent'];
      final n = pct is num ? pct.toDouble() : double.tryParse('$pct') ?? 80;
      return (n / 100).clamp(0.0, 1.0);
    }
    return 0.8;
  }

  @override
  Future<void> set(double value) async {
    if (!_helperPresent) return;
    final pct = (value.clamp(0.0, 1.0) * 100).round();
    await _run(['set', '$pct']);
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
            ? 'brightness helper failed'
            : '${result.stderr}'.trim(),
        result.exitCode,
      );
    }
    return result;
  }
}

/// Factory: real helper on Linux when present, else unsupported.
BrightnessClient createBrightnessClient() {
  if (!Platform.isLinux) return const UnsupportedBrightnessClient();
  const system = SystemBrightnessClient();
  if (!File(system.helperPath).existsSync()) {
    return const UnsupportedBrightnessClient();
  }
  return system;
}
