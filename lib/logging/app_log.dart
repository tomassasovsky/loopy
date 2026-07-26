import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

/// Durable, size-rotated application logfile. On the appliance the directory
/// is `$HOME/log` → `/data/log` (see `loopy-kiosk-launch`). Mirrors every line
/// to `developer.log` / stderr so `journalctl -u loopy.service` still works.
class AppLog {
  AppLog._();

  /// Current log file name inside the init directory.
  static const String fileName = 'loopy.log';

  /// Rotate when the active file reaches this many bytes (~2 MiB).
  static const int maxBytes = 2 * 1024 * 1024;

  /// Keep the active file plus this many rotated siblings (`.1`, `.2`, …).
  static const int rotatedCount = 2;

  static Directory? _directory;
  static File? _file;
  static bool _initialized = false;

  /// Whether [init] has completed successfully.
  static bool get isInitialized => _initialized;

  /// Creates [directory] if needed and opens `loopy.log` for append. Safe to
  /// call more than once (subsequent calls are no-ops).
  static Future<void> init({required Directory directory}) async {
    if (_initialized) return;
    _directory = directory;
    await directory.create(recursive: true);
    _file = File('${directory.path}/$fileName');
    _initialized = true;
  }

  /// Resolves `$HOME/log` (or `%USERPROFILE%\log` on Windows). Falls back to
  /// a temp dir when neither env var is set (tests / odd hosts).
  static Directory defaultDirectory() {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      return Directory('$home/log');
    }
    return Directory('${Directory.systemTemp.path}/loopy-log');
  }

  /// Informational breadcrumb.
  static void info(String message) => _write('I', message);

  /// Non-fatal warning.
  static void warn(String message) => _write('W', message);

  /// Error, optionally with [error] / [stack].
  static void error(
    String message, {
    Object? error,
    StackTrace? stack,
  }) => _write('E', message, error: error, stack: stack);

  static void _write(
    String level,
    String message, {
    Object? error,
    StackTrace? stack,
  }) {
    final stamp = DateTime.now().toUtc().toIso8601String();
    final line = '$stamp $level $message';
    final logLevel = switch (level) {
      'E' => 1000,
      'W' => 900,
      _ => 800,
    };
    developer.log(message, name: 'loopy', level: logLevel);
    // Intentional journal/stderr mirror for the appliance.
    stderr
      ..writeln(line)
      ..write(error == null ? '' : '$error\n')
      ..write(stack == null ? '' : '$stack\n');

    final file = _file;
    if (file == null) return;
    try {
      final text = StringBuffer('$line\n')
        ..write(error == null ? '' : '$error\n')
        ..write(stack == null ? '' : '$stack\n');
      final payload = text.toString();
      final byteLength = utf8.encode(payload).length;
      if (file.existsSync() && file.lengthSync() + byteLength >= maxBytes) {
        _rotateSync();
      }
      (_file ?? file).writeAsStringSync(
        payload,
        mode: FileMode.append,
        flush: true,
      );
    } on Object {
      // Never let logging take down the app.
    }
  }

  /// `loopy.log` → `.1` → `.2` (drop oldest). Next write recreates `loopy.log`.
  static void _rotateSync() {
    final dir = _directory;
    if (dir == null) return;
    final oldest = File('${dir.path}/$fileName.$rotatedCount');
    if (oldest.existsSync()) oldest.deleteSync();
    for (var i = rotatedCount - 1; i >= 1; i--) {
      final from = File('${dir.path}/$fileName.$i');
      if (from.existsSync()) {
        from.renameSync('${dir.path}/$fileName.${i + 1}');
      }
    }
    final current = File('${dir.path}/$fileName');
    if (current.existsSync()) {
      current.renameSync('${dir.path}/$fileName.1');
    }
    _file = File('${dir.path}/$fileName');
  }

  /// Test-only: drop state so the next [init] reopens a fresh sink.
  static void debugReset() {
    _initialized = false;
    _directory = null;
    _file = null;
  }
}
