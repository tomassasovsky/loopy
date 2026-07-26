import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/logging/app_log.dart';

void main() {
  late Directory dir;

  setUp(() async {
    AppLog.debugReset();
    dir = await Directory.systemTemp.createTemp('loopy-app-log-');
    await AppLog.init(directory: dir);
  });

  tearDown(() async {
    AppLog.debugReset();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('info writes a line to loopy.log', () {
    AppLog.info('hello breadcrumb');
    final text = File('${dir.path}/loopy.log').readAsStringSync();
    expect(text, contains(' I hello breadcrumb'));
  });

  test('error appends error and stack', () {
    AppLog.error(
      'boom',
      error: StateError('nope'),
      stack: StackTrace.fromString('stack-here'),
    );
    final text = File('${dir.path}/loopy.log').readAsStringSync();
    expect(text, contains(' E boom'));
    expect(text, contains('Bad state: nope'));
    expect(text, contains('stack-here'));
  });

  test('rotates when the active file exceeds maxBytes', () {
    final file = File('${dir.path}/loopy.log');
    // Seed a file just under the limit, then write past it.
    file.writeAsStringSync('x' * (AppLog.maxBytes - 10));
    AppLog.info('trigger-rotate');
    expect(File('${dir.path}/loopy.log.1').existsSync(), isTrue);
    final active = File('${dir.path}/loopy.log').readAsStringSync();
    expect(active, contains('trigger-rotate'));
    expect(active.contains('xxx'), isFalse);
  });

  test('init is idempotent', () async {
    AppLog.info('first');
    await AppLog.init(directory: dir);
    AppLog.info('second');
    final text = File('${dir.path}/loopy.log').readAsStringSync();
    expect(text, contains('first'));
    expect(text, contains('second'));
  });
}
