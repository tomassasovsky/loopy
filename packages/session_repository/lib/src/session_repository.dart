import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:loopy_engine/loopy_engine.dart';
import 'package:meta/meta.dart';
import 'package:session_repository/src/models/session.dart';
import 'package:session_repository/src/models/session_summary.dart';
import 'package:session_repository/src/session_exception.dart';
import 'package:session_repository/src/session_name.dart';
import 'package:session_repository/src/wav.dart';

/// The decoded contents of a `.loopy` session bundle: the manifest plus each
/// track's stem PCM, keyed by channel.
typedef SessionBundle = ({Session session, Map<int, Float32List> stems});

/// The effect-chain data a [SessionRepository.save] persists that the engine
/// snapshot alone cannot supply: the lane chains and monitor configurations.
///
/// The bloc layer gathers these from the looper repository (the live rig is
/// the truth being saved) and hands them to [SessionRepository.save]. Kept as
/// pre-built manifest models so this package never depends on the effect model.
@immutable
class SessionChains {
  /// Creates a [SessionChains].
  const SessionChains({this.laneChains = const [], this.monitors = const []});

  /// The lane effect chains to persist.
  final List<SessionLaneChain> laneChains;

  /// The per-input monitor configurations to persist.
  final List<SessionMonitor> monitors;
}

/// Saves Loopy sessions, reads them back, and exports audio.
///
/// A session is a `.loopy` bundle directory: a [Session.manifestName] manifest,
/// one 32-bit-float stem WAV per track, and a `mixdown.wav`. This repository
/// only does file I/O plus the engine READS a save/export needs (snapshot +
/// loop PCM); applying a loaded session to the engine is the looper
/// repository's job (the single owner of looper state) — see [read].
class SessionRepository {
  /// Creates a [SessionRepository] capturing from [engine].
  ///
  /// [sessionsRoot] resolves the `sessions/` root directory the named-session
  /// catalog ([listSessions] / [bundlePath] / [renameSession] /
  /// [deleteSession]) operates under; it is optional so the existing
  /// single-bundle flow (which addresses bundles by path) needs no root. The
  /// catalog methods throw [StateError] when it is absent. Injecting a resolver
  /// keeps the catalog testable (point it at a temp dir).
  ///
  /// [clearPollInterval]/[clearPollAttempts] bound how long a save/export waits
  /// for in-flight overdub layers to settle before capturing. Tests can shrink
  /// these.
  SessionRepository({
    required AudioEngine engine,
    Future<String> Function()? sessionsRoot,
    Duration clearPollInterval = const Duration(milliseconds: 8),
    int clearPollAttempts = 64,
  }) : _engine = engine,
       _sessionsRoot = sessionsRoot,
       _clearPollInterval = clearPollInterval,
       _clearPollAttempts = clearPollAttempts;

  final AudioEngine _engine;
  final Future<String> Function()? _sessionsRoot;
  final Duration _clearPollInterval;
  final int _clearPollAttempts;

  /// The mixdown filename within a session bundle.
  static const String mixdownName = 'mixdown.wav';

  // ---- named-session catalog ----
  //
  // A name-keyed view over the `sessions/<slug>/` bundles. These do NOT touch
  // the path-addressed read/save/export below — the bloc layer resolves a name
  // to a path via [bundlePath] and feeds that into those. The sessions root is
  // a sibling of the legacy single `loopy_session/` bundle, so the old bundle
  // is never enumerated here.

  Future<String> _rootPath() async {
    final resolver = _sessionsRoot;
    if (resolver == null) {
      throw StateError('SessionRepository has no sessionsRoot configured');
    }
    return resolver();
  }

  /// Resolves [name]'s bundle directory under the sessions root, folding it to
  /// a folder-safe slug (see [sessionSlug]). Throws [ArgumentError] for a name
  /// that sanitizes to nothing.
  Future<String> bundlePath(String name) async {
    final slug = sessionSlug(name);
    if (slug == null) {
      throw ArgumentError.value(name, 'name', 'not a valid session name');
    }
    return '${await _rootPath()}/$slug';
  }

  /// Lists the saved sessions — one [SessionSummary] per `sessions/<slug>/`
  /// folder that contains a `${Session.manifestName}`, sorted alphabetically
  /// (case-insensitively). Enumeration only `stat`s for the manifest's presence
  /// (never parses it), so a newer-version or otherwise unloadable bundle is
  /// still listed; its typed failure surfaces on an actual load. A folder with
  /// no manifest is skipped. Returns empty when the root does not exist yet.
  Future<List<SessionSummary>> listSessions() async {
    final root = Directory(await _rootPath());
    if (!root.existsSync()) return const [];
    return <SessionSummary>[
      for (final entity in root.listSync())
        if (entity is Directory &&
            File('${entity.path}/${Session.manifestName}').existsSync())
          SessionSummary(name: _basename(entity.path)),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// Renames the bundle folder for session [from] to [to]. Throws
  /// [SessionNameCollision] when [to]'s slug already exists (named sessions
  /// never silently overwrite) and [ArgumentError] when [to] is not a valid
  /// name. Renaming to the same slug is a no-op.
  Future<void> renameSession(String from, String to) async {
    final toSlug = sessionSlug(to);
    if (toSlug == null) {
      throw ArgumentError.value(to, 'to', 'not a valid session name');
    }
    final fromSlug = sessionSlug(from) ?? from;
    if (toSlug == fromSlug) return;
    final root = await _rootPath();
    if (Directory('$root/$toSlug').existsSync()) {
      throw SessionNameCollision(slug: toSlug);
    }
    Directory('$root/$fromSlug').renameSync('$root/$toSlug');
  }

  /// Deletes session [name]'s bundle folder. A missing folder (or an invalid
  /// name) is a no-op — there is no concurrent-mutation race to guard in a
  /// single-window desktop app.
  Future<void> deleteSession(String name) async {
    final slug = sessionSlug(name);
    if (slug == null) return;
    final dir = Directory('${await _rootPath()}/$slug');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  /// The final path segment of [path] (the folder name), split on either
  /// separator so it is correct on every OS.
  static String _basename(String path) =>
      path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last;

  /// Saves the engine's current state to the `.loopy` bundle [directory],
  /// writing the manifest, per-track stems, and a mixdown. Returns the saved
  /// [Session] manifest.
  ///
  /// The audio + per-track mix come from the engine snapshot; the effect chains
  /// come from [chains], gathered from the looper repository by the bloc layer
  /// (the live rig — not settings — is the truth being saved). Chains exist
  /// independently of audio, so they are written for every lane / monitor that
  /// has one, regardless of which tracks hold audio.
  Future<Session> save(
    String directory, {
    SessionChains chains = const SessionChains(),
  }) async {
    await _awaitLayersSettled();
    final captured = _capture();
    await Directory(directory).create(recursive: true);

    for (final track in captured.tracks) {
      await File('$directory/${track.stem}').writeAsBytes(
        WavCodec.encodeFloat32(
          samples: captured.stems[track.channel]!,
          sampleRate: captured.snapshot.sampleRate,
          channels: 1,
        ),
      );
    }

    final session = _sessionFrom(captured, chains);
    await File('$directory/${Session.manifestName}').writeAsString(
      const JsonEncoder.withIndent('  ').convert(session.toJson()),
    );

    final mix = _mixdown(captured);
    if (mix.isNotEmpty) {
      await File('$directory/$mixdownName').writeAsBytes(
        WavCodec.encodeFloat32(
          samples: mix,
          sampleRate: captured.snapshot.sampleRate,
          channels: 1,
        ),
      );
    }
    return session;
  }

  /// Reads and validates the `.loopy` bundle [directory]: decodes the manifest
  /// and every referenced stem WAV. Pure I/O — the engine is never driven;
  /// the caller (the bloc layer) hands the result to the looper repository's
  /// `applySession`, the one apply path.
  ///
  /// The stems are raw PCM at the saved rate; loading them on a device running
  /// a different rate would play the session back at the wrong pitch (there is
  /// no resampling), so this refuses with [SessionSampleRateMismatch] rather
  /// than decode something unusable.
  Future<SessionBundle> read(String directory) async {
    final manifest = await File(
      '$directory/${Session.manifestName}',
    ).readAsString();
    final session = Session.fromJson(
      jsonDecode(manifest) as Map<String, dynamic>,
    );

    final current = _engine.snapshot();
    if (current.sampleRate > 0 &&
        session.sampleRate > 0 &&
        current.sampleRate != session.sampleRate) {
      throw SessionSampleRateMismatch(
        sessionRate: session.sampleRate,
        deviceRate: current.sampleRate,
      );
    }

    final stems = <int, Float32List>{};
    for (final track in session.tracks) {
      final bytes = await File('$directory/${track.stem}').readAsBytes();
      stems[track.channel] = WavCodec.decodeFloat32(bytes).samples;
    }
    return (session: session, stems: stems);
  }

  /// Exports a single mixed-down WAV of the current session to [path].
  Future<void> exportMixdown(String path) async {
    await _awaitLayersSettled();
    final captured = _capture();
    final mix = _mixdown(captured);
    await File(path).writeAsBytes(
      WavCodec.encodeFloat32(
        samples: mix,
        sampleRate: captured.snapshot.sampleRate,
        channels: 1,
      ),
    );
  }

  /// Exports each track's loop as a separate stem WAV in [directory].
  Future<void> exportStems(String directory) async {
    await _awaitLayersSettled();
    final captured = _capture();
    await Directory(directory).create(recursive: true);
    for (final track in captured.tracks) {
      await File('$directory/${track.stem}').writeAsBytes(
        WavCodec.encodeFloat32(
          samples: captured.stems[track.channel]!,
          sampleRate: captured.snapshot.sampleRate,
          channels: 1,
        ),
      );
    }
  }

  /// Reads the engine snapshot and each non-empty track's PCM once.
  ///
  /// Export is **lane-0 only** for this pass: `exportTrack` returns the track's
  /// primary lane PCM and the per-track [SessionTrack] mix mirrors lane 0. Full
  /// multi-lane stems are a documented follow-up.
  _Capture _capture() {
    final snapshot = _engine.snapshot();
    final stems = <int, Float32List>{};
    final tracks = <SessionTrack>[];
    for (var i = 0; i < snapshot.tracks.length; i++) {
      final track = snapshot.tracks[i];
      // Only export settled tracks: a recording/overdubbing track's buffer is
      // being written by the audio thread, so exporting it would race.
      if (track.state != TrackState.playing &&
          track.state != TrackState.stopped) {
        continue;
      }
      if (track.lengthFrames <= 0) continue;
      final pcm = _engine.exportTrack(i);
      if (pcm.isEmpty) continue;
      stems[i] = pcm;
      tracks.add(
        SessionTrack(
          channel: i,
          volume: track.volume,
          muted: track.muted,
          multiple: track.multiple,
          lengthFrames: track.lengthFrames,
          stem: 'track$i.wav',
        ),
      );
    }
    return _Capture(snapshot: snapshot, stems: stems, tracks: tracks);
  }

  Session _sessionFrom(_Capture captured, SessionChains chains) {
    final snapshot = captured.snapshot;
    return Session(
      sampleRate: snapshot.sampleRate,
      channels: 1,
      // The engine keeps the master grid alive after the last track is undone
      // to empty (redo needs it), but a session with zero tracks must not
      // persist that ghost tempo — loading it would re-establish a grid with
      // no content, silently locking the next recording's length.
      baseLengthFrames: captured.tracks.isEmpty
          ? 0
          : snapshot.masterLengthFrames,
      tracks: captured.tracks,
      laneChains: chains.laneChains,
      monitors: chains.monitors,
    );
  }

  /// Sums the unmuted tracks (at their gains) over the session period — the LCM
  /// of the track lengths, so every track's loop closes cleanly.
  Float32List _mixdown(_Capture captured) {
    const channels = 1; // per-track buffers are mono
    final active = captured.tracks.where((t) => !t.muted).toList();
    if (active.isEmpty || channels <= 0) return Float32List(0);

    var period = 1;
    for (final track in active) {
      final frames = captured.stems[track.channel]!.length ~/ channels;
      if (frames > 0) period = _lcm(period, frames);
    }

    final mix = Float32List(period * channels);
    for (final track in active) {
      final pcm = captured.stems[track.channel]!;
      final frames = pcm.length ~/ channels;
      if (frames == 0) continue;
      final volume = track.volume;
      for (var f = 0; f < period; f++) {
        final srcFrame = (f % frames) * channels;
        final dstFrame = f * channels;
        for (var c = 0; c < channels; c++) {
          mix[dstFrame + c] += pcm[srcFrame + c] * volume;
        }
      }
    }
    return mix;
  }

  /// Waits until no track has an overdub undo layer in flight (the punch-out
  /// fade tail / drain window, ~tens of ms): exporting during it would copy a
  /// buffer the audio thread is still writing, losing the tail. Throws on
  /// timeout rather than silently exporting a mid-fade stem.
  Future<void> _awaitLayersSettled() async {
    for (var attempt = 0; attempt < _clearPollAttempts; attempt++) {
      final snapshot = _engine.snapshot();
      if (snapshot.tracks.every((t) => !t.layerInFlight)) return;
      await Future<void>.delayed(_clearPollInterval);
    }
    throw StateError(
      'an overdub layer never settled — cannot export a stable capture',
    );
  }
}

int _gcd(int a, int b) {
  var x = a;
  var y = b;
  while (y != 0) {
    final t = y;
    y = x % y;
    x = t;
  }
  return x;
}

int _lcm(int a, int b) => (a == 0 || b == 0) ? 0 : (a ~/ _gcd(a, b)) * b;

/// The engine state captured once for a save/export.
class _Capture {
  const _Capture({
    required this.snapshot,
    required this.stems,
    required this.tracks,
  });

  final EngineSnapshot snapshot;
  final Map<int, Float32List> stems;
  final List<SessionTrack> tracks;
}
