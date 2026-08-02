import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/pedal/flashed_firmware.dart';

void main() {
  group('parseFlashedPedalProtocolVersion', () {
    test('reads the protocol field of a well-formed record', () {
      expect(parseFlashedPedalProtocolVersion('0.2.0 3'), 3);
      expect(parseFlashedPedalProtocolVersion('1.0.0-experimental.7 2'), 2);
    });

    test('tolerates trailing newlines and extra spacing', () {
      expect(parseFlashedPedalProtocolVersion('0.2.0   3\n'), 3);
    });

    // Everything below means "learn nothing", which leaves the caller on its
    // v2 safety floor. Guessing here would encode at a version the pedal may
    // not speak.
    test('returns null when nothing was recorded', () {
      expect(parseFlashedPedalProtocolVersion(null), isNull);
      expect(parseFlashedPedalProtocolVersion(''), isNull);
      expect(parseFlashedPedalProtocolVersion('   '), isNull);
    });

    test('returns null for a truncated record (version but no protocol)', () {
      expect(parseFlashedPedalProtocolVersion('0.2.0'), isNull);
      expect(parseFlashedPedalProtocolVersion('0.2.0\n'), isNull);
    });

    test('returns null for a non-numeric protocol field', () {
      expect(parseFlashedPedalProtocolVersion('0.2.0 three'), isNull);
    });

    test("returns null for the flasher's own unknown (0) and negatives", () {
      expect(parseFlashedPedalProtocolVersion('0.2.0 0'), isNull);
      expect(parseFlashedPedalProtocolVersion('0.2.0 -1'), isNull);
    });

    test('reads a future record with extra trailing fields', () {
      // Forward compatibility: a later flasher may append columns, and that
      // must not read as "unknown" on an older app.
      expect(parseFlashedPedalProtocolVersion('0.2.0 3 extra stuff'), 3);
    });
  });

  group('readFlashedPedalProtocolVersion', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('flashed-fw'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('reads the recorded version from disk', () async {
      final path = '${dir.path}/pedal-firmware-version';
      File(path).writeAsStringSync('0.2.0 3\n');

      expect(await readFlashedPedalProtocolVersion(path: path), 3);
    });

    test('returns null when the file does not exist', () async {
      // Every desktop build, and any console that has not flashed yet.
      expect(
        await readFlashedPedalProtocolVersion(path: '${dir.path}/absent'),
        isNull,
      );
    });

    test(
      'returns null rather than throwing when the path is a directory',
      () async {
        expect(await readFlashedPedalProtocolVersion(path: dir.path), isNull);
      },
    );
  });
}
