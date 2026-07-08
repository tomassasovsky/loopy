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
/// bounced performance, placed at capture t=0), zero or more session-view
/// clips (one per recordable lane's settled loop content), and zero or more
/// automation lanes reconstructed from the captured performance's logged
/// gestures (part 10).
@immutable
class DawTrack {
  /// Creates a [DawTrack].
  const DawTrack({
    required this.name,
    this.arrangementClip,
    this.sessionClips = const [],
    this.automationLanes = const [],
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

  /// Automation reconstructed from the captured performance's logged
  /// gestures — a volume ride becomes a [AutomationTarget.volume] envelope,
  /// a mute/unmute becomes a [AutomationTarget.activator] envelope (Ableton
  /// has no native "mute automation"; the mixer's activator on/off parameter
  /// preserves the gesture instead of baking it into clip splits — D-MUTE).
  /// At most one lane per [AutomationTarget] — a caller building this by
  /// hand should not emit two lanes for the same target on the same track.
  final List<AutomationLane> automationLanes;
}

/// Which Ableton mixer parameter an [AutomationLane] targets.
enum AutomationTarget {
  /// The track's mixer volume fader — a continuous 0..1 gain ramp, emitted
  /// as `FloatEvent`s (D-MUTE's counterpart for the continuous case: a
  /// volume ride is already a native Ableton automation concept, no
  /// workaround needed).
  volume,

  /// The track's mixer "Activator" (on/off) — Ableton's nearest equivalent
  /// to a mute toggle, since Ableton itself has no per-track mute automation
  /// parameter (D-MUTE). Step-shaped: emitted as `BoolEvent`s, never
  /// interpolated between 0 and 1.
  activator,
}

/// One automation envelope for a track's [AutomationTarget] parameter: an
/// ordered, already-thinned (see `automation_thinning.dart`) list of
/// breakpoints. [AutomationTarget.volume] breakpoints are continuous ramp
/// points (linear interpolation between them is expected to stay within the
/// thinning epsilon of the original captured curve);
/// [AutomationTarget.activator] breakpoints are step edges — each one holds
/// until the next, never interpolated.
@immutable
class AutomationLane {
  /// Creates an [AutomationLane].
  const AutomationLane({required this.target, required this.breakpoints});

  /// Which mixer parameter this envelope drives.
  final AutomationTarget target;

  /// Ordered by [AutomationBreakpoint.beat], ascending. Never empty for a
  /// lane that exists at all — an [AutomationLane] with nothing to say
  /// simply isn't constructed.
  final List<AutomationBreakpoint> breakpoints;
}

/// One point on an [AutomationLane]'s envelope.
@immutable
class AutomationBreakpoint {
  /// Creates an [AutomationBreakpoint].
  const AutomationBreakpoint({required this.beat, required this.value});

  /// Position on the arrangement timeline, in Ableton beat units (see
  /// `als_builder.dart`'s `secondsToBeats`).
  final double beat;

  /// The parameter's value at [beat]: `0..1` gain for
  /// [AutomationTarget.volume], or exactly `0.0`/`1.0` (off/on) for
  /// [AutomationTarget.activator].
  final double value;
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
