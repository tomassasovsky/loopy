import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loopy_engine/loopy_engine.dart';
import 'package:session_repository/session_repository.dart';

import 'helpers/fake_session_engine.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('loopy_session');
  });
  tearDown(() => tempDir.deleteSync(recursive: true));

  SessionRepository repoFor(AudioEngine engine) => SessionRepository(
    engine: engine,
    clearPollInterval: Duration.zero,
    clearPollAttempts: 4,
  );

  test('save writes the manifest, a stem per track, and a mixdown', () async {
    final engine = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
      ..seedTrack(
        1,
        Float32List.fromList([2, 2, 2, 2, 3, 3, 3, 3]),
        multiple: 2,
      );
    final dir = '${tempDir.path}/sess';

    final session = await repoFor(engine).save(dir);

    expect(File('$dir/${Session.manifestName}').existsSync(), isTrue);
    expect(File('$dir/track0.wav').existsSync(), isTrue);
    expect(File('$dir/track1.wav').existsSync(), isTrue);
    expect(File('$dir/${SessionRepository.mixdownName}').existsSync(), isTrue);
    expect(session.baseLengthFrames, 4);
    expect(session.tracks, hasLength(2));
    expect(session.tracks[1].multiple, 2);
  });

  test('save waits out an in-flight overdub layer before capturing', () async {
    final engine = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
      ..layerInFlightPolls = 2; // the punch-tail/drain window, then settled
    final dir = '${tempDir.path}/sess';

    final session = await repoFor(engine).save(dir);

    expect(session.tracks, hasLength(1)); // captured AFTER the settle
    expect(engine.layerInFlightPolls, 0); // the wait actually consumed polls
  });

  test('save throws when an overdub layer never settles', () async {
    final engine = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
      ..layerInFlightPolls = 1 << 30; // never settles within the attempts
    final dir = '${tempDir.path}/sess';

    await expectLater(repoFor(engine).save(dir), throwsStateError);
  });

  test(
    'saving an all-empty looper persists no ghost grid, and loading an '
    'empty session establishes no master',
    () async {
      // The engine keeps the master grid after the last track is undone to
      // empty (redo needs it live) — but a zero-track session must not carry
      // that ghost tempo to disk.
      final engine = FakeSessionEngine()..masterLength = 48000;
      final dir = '${tempDir.path}/sess';

      final session = await repoFor(engine).save(dir);
      expect(session.baseLengthFrames, 0);
      expect(session.tracks, isEmpty);

      // Loading it into a fresh engine leaves the grid unset: the next
      // recording is free to define its own loop length.
      final target = FakeSessionEngine();
      await repoFor(target).load(dir);
      expect(target.masterLength, 0);
    },
  );

  test('save then load reproduces the engine state', () async {
    final source = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
      ..seedTrack(
        1,
        Float32List.fromList([2, 2, 2, 2, 3, 3, 3, 3]),
        multiple: 2,
        volume: 0.5,
        muted: true,
      );
    final dir = '${tempDir.path}/s';
    await repoFor(source).save(dir);

    final target = FakeSessionEngine();
    await repoFor(target).load(dir);
    final snap = target.snapshot();

    expect(snap.masterLengthFrames, 4);

    expect(snap.tracks[0].state, TrackState.playing);
    expect(snap.tracks[0].multiple, 1);
    expect(target.exportTrack(0), Float32List.fromList([1, 1, 1, 1]));

    expect(snap.tracks[1].state, TrackState.playing);
    expect(snap.tracks[1].multiple, 2);
    expect(snap.tracks[1].muted, isTrue);
    expect(snap.tracks[1].volume, 0.5);
    expect(
      target.exportTrack(1),
      Float32List.fromList([2, 2, 2, 2, 3, 3, 3, 3]),
    );
  });

  test('mixdown sums unmuted tracks over the LCM period', () async {
    final engine = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1])) // base 2
      ..seedTrack(
        1,
        Float32List.fromList([0.5, 0.5, 0.5, 0.5]),
        multiple: 2,
      ); // length 4, base 2
    final path = '${tempDir.path}/mix.wav';

    await repoFor(engine).exportMixdown(path);
    final wav = WavCodec.decodeFloat32(File(path).readAsBytesSync());

    expect(wav.frames, 4); // lcm(2, 4)
    for (final sample in wav.samples) {
      expect(sample, closeTo(1.5, 1e-6));
    }
  });

  test('mixdown excludes muted tracks', () async {
    final engine = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
      ..seedTrack(1, Float32List.fromList([9, 9, 9, 9]), muted: true);
    final path = '${tempDir.path}/mix.wav';

    await repoFor(engine).exportMixdown(path);
    final wav = WavCodec.decodeFloat32(File(path).readAsBytesSync());

    for (final sample in wav.samples) {
      expect(sample, closeTo(1, 1e-6));
    }
  });

  test('exportStems writes one WAV per non-empty track', () async {
    final engine = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
    final dir = '${tempDir.path}/stems';

    await repoFor(engine).exportStems(dir);

    expect(File('$dir/track0.wav').existsSync(), isTrue);
    expect(File('$dir/track1.wav').existsSync(), isFalse);
  });

  test('load throws when the bundle is missing', () async {
    final engine = FakeSessionEngine();
    await expectLater(
      repoFor(engine).load('${tempDir.path}/does_not_exist'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('load refuses a session saved at a different sample rate', () async {
    final source = FakeSessionEngine(sampleRate: 44100)
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
    final dir = '${tempDir.path}/sr';
    await repoFor(source).save(dir);

    final target = FakeSessionEngine(); // 48000 Hz
    await expectLater(
      repoFor(target).load(dir),
      throwsA(isA<SessionSampleRateMismatch>()),
    );
  });

  test('save then load round-trips a single mono track exactly', () async {
    final source = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([0.1, -0.2, 0.3, -0.4]));
    final dir = '${tempDir.path}/mono';
    await repoFor(source).save(dir);

    final target = FakeSessionEngine();
    await repoFor(target).load(dir);

    expect(
      target.exportTrack(0),
      Float32List.fromList([0.1, -0.2, 0.3, -0.4]),
    );
  });
}
