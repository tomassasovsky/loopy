import 'package:meta/meta.dart';

/// A DAW project ready to be rendered to an Ableton Live 12 `.als` set
/// (`buildAls`, `als_builder.dart`).
///
/// This is `daw_export`'s own input model — it is built either directly by a
/// test fixture or by `DawManifestReader` (`manifest_reader.dart`) from a
/// finalized performance-recording capture's `performance.json`
/// (`docs/design/performance-manifest-format.md`), never by importing
/// `performance_repository` or `loopy_engine` (this package has no
/// dependency on either, so it can run standalone against just the
/// documented file formats).
@immutable
class DawProject {
  /// Creates a [DawProject].
  const DawProject({required this.tracks, this.tempoBpm = 120.0});

  /// One entry per non-empty Loopy track or live-input stem. An empty track
  /// (nothing recorded) is never represented here — the caller building this
  /// project (a fixture, or `DawManifestReader`) already excludes it, so
  /// `buildAls` never needs to re-derive "empty."
  final List<DawTrack> tracks;

  /// Fixed project tempo in BPM (D-TEMPO: always 120 for this feature —
  /// every clip's beat-time math in `als_builder.dart` assumes this).
  final double tempoBpm;
}

/// One Ableton audio track: an optional arrangement-view clip (the full
/// bounced performance, placed at capture t=0) and zero or more session-view
/// clips (one per recordable lane's settled loop content).
@immutable
class DawTrack {
  /// Creates a [DawTrack].
  const DawTrack({
    required this.name,
    this.arrangementClip,
    this.sessionClips = const [],
  });

  /// The track's display name in Ableton (e.g. `Track 0` or `Input 1`).
  final String name;

  /// The full-length, capture-t=0 arrangement clip for this track, or `null`
  /// if this track has no arrangement-worthy content (e.g. a live-input stem
  /// that was never actually captured to a bounce, only its per-lane loop
  /// content exists in [sessionClips]).
  final DawClip? arrangementClip;

  /// One session-view loop clip per recordable lane this track owns.
  final List<DawSessionClip> sessionClips;
}

/// One arrangement-view audio clip: placed at [startSeconds] for
/// [lengthSeconds], referencing [fileRef] (always a path relative to the
/// `.als` file's own directory — D-ALS, so moving the whole bundle keeps
/// every reference resolving). Warp is always off (D-TEMPO): a captured
/// performance is not meant to stretch to the project tempo, since re-warping
/// would defeat the point of an already sample-accurate export.
@immutable
class DawClip {
  /// Creates a [DawClip].
  const DawClip({
    required this.fileRef,
    required this.startSeconds,
    required this.lengthSeconds,
  });

  /// Path to the referenced audio file, relative to the `.als` file's own
  /// directory. Never absolute (D-ALS) — `als_builder.dart`'s own tests
  /// fail the suite on an absolute path in any fixture output.
  final String fileRef;

  /// Clip start position on the arrangement timeline, in seconds.
  final double startSeconds;

  /// Clip length in seconds.
  final double lengthSeconds;
}

/// One session-view loop clip: a single recordable lane's settled loop
/// content, placed in that lane's own clip slot (index [laneIndex]) so it can
/// be triggered/looped independently of the arrangement-view bounce. Warp is
/// always off, same rationale as [DawClip].
@immutable
class DawSessionClip {
  /// Creates a [DawSessionClip].
  const DawSessionClip({
    required this.laneIndex,
    required this.fileRef,
    required this.lengthSeconds,
  });

  /// The lane this clip slot belongs to (0-based, matching the owning
  /// track's lane indices).
  final int laneIndex;

  /// Path to the referenced audio file, relative to the `.als` file's own
  /// directory. Never absolute (D-ALS).
  final String fileRef;

  /// Clip length in seconds (a session clip's own loop length — this is the
  /// lane's settled content, not the full capture).
  final double lengthSeconds;
}
