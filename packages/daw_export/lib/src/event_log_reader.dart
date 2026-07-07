import 'dart:io';
import 'dart:typed_data';

import 'package:daw_export/src/daw_project.dart';

/// Reads `events.log`
/// (`docs/design/performance-event-log-format.md`) directly — a
/// fixed-width binary format, parsed here with no dependency on
/// `loopy_engine` (own-input-model rule, same as `DawManifestReader`'s
/// `performance.json` reading). Every field offset below mirrors that
/// document's entry layout exactly.
abstract final class EventLogReader {
  static const int _headerBytes = 12;
  static const int _entryBytes = 28;

  // Values from perf_log_ring.h / loopy_engine_api.h's audited command
  // table — never imported (this package has no loopy_engine dependency),
  // reproduced verbatim as this reader's own constants.
  static const int _codeSetVolume = 7;
  static const int _codeSetMute = 8;
  static const int _codeSetLaneVolume = 28;
  static const int _codeSetLaneMute = 29;

  /// Reads `<captureDir>/events.log` and returns every entry in file order
  /// (already frame-monotonic *within* each of the two producer streams,
  /// per the format doc — not globally sorted; callers that need one merged
  /// timeline, like [readChannelAutomation], sort themselves), or `null` if
  /// the file is missing, too short for even a header, or the header's
  /// magic doesn't match (a graceful no-op, same convention as
  /// `DawManifestReader.read`'s missing/corrupt manifest handling).
  static List<RawLogEntry>? readAll(String captureDir) {
    final file = File('$captureDir/events.log');
    if (!file.existsSync()) return null;
    final bytes = file.readAsBytesSync();
    if (bytes.length < _headerBytes) return null;

    final header = ByteData.sublistView(bytes, 0, _headerBytes);
    final magic = String.fromCharCodes(bytes.sublist(0, 4));
    if (magic != 'PLEV') return null;
    final sampleRate = header.getInt32(8, Endian.little);
    if (sampleRate <= 0) return null;

    final entries = <RawLogEntry>[];
    var offset = _headerBytes;
    while (offset + _entryBytes <= bytes.length) {
      final entry = ByteData.sublistView(bytes, offset, offset + _entryBytes);
      entries.add(
        RawLogEntry(
          frame: entry.getUint64(0, Endian.little),
          code: entry.getInt32(8, Endian.little),
          payload: ByteData.sublistView(bytes, offset + 12, offset + 28),
        ),
      );
      offset += _entryBytes;
    }
    return entries;
  }

  /// Extracts channel `channel`'s lane-0 volume-ride and mute-toggle
  /// breakpoints (in beat units at [tempoBpm]) from [entries], matching the
  /// scope precedent the native offline renderer already established
  /// (`perf_render.c`, parts 7-8): only lane 0's track-addressed
  /// volume/mute — both the legacy generic-arm commands
  /// (`LE_CMD_SET_VOLUME`/`LE_CMD_SET_MUTE`, which the engine maps to lane 0
  /// for backward compatibility) and the explicit lane-addressed ones
  /// (`LE_CMD_SET_LANE_VOLUME`/`LE_CMD_SET_LANE_MUTE` with `lane == 0`) are
  /// read; a non-zero explicit lane is ignored, same scope restriction as
  /// the native renderer. Entries are sorted by frame before conversion —
  /// `events.log`'s two producer streams are not globally pre-sorted (see
  /// the format doc).
  static ({List<AutomationBreakpoint> volume, List<AutomationBreakpoint> mute})
  readChannelAutomation(
    List<RawLogEntry> entries,
    int channel,
    int sampleRate,
    double tempoBpm,
  ) {
    final sorted = [...entries]..sort((a, b) => a.frame.compareTo(b.frame));
    final volume = <AutomationBreakpoint>[];
    final mute = <AutomationBreakpoint>[];

    double beatOf(int frame) => (frame / sampleRate) * (tempoBpm / 60.0);

    for (final e in sorted) {
      switch (e.code) {
        case _codeSetVolume:
          if (e.payload.getInt32(0, Endian.little) == channel) {
            volume.add(
              AutomationBreakpoint(
                beat: beatOf(e.frame),
                value: e.payload.getFloat32(4, Endian.little),
              ),
            );
          }
        case _codeSetLaneVolume:
          if (e.payload.getInt32(0, Endian.little) == channel &&
              e.payload.getInt32(4, Endian.little) == 0) {
            volume.add(
              AutomationBreakpoint(
                beat: beatOf(e.frame),
                value: e.payload.getFloat32(8, Endian.little),
              ),
            );
          }
        case _codeSetMute:
          if (e.payload.getInt32(0, Endian.little) == channel) {
            mute.add(
              AutomationBreakpoint(
                beat: beatOf(e.frame),
                // Ableton's activator is on == audible; the logged mute
                // flag is inverted from that (1 == muted == inaudible).
                value: e.payload.getFloat32(4, Endian.little) != 0.0
                    ? 0.0
                    : 1.0,
              ),
            );
          }
        case _codeSetLaneMute:
          if (e.payload.getInt32(0, Endian.little) == channel &&
              e.payload.getInt32(4, Endian.little) == 0) {
            mute.add(
              AutomationBreakpoint(
                beat: beatOf(e.frame),
                value: e.payload.getFloat32(8, Endian.little) != 0.0
                    ? 0.0
                    : 1.0,
              ),
            );
          }
      }
    }

    return (volume: volume, mute: mute);
  }
}

/// One raw `events.log` entry: the frame it was logged at, its
/// `le_command_code`/`le_perf_log_code` value, and its 16-byte union
/// payload (interpretation keyed on [code], see
/// `docs/design/performance-event-log-format.md`).
class RawLogEntry {
  /// Creates a [RawLogEntry].
  const RawLogEntry({
    required this.frame,
    required this.code,
    required this.payload,
  });

  /// Frames elapsed since arm.
  final int frame;

  /// One of `le_command_code`'s audited values, or an `le_perf_log_code`.
  final int code;

  /// The raw 16-byte union payload.
  final ByteData payload;
}
