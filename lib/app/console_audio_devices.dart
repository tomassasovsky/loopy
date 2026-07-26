import 'package:looper_repository/looper_repository.dart';

/// Playback + capture device ids chosen for a console first-boot / empty-id
/// heal. Both are non-empty when non-null.
typedef ConsoleAudioDevices = ({String playbackId, String captureId});

/// Picks the audio interface a floor-console should open when no device is
/// pinned yet (heuristic A):
///
/// 1. Prefer the first **non-default** playback id that also appears as a
///    non-default capture id (shared duplex id).
/// 2. Else the first non-default playback id + first non-default capture id
///    (ALSA sometimes splits direction ids).
/// 3. Else `null` — caller keeps today's system-default open.
ConsoleAudioDevices? pickConsoleAudioDevices(List<AudioDevice> devices) {
  final playback = [
    for (final d in devices)
      if (!d.isInput && !d.isDefault) d,
  ];
  final capture = [
    for (final d in devices)
      if (d.isInput && !d.isDefault) d,
  ];
  if (playback.isEmpty || capture.isEmpty) return null;

  final captureIds = {for (final d in capture) d.id};
  for (final p in playback) {
    if (captureIds.contains(p.id)) {
      return (playbackId: p.id, captureId: p.id);
    }
  }
  return (playbackId: playback.first.id, captureId: capture.first.id);
}
