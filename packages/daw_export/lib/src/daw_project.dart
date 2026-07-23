import 'package:daw_export/src/daw_effect.dart';
import 'package:daw_export/src/device_chain_resolver.dart';
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
  ///
  /// [tempoBpm] is normalized at construction: a non-positive value (`<= 0`,
  /// including the default-free-looper "unset" sentinel a v4 session manifest
  /// reports — `Session.tempoBpm`, `session_repository`'s "0 = unset") falls
  /// back to [kFallbackTempoBpm] rather than being stored verbatim, so this
  /// model can never carry a tempo that would make `als_builder.dart`'s
  /// beat-time math (`secondsToBeats`) degenerate. Every construction path —
  /// a direct fixture, or `DawManifestReader.read` — goes through this same
  /// normalization.
  const DawProject({required this.tracks, double tempoBpm = kFallbackTempoBpm})
    : tempoBpm = tempoBpm > 0 ? tempoBpm : kFallbackTempoBpm;

  /// One entry per non-empty Loopy track or live-input stem. An empty track
  /// (nothing recorded) is never represented here — the caller building this
  /// project (a fixture, or `DawManifestReader`) already excludes it, so
  /// `buildAls` never needs to re-derive "empty."
  final List<DawTrack> tracks;

  /// Project tempo in BPM, applied uniformly to every clip/automation's
  /// beat-time math in `als_builder.dart` (D-TEMPO: a captured performance
  /// still renders at one fixed tempo start-to-finish — Loopy has no
  /// mid-performance tempo changes to represent).
  ///
  /// This is the session's REAL tempo once the caller has one to supply
  /// (`DawManifestReader.read`'s `tempoBpm` argument, threaded from the v4
  /// session manifest's `Session.tempoBpm`) — no longer hardcoded to 120 for
  /// every export. [kFallbackTempoBpm] (120 BPM, this feature's original
  /// fixed assumption) remains the compatible fallback for a legacy v3
  /// session or grid-off (`TempoSource.none`) content, where there is no real
  /// tempo to export — see the constructor doc.
  final double tempoBpm;
}

/// The fallback project tempo in BPM: this feature's original fixed-tempo
/// assumption (D-TEMPO), now used specifically for the "no real tempo known"
/// case — a legacy v3 session, or v4 grid-off content, both of which report
/// `Session.tempoBpm == 0` ("unset").
const double kFallbackTempoBpm = 120;

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
    this.deviceChain,
    this.deviceChainFallbackReason,
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

  /// The channel's resolved real Loopy VST3 device chain (part 10,
  /// `device_chain_resolver.dart`'s [resolveDeviceChain]), or `null` when no
  /// chain could be honestly resolved (see [deviceChainFallbackReason]) —
  /// today's existing wet-bounce export is the fallback for a `null` chain
  /// (umbrella D-NO-STOCK-DEVICES). Non-null but *empty* for a channel with
  /// no effects on any lane at all — a real, resolved "nothing to emit"
  /// outcome, distinct from a fallback.
  final List<DawEffect>? deviceChain;

  /// Why [deviceChain] is `null`, or `null` if it resolved (including to an
  /// empty chain) — set only when effects existed but couldn't be honestly
  /// represented as a single device chain. Never set for a channel with no
  /// effects at all, since there is nothing to explain there.
  final DeviceChainFallbackReason? deviceChainFallbackReason;
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
