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
    final path = '${dir.path}/loopy.log';
    // Seed past the threshold so the next write rotates.
    File(path).writeAsStringSync('x' * AppLog.maxBytes);
    AppLog.info('trigger-rotate');
    expect(File('${dir.path}/loopy.log.1').existsSync(), isTrue);
    final active = File(path).readAsStringSync();
    expect(
      active,
      allOf(contains('trigger-rotate'), isNot(contains('xxx'))),
    );
  });

  test('drops the oldest rotated sibling', () {
    final active = File('${dir.path}/loopy.log');
    final one = File('${dir.path}/loopy.log.1');
    final two = File('${dir.path}/loopy.log.2');
    active.writeAsStringSync('current');
    one.writeAsStringSync('one');
    two.writeAsStringSync('two');
    // Force a rotate on the next write.
    active.writeAsStringSync('x' * AppLog.maxBytes);
    AppLog.info('newest');
    expect(two.readAsStringSync(), 'one');
    expect(active.readAsStringSync(), contains('newest'));
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
