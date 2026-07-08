import 'dart:convert';
import 'dart:io';

import 'package:daw_export/src/daw_project.dart';

/// Reads a finalized performance-recording capture directory's
/// `performance.json` (docs/design/performance-manifest-format.md) directly
/// — no import of `performance_repository`/`loopy_engine`, matching this
/// package's own-input-model rule — into a [DawProject] whose clips
/// reference the capture's already-rendered stems (`stems/wet/`, falling
/// back to `stems/dry/` for a channel whose wet render failed or hasn't run)
/// and per-lane loop exports (`loops/`).
///
/// This only reconstructs what part 9 actually needs: track layout and
/// full-length arrangement clips plus per-lane session clips. It does not
/// read `events.log` at all — automation lanes are part 10.
abstract final class DawManifestReader {
  /// Reads `<captureDir>/performance.json` and returns the [DawProject] it
  /// describes, or `null` if the manifest is missing/unreadable/corrupt (a
  /// capture that never finalized, or was deleted out from under the
  /// caller) — mirrors this codebase's established "graceful no-op on a
  /// missing/corrupt sidecar" convention (`performance_repository`'s
  /// `recoverCapture`) rather than throwing.
  static DawProject? read(String captureDir, {double tempoBpm = 120.0}) {
    final manifestFile = File('$captureDir/performance.json');
    if (!manifestFile.existsSync()) return null;
    final Map<String, dynamic> manifest;
    try {
      manifest =
          jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
    } on FormatException {
      return null;
    }

    final sampleRate = (manifest['sample_rate'] as num?)?.toInt() ?? 0;
    final captureFrames = (manifest['capture_frames'] as num?)?.toInt() ?? 0;
    if (sampleRate <= 0 || captureFrames <= 0) return null;
    final captureSeconds = captureFrames / sampleRate;

    final armTracks = _tracksOf(manifest['armSnapshot']);
    final disarmTracks = _tracksOf(manifest['disarmSnapshot']);

    // channel -> (lane -> pcmRef). Built from arm first, then disarm
    // overwrites — disarm is the later, fresher pass (a track recorded
    // fresh during the session has no arm-time entry at all, and a track
    // that was already settled at arm keeps its arm-time entry unless
    // disarm captured something newer for the same lane).
    final pcmRefsByChannel = <int, Map<int, String>>{};
    for (final t in [...armTracks, ...disarmTracks]) {
      final channel = (t['channel'] as num?)?.toInt();
      if (channel == null) continue;
      final laneMap = pcmRefsByChannel.putIfAbsent(channel, () => {});
      for (final lane in (t['lanes'] as List<dynamic>? ?? const [])) {
        final laneJson = lane as Map<String, dynamic>;
        final laneIndex = (laneJson['lane'] as num?)?.toInt();
        final pcmRef = laneJson['pcmRef'] as String?;
        if (laneIndex == null || pcmRef == null) continue;
        laneMap[laneIndex] = pcmRef;
      }
    }

    final tracks = <DawTrack>[];
    for (final channel in pcmRefsByChannel.keys.toList()..sort()) {
      final arrangementFile = _firstExisting(captureDir, [
        'stems/wet/track$channel.wav',
        'stems/dry/track$channel.wav',
      ]);

      final sessionClips = <DawSessionClip>[];
      final lanes = pcmRefsByChannel[channel]!;
      for (final lane in lanes.keys.toList()..sort()) {
        final pcmRef = lanes[lane]!;
        if (!File('$captureDir/$pcmRef').existsSync()) continue;
        sessionClips.add(
          DawSessionClip(
            laneIndex: lane,
            fileRef: pcmRef,
            // The per-lane loop's own length isn't recorded in the
            // manifest at the top level (only the full capture's is) — a
            // fixed reference to the capture length is a placeholder until
            // part 11 threads the lane's actual settled length through;
            // documented as a known simplification, not a silent guess.
            lengthSeconds: captureSeconds,
          ),
        );
      }

      if (arrangementFile == null && sessionClips.isEmpty) continue;

      tracks.add(
        DawTrack(
          name: 'Track $channel',
          arrangementClip: arrangementFile == null
              ? null
              : DawClip(
                  fileRef: arrangementFile,
                  startSeconds: 0,
                  lengthSeconds: captureSeconds,
                ),
          sessionClips: sessionClips,
        ),
      );
    }

    return DawProject(tracks: tracks, tempoBpm: tempoBpm);
  }

  static List<Map<String, dynamic>> _tracksOf(dynamic snapshot) {
    if (snapshot is! Map<String, dynamic>) return const [];
    final tracks = snapshot['tracks'];
    if (tracks is! List) return const [];
    return [for (final t in tracks) t as Map<String, dynamic>];
  }

  static String? _firstExisting(String captureDir, List<String> candidates) {
    for (final relative in candidates) {
      if (File('$captureDir/$relative').existsSync()) return relative;
    }
    return null;
  }
}
