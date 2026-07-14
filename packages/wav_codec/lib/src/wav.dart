import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Decoded contents of a WAV file: interleaved [samples] plus the format.
@immutable
class WavData {
  /// Creates a [WavData].
  const WavData({
    required this.samples,
    required this.sampleRate,
    required this.channels,
  });

  /// Interleaved PCM samples in `-1..1`.
  final Float32List samples;

  /// Sample rate in Hz.
  final int sampleRate;

  /// Number of interleaved channels.
  final int channels;

  /// Frames (samples per channel).
  int get frames => channels > 0 ? samples.length ~/ channels : 0;
}

/// Minimal 32-bit IEEE-float WAV codec — the lossless format Loopy stores its
/// loop stems and mixdowns in. Bytes are written/read little-endian regardless
/// of host endianness, so files are portable across desktop targets.
abstract final class WavCodec {
  static const int _headerBytes = 44;

  // Largest data-chunk byte count for which the RIFF chunk-size field
  // (36 + dataBytes) still fits in an unsigned 32-bit int. Beyond this,
  // ByteData.setUint32 would silently wrap instead of throwing.
  static const int _maxDataBytes = 0xFFFFFFFF - 36;

  /// Throws [ArgumentError] if [dataBytes] would overflow the WAV header's
  /// 32-bit chunk-size fields. Exposed (`@visibleForTesting`) so the exact
  /// boundary can be tested without allocating a ~4 GiB sample buffer.
  @visibleForTesting
  static void checkDataSize(int dataBytes) {
    if (dataBytes > _maxDataBytes) {
      throw ArgumentError(
        'WAV data size of $dataBytes bytes (from `samples`) exceeds the '
        '32-bit RIFF/data chunk-size limit of $_maxDataBytes bytes',
      );
    }
  }

  /// Encodes interleaved [samples] as a 32-bit float WAV byte stream.
  ///
  /// Throws [ArgumentError] if [samples] is large enough that the WAV
  /// header's 32-bit chunk-size fields would overflow (see [checkDataSize]).
  static Uint8List encodeFloat32({
    required Float32List samples,
    required int sampleRate,
    required int channels,
  }) {
    final dataBytes = samples.length * 4;
    checkDataSize(dataBytes);
    final out = Uint8List(_headerBytes + dataBytes);
    final bd = ByteData.view(out.buffer);

    _writeTag(out, 0, 'RIFF');
    bd.setUint32(4, 36 + dataBytes, Endian.little);
    _writeTag(out, 8, 'WAVE');

    _writeTag(out, 12, 'fmt ');
    bd
      ..setUint32(16, 16, Endian.little) // PCM fmt chunk size
      ..setUint16(20, 3, Endian.little) // 3 = IEEE float
      ..setUint16(22, channels, Endian.little)
      ..setUint32(24, sampleRate, Endian.little)
      ..setUint32(28, sampleRate * channels * 4, Endian.little) // byte rate
      ..setUint16(32, channels * 4, Endian.little) // block align
      ..setUint16(34, 32, Endian.little); // bits per sample

    _writeTag(out, 36, 'data');
    bd.setUint32(40, dataBytes, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      bd.setFloat32(_headerBytes + i * 4, samples[i], Endian.little);
    }
    return out;
  }

  /// Decodes a 32-bit float WAV byte stream. Throws [FormatException] for a
  /// malformed file or an unsupported (non 32-bit-float) format.
  static WavData decodeFloat32(Uint8List bytes) {
    final bd = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.length,
    );
    if (bytes.length < 12 ||
        _readTag(bytes, 0) != 'RIFF' ||
        _readTag(bytes, 8) != 'WAVE') {
      throw const FormatException('not a WAVE file');
    }

    int? format;
    int? channels;
    int? sampleRate;
    int? bits;
    int? dataOffset;
    int? dataSize;
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final tag = _readTag(bytes, offset);
      final size = bd.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (tag == 'fmt ' && body + 16 <= bytes.length) {
        format = bd.getUint16(body, Endian.little);
        channels = bd.getUint16(body + 2, Endian.little);
        sampleRate = bd.getUint32(body + 4, Endian.little);
        bits = bd.getUint16(body + 14, Endian.little);
      } else if (tag == 'data') {
        dataOffset = body;
        dataSize = size;
      }
      offset = body + size + (size.isOdd ? 1 : 0); // chunks are word-aligned
    }

    if (format != 3 ||
        bits != 32 ||
        channels == null ||
        sampleRate == null ||
        dataOffset == null ||
        dataSize == null) {
      throw const FormatException('unsupported WAV (expected 32-bit float)');
    }

    final count = dataSize ~/ 4;
    final samples = Float32List(count);
    for (var i = 0; i < count; i++) {
      samples[i] = bd.getFloat32(dataOffset + i * 4, Endian.little);
    }
    return WavData(
      samples: samples,
      sampleRate: sampleRate,
      channels: channels,
    );
  }

  static void _writeTag(Uint8List out, int offset, String tag) {
    for (var i = 0; i < 4; i++) {
      out[offset + i] = tag.codeUnitAt(i);
    }
  }

  static String _readTag(Uint8List bytes, int offset) {
    return String.fromCharCodes(bytes, offset, offset + 4);
  }
}
