import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:loopy_engine/loopy_engine.dart';
import 'package:session_repository/src/models/session.dart';
import 'package:session_repository/src/session_exception.dart';
import 'package:session_repository/src/wav.dart';

/// Saves and restores Loopy sessions and exports audio.
///
/// A session is a `.loopy` bundle directory: a [Session.manifestName] manifest,
/// one 32-bit-float stem WAV per track, and a `mixdown.wav`. The repository
/// reads the engine's loop PCM for export and writes it back on load; it does
/// not own the engine (the looper repository does), it only drives it.
class SessionRepository {
  /// Creates a [SessionRepository] driving [engine].
  ///
  /// [clearPollInterval]/[clearPollAttempts] bound how long [load] waits for the
  /// engine to report all tracks cleared before importing (clears are applied
  /// asynchronously on the audio thread). Tests can shrink these.
  SessionRepository({
    required AudioEngine engine,
    Duration clearPollInterval = const Duration(milliseconds: 8),
    int clearPollAttempts = 64,
  }) : _engine = engine,
       _clearPollInterval = clearPollInterval,
       _clearPollAttempts = clearPollAttempts;

  final AudioEngine _engine;
  final Duration _clearPollInterval;
  final int _clearPollAttempts;

  /// The mixdown filename within a session bundle.
  static const String mixdownName = 'mixdown.wav';

  /// Saves the engine's current state to the `.loopy` bundle [directory],
  /// writing the manifest, per-track stems, and a mixdown. Returns the saved
  /// [Session] manifest.
  Future<Session> save(String directory) async {
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

    final session = _sessionFrom(captured);
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

  /// Restores a session from the `.loopy` bundle [directory] into the engine.
  Future<Session> load(String directory) async {
    final manifest = await File(
      '$directory/${Session.manifestName}',
    ).readAsString();
    final session = Session.fromJson(
      jsonDecode(manifest) as Map<String, dynamic>,
    );

    // The stems are raw PCM at the saved rate; loading them on a device running
    // a different rate would play the session back at the wrong pitch (there is
    // no resampling), so refuse rather than do so silently.
    final current = _engine.snapshot();
    if (current.sampleRate > 0 &&
        session.sampleRate > 0 &&
        current.sampleRate != session.sampleRate) {
      throw SessionSampleRateMismatch(
        sessionRate: session.sampleRate,
        deviceRate: current.sampleRate,
      );
    }

    // Clear the current session and wait for the engine to settle to empty.
    for (var i = 0; i < current.tracks.length; i++) {
      _engine.clear(channel: i);
    }
    if (!await _awaitCleared()) {
      throw StateError('engine did not clear before loading the session');
    }

    for (final track in session.tracks) {
      final bytes = await File('$directory/${track.stem}').readAsBytes();
      final result = _engine.importTrack(
        track.channel,
        WavCodec.decodeFloat32(bytes).samples,
      );
      if (!result.isOk) {
        throw StateError('failed to import ${track.stem}: ${result.name}');
      }
    }
    // An empty session (or a legacy save carrying a ghost grid with no
    // tracks) establishes no master: the cleared engine stays free to define
    // a fresh loop length.
    if (session.tracks.isNotEmpty && session.baseLengthFrames > 0) {
      final committed = _engine.commitSession(session.baseLengthFrames);
      if (!committed.isOk) {
        throw StateError('failed to start the session: ${committed.name}');
      }
    }

    // Session stems are lane-0-only for now (full multi-lane stems are a
    // follow-up), so restore mix settings onto lane 0.
    for (final track in session.tracks) {
      _engine
        ..setLaneVolume(track.volume, channel: track.channel)
        ..setLaneMute(muted: track.muted, channel: track.channel);
    }
    return session;
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

  Session _sessionFrom(_Capture captured) {
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

  /// Polls until every track reports empty and the master is reset, returning
  /// whether the engine settled within [_clearPollAttempts].
  Future<bool> _awaitCleared() async {
    for (var attempt = 0; attempt < _clearPollAttempts; attempt++) {
      final snapshot = _engine.snapshot();
      final cleared =
          snapshot.masterLengthFrames == 0 &&
          snapshot.tracks.every((t) => t.state == TrackState.empty);
      if (cleared) return true;
      await Future<void>.delayed(_clearPollInterval);
    }
    return false;
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
