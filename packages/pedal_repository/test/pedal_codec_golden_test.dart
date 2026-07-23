import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

import 'helpers/golden_frames.dart';

void main() {
  group('golden SysEx fixtures', () {
    // These committed bytes are the shared contract with the firmware. If this
    // test fails after an intentional protocol change, regenerate them with
    // `flutter test tool/generate_golden_fixtures.dart` (plain `dart run`
    // fails: the package transitively imports `dart:ui` via `flutter`, which
    // only resolves under the Flutter test embedder) and review the diff.
    for (final entry in goldenFrames().entries) {
      final name = entry.key;
      final frame = entry.value;

      test('$name encodes to its committed bytes', () {
        final file = File('test/fixtures/$name.syx');
        expect(
          file.existsSync(),
          isTrue,
          reason: 'missing fixture test/fixtures/$name.syx',
        );
        final golden = file.readAsBytesSync();
        expect(PedalCodec.encodeFrame(frame), golden);
      });

      test('$name decodes back from its committed bytes', () {
        final golden = File('test/fixtures/$name.syx').readAsBytesSync();
        expect(PedalCodec.decodeFrame(golden), frame);
      });
    }

    // D11: fixtures pinned at an explicit (non-default) protocol version —
    // see explicitVersionGoldenFrames's doc comment.
    for (final entry in explicitVersionGoldenFrames().entries) {
      final name = entry.key;
      final frame = entry.value.frame;
      final version = entry.value.version;

      test('$name encodes to its committed bytes at its pinned version', () {
        final file = File('test/fixtures/$name.syx');
        expect(
          file.existsSync(),
          isTrue,
          reason: 'missing fixture test/fixtures/$name.syx',
        );
        final golden = file.readAsBytesSync();
        expect(PedalCodec.encodeFrame(frame, targetVersion: version), golden);
      });

      test('$name decodes back from its committed bytes', () {
        final golden = File('test/fixtures/$name.syx').readAsBytesSync();
        expect(PedalCodec.decodeFrame(golden), frame);
      });
    }
  });
}
