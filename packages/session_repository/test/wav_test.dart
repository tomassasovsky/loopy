import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:session_repository/session_repository.dart';

void main() {
  group('WavCodec', () {
    test('writes a valid 32-bit float WAV header', () {
      final samples = Float32List.fromList([0, 0.5, -0.5, 1]);
      final bytes = WavCodec.encodeFloat32(
        samples: samples,
        sampleRate: 48000,
        channels: 2,
      );
      final bd = ByteData.view(bytes.buffer);

      expect(String.fromCharCodes(bytes, 0, 4), 'RIFF');
      expect(String.fromCharCodes(bytes, 8, 12), 'WAVE');
      expect(String.fromCharCodes(bytes, 12, 16), 'fmt ');
      expect(String.fromCharCodes(bytes, 36, 40), 'data');
      expect(bd.getUint16(20, Endian.little), 3); // IEEE float
      expect(bd.getUint16(22, Endian.little), 2); // channels
      expect(bd.getUint32(24, Endian.little), 48000);
      expect(bd.getUint16(34, Endian.little), 32); // bits per sample
      expect(bytes.length, 44 + samples.length * 4);
    });

    test('round-trips samples losslessly', () {
      final samples = Float32List.fromList([0, 0.25, -0.75, 1, -1, 0.123456]);
      final decoded = WavCodec.decodeFloat32(
        WavCodec.encodeFloat32(
          samples: samples,
          sampleRate: 44100,
          channels: 1,
        ),
      );
      expect(decoded.sampleRate, 44100);
      expect(decoded.channels, 1);
      expect(decoded.frames, 6);
      expect(decoded.samples, samples);
    });

    test('rejects non-WAVE bytes', () {
      expect(
        () => WavCodec.decodeFloat32(Uint8List(8)),
        throwsFormatException,
      );
    });
  });
}
