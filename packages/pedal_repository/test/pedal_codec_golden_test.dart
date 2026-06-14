import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

import 'helpers/golden_frames.dart';

void main() {
  group('golden SysEx fixtures', () {
    // These committed bytes are the shared contract with the firmware. If this
    // test fails after an intentional protocol change, regenerate them with
    // `dart run tool/generate_golden_fixtures.dart` and review the diff.
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
  });
}
