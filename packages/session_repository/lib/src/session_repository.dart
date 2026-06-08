import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:loopy_engine/loopy_engine.dart';
import 'package:session_repository/src/models/session.dart';
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
    final captured = _capture();
    await Directory(directory).create(recursive: true);

    for (final track in captured.tracks) {
      await File('$directory/${track.stem}').writeAsBytes(
        WavCodec.encodeFloat32(
          samples: captured.stems[track.channel]!,
          sampleRate: captured.snapshot.sampleRate,
          channels: captured.snapshot.channels,
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
          channels: captured.snapshot.channels,
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

    // Clear the current session and wait for the engine to settle to empty.
    final current = _engine.snapshot();
    for (var i = 0; i < current.tracks.length; i++) {
      _engine.clear(channel: i);
    }
    await _awaitCleared();

    // Apply tempo/sync/quantize before committing so the derived beat grid
    // matches the saved session, then transport toggles.
    _engine
      ..setTempo(session.tempoBpm)
      ..setSyncTempo(on: session.syncLoopToTempo)
      ..setQuantize(session.quantizeMode)
      ..setMetronome(on: session.metronomeOn)
      ..setCountIn(enabled: session.countInEnabled);

    for (final track in session.tracks) {
      final bytes = await File('$directory/${track.stem}').readAsBytes();
      _engine.importTrack(track.channel, WavCodec.decodeFloat32(bytes).samples);
    }
    _engine.commitSession(session.baseLengthFrames);

    for (final track in session.tracks) {
      _engine
        ..setTrackVolume(track.volume, channel: track.channel)
        ..setTrackMute(muted: track.muted, channel: track.channel);
    }
    return session;
  }

  /// Exports a single mixed-down WAV of the current session to [path].
  Future<void> exportMixdown(String path) async {
    final captured = _capture();
    final mix = _mixdown(captured);
    await File(path).writeAsBytes(
      WavCodec.encodeFloat32(
        samples: mix,
        sampleRate: captured.snapshot.sampleRate,
        channels: captured.snapshot.channels,
      ),
    );
  }

  /// Exports each track's loop as a separate stem WAV in [directory].
  Future<void> exportStems(String directory) async {
    final captured = _capture();
    await Directory(directory).create(recursive: true);
    for (final track in captured.tracks) {
      await File('$directory/${track.stem}').writeAsBytes(
        WavCodec.encodeFloat32(
          samples: captured.stems[track.channel]!,
          sampleRate: captured.snapshot.sampleRate,
          channels: captured.snapshot.channels,
        ),
      );
    }
  }

  /// Reads the engine snapshot and each non-empty track's PCM once.
  _Capture _capture() {
    final snapshot = _engine.snapshot();
    final stems = <int, Float32List>{};
    final tracks = <SessionTrack>[];
    for (var i = 0; i < snapshot.tracks.length; i++) {
      final track = snapshot.tracks[i];
      if (track.state == TrackState.empty || track.lengthFrames <= 0) continue;
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
      channels: snapshot.channels,
      baseLengthFrames: snapshot.masterLengthFrames,
      tempoBpm: snapshot.tempoBpm,
      syncLoopToTempo: snapshot.syncLoopToTempo,
      quantizeMode: snapshot.quantizeMode,
      metronomeOn: snapshot.metronomeOn,
      countInEnabled: snapshot.countInEnabled,
      tracks: captured.tracks,
    );
  }

  /// Sums the unmuted tracks (at their gains) over the session period — the LCM
  /// of the track lengths, so every track's loop closes cleanly.
  Float32List _mixdown(_Capture captured) {
    final channels = captured.snapshot.channels;
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

  Future<void> _awaitCleared() async {
    for (var attempt = 0; attempt < _clearPollAttempts; attempt++) {
      final snapshot = _engine.snapshot();
      final cleared =
          snapshot.masterLengthFrames == 0 &&
          snapshot.tracks.every((t) => t.state == TrackState.empty);
      if (cleared) return;
      await Future<void>.delayed(_clearPollInterval);
    }
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
