import 'dart:convert';
import 'dart:io';

import 'package:segno/update/appliance/appliance_env.dart';

/// The production [ApplianceEnv]: real files, HTTP, and the privileged helper.
///
/// The helper (`segno-update-ctl`, shipped by the appliance image) does the
/// RAUC work. On the single-purpose appliance the kiosk app runs as root, so
/// the helper is invoked directly — no pkexec/polkit/setuid. This class is the
/// I/O boundary and is excluded from coverage; the testable logic lives in
/// `AppliancePlatformBackend` over a fake [ApplianceEnv].
class SystemApplianceEnv implements ApplianceEnv {
  /// Creates a [SystemApplianceEnv]. [helperPath] is the update helper.
  const SystemApplianceEnv({this.helperPath = '/usr/bin/segno-update-ctl'});

  /// Path to the update helper (run directly; the appliance app is root).
  final String helperPath;

  @override
  String? readTextSync(String path) {
    try {
      return File(path).readAsStringSync();
    } on IOException {
      return null;
    }
  }

  @override
  void writeTextSync(String path, String contents) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  @override
  bool existsSync(String path) => File(path).existsSync();

  @override
  Future<String?> httpGetText(Uri url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;
      return await response.transform(utf8.decoder).join();
    } on Exception {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Stream<double> stage(String version) => _runHelper(['install', version]);

  @override
  Stream<double> flashPedal() => _runHelper(['flash-pedal']);

  @override
  Future<String?> pedalPending() async {
    try {
      final result = await Process.run(helperPath, const ['pedal-pending']);
      if (result.exitCode != 0) return null;
      final version = '${result.stdout}'.trim();
      return version.isEmpty ? null : version;
    } on Exception {
      // Helper missing / old image: no gate, rather than no app.
      return null;
    }
  }

  /// Runs the privileged helper with [args], republishing its
  /// `PROGRESS <0-100>` lines as `[0, 1]` and throwing with the collected
  /// stderr on a non-zero exit.
  Stream<double> _runHelper(List<String> args) async* {
    final process = await Process.start(helperPath, args);
    final stderrLines = <String>[];
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(stderrLines.add);
    final progress = RegExp(r'^PROGRESS\s+(\d+)');
    await for (final line
        in process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      final match = progress.firstMatch(line);
      if (match != null) {
        yield (int.parse(match.group(1)!) / 100).clamp(0.0, 1.0);
      }
    }
    final code = await process.exitCode;
    await stderrDone;
    if (code != 0) {
      final reason = stderrLines.isEmpty
          ? 'update helper failed'
          : stderrLines.join('\n');
      throw ProcessException(helperPath, args, reason, code);
    }
    yield 1;
  }

  @override
  Future<void> reboot() async {
    final result = await Process.run(helperPath, ['reboot']);
    if (result.exitCode != 0) {
      throw ProcessException(
        helperPath,
        const ['reboot'],
        '${result.stderr}',
        result.exitCode,
      );
    }
  }

  @override
  Future<void> reconcileStaged() async {
    try {
      await Process.run(helperPath, const ['reconcile-staged']);
    } on Exception {
      // Helper missing / old image — leave the marker alone.
    }
  }
}
