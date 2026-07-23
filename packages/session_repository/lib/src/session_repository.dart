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
import 'package:wav_codec/wav_codec.dart';

/// The decoded contents of a `.loopy` session bundle: the manifest plus each
/// lane's ordinal-ordered layer PCM (undo… live … redo), keyed by
/// `(channel, lane)`.
typedef SessionBundle = ({
  Session session,
  Map<(int, int), List<Float32List>> laneStems,
});

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

  /// Copies session [from]'s bundle to a NEW session [to]. Throws
  /// [SessionNameCollision] when [to]'s slug already exists (never overwrites),
  /// [ArgumentError] when [to] is not a valid name, and is a no-op when [from]
  /// does not exist. The copy is independent — editing it never touches [from].
  Future<void> duplicateSession(String from, String to) async {
    final toSlug = sessionSlug(to);
    if (toSlug == null) {
      throw ArgumentError.value(to, 'to', 'not a valid session name');
    }
    final fromSlug = sessionSlug(from) ?? from;
    final root = await _rootPath();
    final src = Directory('$root/$fromSlug');
    if (!src.existsSync()) return;
    if (Directory('$root/$toSlug').existsSync()) {
      throw SessionNameCollision(slug: toSlug);
    }
    _copyDirSync(src, Directory('$root/$toSlug'));
  }

  /// Recursively copies [src] to [dst] (files + nested folders). The catalog
  /// bundles are shallow, but this stays correct for any nesting.
  static void _copyDirSync(Directory src, Directory dst) {
    dst.createSync(recursive: true);
    for (final entity in src.listSync()) {
      final name = _basename(entity.path);
      if (entity is Directory) {
        _copyDirSync(entity, Directory('${dst.path}/$name'));
      } else if (entity is File) {
        entity.copySync('${dst.path}/$name');
      }
    }
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

    final written = <String>{};
    for (final track in captured.tracks) {
      for (final lane in track.lanes) {
        final layerPcm = captured.laneStems[(track.channel, lane.lane)]!;
        for (var o = 0; o < lane.layers.length; o++) {
          final file = lane.layers[o].file;
          written.add(file);
          await File('$directory/$file').writeAsBytes(
            WavCodec.encodeFloat32(
              samples: layerPcm[o],
              sampleRate: captured.snapshot.sampleRate,
              channels: 1,
            ),
          );
        }
      }
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
    // The per-track file set is variable (lanes × layers shrink between saves),
    // so a re-save would otherwise leave orphaned layer WAVs. The just-written
    // manifest is the source of truth; prune every layer file it does not
    // reference. Non-layer files (the manifest, the mixdown) are untouched.
    await _pruneOrphanLayers(directory, written);
    return session;
  }

  /// The pattern of a bundle's per-layer WAV filenames
  /// (`track{c}_lane{l}_L{n}.wav`).
  static final RegExp _layerFilePattern = RegExp(
    r'^track\d+_lane\d+_L\d+\.wav$',
  );

  /// Deletes every layer WAV in [directory] not in the [keep] set — the
  /// orphans a shrinking re-save leaves behind.
  Future<void> _pruneOrphanLayers(String directory, Set<String> keep) async {
    final dir = Directory(directory);
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if (_layerFilePattern.hasMatch(name) && !keep.contains(name)) {
        entity.deleteSync();
      }
    }
  }

  /// Reads and validates the `.loopy` bundle [directory]: decodes the manifest
  /// and every lane's live-buffer WAV. Pure I/O — the engine is never driven;
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

    // Decode every lane's layers in ordinal order (undo… live … redo).
    final laneStems = <(int, int), List<Float32List>>{};
    for (final track in session.tracks) {
      for (final lane in track.lanes) {
        final layers = <Float32List>[];
        for (final layer in lane.layers) {
          final bytes = await File('$directory/${layer.file}').readAsBytes();
          layers.add(WavCodec.decodeFloat32(bytes).samples);
        }
        laneStems[(track.channel, lane.lane)] = layers;
      }
    }
    return (session: session, laneStems: laneStems);
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

  /// Exports every lane of every track as a separate WAV in [directory]. A
  /// stem is the lane's live (currently playing) buffer only — the undo/redo
  /// history is not part of a flat stems export — so each file is named
  /// `track{c}_lane{l}_L0.wav` regardless of the lane's undo depth.
  Future<void> exportStems(String directory) async {
    await _awaitLayersSettled();
    final captured = _capture();
    await Directory(directory).create(recursive: true);
    for (final track in captured.tracks) {
      for (final lane in track.lanes) {
        final layerPcm = captured.laneStems[(track.channel, lane.lane)]!;
        await File(
          '$directory/track${track.channel}_lane${lane.lane}_L0.wav',
        ).writeAsBytes(
          WavCodec.encodeFloat32(
            samples: layerPcm[lane.liveIndex],
            sampleRate: captured.snapshot.sampleRate,
            channels: 1,
          ),
        );
      }
    }
  }

  /// Reads the engine snapshot and each settled track's per-lane overdub layers
  /// once.
  ///
  /// Every active lane's full pool history is exported: the `undoDepth` undo
  /// snapshots, the live buffer, then the `redoDepth` redo snapshots (the
  /// undo/redo depths are track-wide, so every lane carries the same count). A
  /// lane whose live buffer is empty is skipped, and a track left with no lane
  /// is dropped.
  _Capture _capture() {
    final snapshot = _engine.snapshot();
    final laneStems = <(int, int), List<Float32List>>{};
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
      final undoCount = track.undoDepth;
      final redoCount = track.redoDepth;
      final total = undoCount + 1 + redoCount;
      final lanes = <SessionLane>[];
      for (var l = 0; l < track.lanes.length; l++) {
        // The live layer sits at ordinal `undoCount`; skip a lane whose live
        // buffer is empty (nothing recorded on it).
        final live = _engine.exportLayer(i, l, undoCount);
        if (live.isEmpty) continue;
        final layerPcm = <Float32List>[];
        final layerFiles = <SessionLayer>[];
        for (var ordinal = 0; ordinal < total; ordinal++) {
          final pcm = ordinal == undoCount
              ? live
              : _engine.exportLayer(i, l, ordinal);
          if (pcm.isEmpty) break; // torn history — drop this lane
          layerPcm.add(pcm);
          layerFiles.add(
            SessionLayer(file: 'track${i}_lane${l}_L$ordinal.wav'),
          );
        }
        if (layerPcm.length != total) continue;
        laneStems[(i, l)] = layerPcm;
        final laneSnap = track.lanes[l];
        lanes.add(
          SessionLane(
            lane: l,
            volume: laneSnap.volume,
            muted: laneSnap.muted,
            outputMask: laneSnap.outputMask,
            inputChannel: laneSnap.inputChannel,
            layers: layerFiles,
            undoCount: undoCount,
            redoCount: redoCount,
          ),
        );
      }
      if (lanes.isEmpty) continue;
      tracks.add(
        SessionTrack(
          channel: i,
          multiple: track.multiple,
          lengthFrames: track.lengthFrames,
          lengthPresetBars: track.lengthPresetBars,
          oneShot: track.oneShot,
          lanes: lanes,
        ),
      );
    }
    return _Capture(snapshot: snapshot, laneStems: laneStems, tracks: tracks);
  }

  Session _sessionFrom(_Capture captured, SessionChains chains) {
    final snapshot = captured.snapshot;
    return Session(
      sampleRate: snapshot.sampleRate,
      channels: 1,
      // The engine keeps the master grid alive after the last track is undone
      // to empty (redo needs it), but a session with zero tracks must not
      // persist that ghost length — loading it would re-establish a grid
      // with no content, silently locking the next recording's length.
      baseLengthFrames: captured.tracks.isEmpty
          ? 0
          : snapshot.masterLengthFrames,
      tracks: captured.tracks,
      laneChains: chains.laneChains,
      monitors: chains.monitors,
      // Tempo/signature/quantize/click/count-in are session-level settings,
      // not derived-from-track-content state, so — unlike baseLengthFrames
      // above — they persist regardless of whether any track has content.
      // This is deliberate, not an oversight: D6 says a derived tempo
      // survives clearing its source loop ("clearing all tracks offers a
      // tempo reset, never forces it"), and D7 lets a manual/tapped tempo be
      // dialed in before the first recording ever starts — both cases are a
      // zero-track snapshot the app must still round-trip faithfully.
      tempoBpm: snapshot.tempoBpm,
      tempoSource: snapshot.tempoSource,
      tsNum: snapshot.tsNum,
      tsDen: snapshot.tsDen,
      quantizeDiv: snapshot.quantizeDiv,
      clickMode: snapshot.clickMode,
      clickOutputMask: snapshot.clickMask,
      clickVolume: snapshot.clickVolume,
      countInBars: snapshot.countInBars,
      // Looper mode + crown (schema v4, B5c) are session-level SETTINGS, not
      // derived-from-track-content state either — same reasoning as the
      // tempo-grid fields above, and [snapshot.looperMode]/
      // [snapshot.primaryTrack] persist regardless of track content by
      // construction (D18; [LooperModeControl]'s class doc).
      looperMode: snapshot.looperMode,
      primaryTrack: snapshot.primaryTrack,
      // One Shot, per channel (post-B5c independent review fix): read
      // straight off `snapshot.tracks` — EVERY channel, unconditional on
      // `state`/`lengthFrames` — rather than off `captured.tracks` (which
      // the loop above only builds for a settled, content-bearing channel).
      // `LooperModeControl.setOneShot` is explicitly "not gated by the D4
      // content lock" and settable on an empty track in advance of
      // recording, so this is the one content-independent home the flag
      // needs to round-trip a pre-armed-but-empty channel through save/load
      // — see [Session.oneShotChannels]'s doc.
      oneShotChannels: [
        for (var i = 0; i < snapshot.tracks.length; i++)
          if (snapshot.tracks[i].oneShot) i,
      ],
    );
  }

  /// Sums every unmuted lane (at its gain) over the session period — the LCM of
  /// the lane lengths, so every lane's loop closes cleanly. Lanes are summed,
  /// never merged: a two-lane track contributes both lanes to the mix.
  Float32List _mixdown(_Capture captured) {
    final active = <(Float32List, double)>[];
    for (final track in captured.tracks) {
      for (final lane in track.lanes) {
        if (lane.muted) continue;
        final layerPcm = captured.laneStems[(track.channel, lane.lane)];
        if (layerPcm == null) continue;
        final pcm = layerPcm[lane.liveIndex]; // mix the live buffer per lane
        if (pcm.isEmpty) continue;
        active.add((pcm, lane.volume));
      }
    }
    if (active.isEmpty) return Float32List(0);

    var period = 1;
    for (final (pcm, _) in active) {
      period = _lcm(period, pcm.length);
    }

    final mix = Float32List(period);
    for (final (pcm, volume) in active) {
      final frames = pcm.length;
      if (frames == 0) continue;
      for (var f = 0; f < period; f++) {
        mix[f] += pcm[f % frames] * volume;
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
    required this.laneStems,
    required this.tracks,
  });

  final EngineSnapshot snapshot;
  final Map<(int, int), List<Float32List>> laneStems;
  final List<SessionTrack> tracks;
}
