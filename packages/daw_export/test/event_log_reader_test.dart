import 'dart:io';
import 'dart:typed_data';

import 'package:daw_export/daw_export.dart';
import 'package:test/test.dart';

/// Writes a minimal `events.log` fixture: the 12-byte header (`PLEV`,
/// version, sample rate) followed by [entries], each a `(frame, code,
/// payload)` triple where `payload` is exactly 16 bytes — mirroring
/// `perf_drain.c`'s own on-disk layout (`docs/design/performance-event-log-
/// format.md`).
void _writeLog(
  String path,
  int sampleRate,
  List<(int frame, int code, List<int> payload)> entries,
) {
  final out = BytesBuilder()..add('PLEV'.codeUnits);
  final version = ByteData(4)..setUint32(0, 1, Endian.little);
  out.add(version.buffer.asUint8List());
  final sr = ByteData(4)..setInt32(0, sampleRate, Endian.little);
  out.add(sr.buffer.asUint8List());

  for (final (frame, code, payload) in entries) {
    final header = ByteData(12)
      ..setUint64(0, frame, Endian.little)
      ..setInt32(8, code, Endian.little);
    out.add(header.buffer.asUint8List());
    final padded = List<int>.filled(16, 0);
    for (var i = 0; i < payload.length && i < 16; i++) {
      padded[i] = payload[i];
    }
    out.add(padded);
  }

  File(path).writeAsBytesSync(out.toBytes());
}

/// Packs a generic `{arg_i, arg_f}` payload (`LE_CMD_SET_VOLUME`/`_MUTE`).
List<int> _generic(int argI, double argF) {
  final b = ByteData(16)
    ..setInt32(0, argI, Endian.little)
    ..setFloat32(4, argF, Endian.little);
  return b.buffer.asUint8List();
}

/// Packs a `lanef` payload (`LE_CMD_SET_LANE_VOLUME`/`_MUTE`):
/// `{channel, lane, value}`.
List<int> _lanef(int channel, int lane, double value) {
  final b = ByteData(16)
    ..setInt32(0, channel, Endian.little)
    ..setInt32(4, lane, Endian.little)
    ..setFloat32(8, value, Endian.little);
  return b.buffer.asUint8List();
}

void main() {
  group('EventLogReader', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('daw_export_log_test_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('returns null when events.log is missing', () {
      expect(EventLogReader.readAll(dir.path), isNull);
    });

    test('returns null when the magic header does not match', () {
      File('${dir.path}/events.log').writeAsBytesSync([1, 2, 3, 4, 5, 6, 7]);
      expect(EventLogReader.readAll(dir.path), isNull);
    });

    test('reads every entry back with its frame, code, and payload', () {
      const codeSetVolume = 7;
      _writeLog(
        '${dir.path}/events.log',
        48000,
        [(0, codeSetVolume, _generic(0, 0.8))],
      );
      final entries = EventLogReader.readAll(dir.path);
      expect(entries, hasLength(1));
      expect(entries!.single.frame, 0);
      expect(entries.single.code, codeSetVolume);
      expect(entries.single.payload.getInt32(0, Endian.little), 0);
      expect(
        entries.single.payload.getFloat32(4, Endian.little),
        closeTo(0.8, 1e-6),
      );
    });

    test(
      'extracts lane-0 volume events from both the generic (track-level) '
      'and explicit-lane commands, ignoring a non-zero explicit lane',
      () {
        const codeSetVolume = 7;
        const codeSetLaneVolume = 28;
        _writeLog('${dir.path}/events.log', 48000, [
          (0, codeSetVolume, _generic(0, 0.5)),
          (100, codeSetLaneVolume, _lanef(0, 0, 0.7)),
          (200, codeSetLaneVolume, _lanef(0, 1, 0.9)), // lane 1: ignored
          (300, codeSetVolume, _generic(1, 0.3)), // channel 1: ignored
        ]);
        final entries = EventLogReader.readAll(dir.path)!;
        final result = EventLogReader.readChannelAutomation(
          entries,
          0,
          48000,
          120,
        );
        expect(result.volume, hasLength(2));
        expect(result.volume[0].value, closeTo(0.5, 1e-6));
        expect(result.volume[1].value, closeTo(0.7, 1e-6));
      },
    );

    test(
      'extracts mute events inverted to Ableton activator semantics '
      '(muted -> 0, unmuted -> 1)',
      () {
        const codeSetMute = 8;
        const codeSetLaneMute = 29;
        _writeLog('${dir.path}/events.log', 48000, [
          (0, codeSetMute, _generic(0, 1)), // muted
          (100, codeSetLaneMute, _lanef(0, 0, 0)), // unmuted
        ]);
        final entries = EventLogReader.readAll(dir.path)!;
        final result = EventLogReader.readChannelAutomation(
          entries,
          0,
          48000,
          120,
        );
        expect(result.mute, hasLength(2));
        expect(result.mute[0].value, 0.0); // muted -> activator off
        expect(result.mute[1].value, 1.0); // unmuted -> activator on
      },
    );

    test('converts frame to beat correctly at a given tempo', () {
      const codeSetVolume = 7;
      const sampleRate = 48000;
      // 1 second in -> at 120 BPM, 1 second == 2 beats.
      _writeLog('${dir.path}/events.log', sampleRate, [
        (sampleRate, codeSetVolume, _generic(0, 0.6)),
      ]);
      final entries = EventLogReader.readAll(dir.path)!;
      final result = EventLogReader.readChannelAutomation(
        entries,
        0,
        sampleRate,
        120,
      );
      expect(result.volume.single.beat, closeTo(2.0, 1e-9));
    });

    test('sorts entries by frame before conversion', () {
      const codeSetVolume = 7;
      _writeLog('${dir.path}/events.log', 48000, [
        (200, codeSetVolume, _generic(0, 0.9)),
        (0, codeSetVolume, _generic(0, 0.1)),
        (100, codeSetVolume, _generic(0, 0.5)),
      ]);
      final entries = EventLogReader.readAll(dir.path)!;
      final result = EventLogReader.readChannelAutomation(
        entries,
        0,
        48000,
        120,
      );
      final values = result.volume.map((b) => b.value).toList();
      expect(values[0], closeTo(0.1, 1e-6));
      expect(values[1], closeTo(0.5, 1e-6));
      expect(values[2], closeTo(0.9, 1e-6));
    });
  });
}
