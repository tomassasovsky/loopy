import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loopy_engine/loopy_engine.dart';
import 'package:session_repository/session_repository.dart';
import 'package:wav_codec/wav_codec.dart';

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
    expect(File('$dir/track0_lane0_L0.wav').existsSync(), isTrue);
    expect(File('$dir/track1_lane0_L0.wav').existsSync(), isTrue);
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
    'saving an all-empty looper persists no ghost grid — an empty session '
    'reads back with no master to establish',
    () async {
      // The engine keeps the master grid after the last track is undone to
      // empty (redo needs it live) — but a zero-track session must not carry
      // that ghost tempo to disk.
      final engine = FakeSessionEngine()..masterLength = 48000;
      final dir = '${tempDir.path}/sess';

      final session = await repoFor(engine).save(dir);
      expect(session.baseLengthFrames, 0);
      expect(session.tracks, isEmpty);

      // Reading it back carries no grid: the apply path (looper repository)
      // leaves the cleared engine free to define a fresh loop length.
      final bundle = await repoFor(FakeSessionEngine()).read(dir);
      expect(bundle.session.baseLengthFrames, 0);
      expect(bundle.laneStems, isEmpty);
    },
  );

  test(
    'save persists the lane chains and monitors, read returns them',
    () async {
      final source = FakeSessionEngine()
        ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
      final dir = '${tempDir.path}/fx';

      const chains = SessionChains(
        laneChains: [
          SessionLaneChain(channel: 0, lane: 0, encoded: '[{"t":1}]'),
        ],
        monitors: [
          SessionMonitor(
            input: 2,
            enabled: true,
            outputMask: 0x1,
            volume: 0.6,
            muted: true,
            encoded: '[{"t":7}]',
          ),
        ],
      );
      final session = await repoFor(source).save(dir, chains: chains);
      expect(session.laneChains, chains.laneChains);
      expect(session.monitors, chains.monitors);

      final bundle = await repoFor(FakeSessionEngine()).read(dir);
      expect(bundle.session.laneChains, chains.laneChains);
      expect(bundle.session.monitors, chains.monitors);
    },
  );

  test(
    'save threads the engine snapshot tempo grid + click + count-in into '
    'the v4 manifest, read decodes it back',
    () async {
      final source = FakeSessionEngine()
        ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
        ..tempoBpm = 96.0
        ..tempoSource = TempoSource.tapped
        ..tsNum = 7
        ..tsDen = 8
        ..quantizeDiv = GridDivision.quarter
        ..clickMode = ClickMode.playRec
        ..clickMask = 0x1
        ..clickVolume = 0.4
        ..countInBars = 3;
      final dir = '${tempDir.path}/tempo';

      final session = await repoFor(source).save(dir);
      expect(session.tempoBpm, 96.0);
      expect(session.tempoSource, TempoSource.tapped);
      expect(session.tsNum, 7);
      expect(session.tsDen, 8);
      expect(session.quantizeDiv, GridDivision.quarter);
      expect(session.clickMode, ClickMode.playRec);
      expect(session.clickOutputMask, 0x1);
      expect(session.clickVolume, 0.4);
      expect(session.countInBars, 3);

      final bundle = await repoFor(FakeSessionEngine()).read(dir);
      expect(bundle.session.tempoBpm, 96.0);
      expect(bundle.session.tempoSource, TempoSource.tapped);
      expect(bundle.session.tsNum, 7);
      expect(bundle.session.tsDen, 8);
      expect(bundle.session.quantizeDiv, GridDivision.quarter);
      expect(bundle.session.clickMode, ClickMode.playRec);
      expect(bundle.session.clickOutputMask, 0x1);
      expect(bundle.session.clickVolume, 0.4);
      expect(bundle.session.countInBars, 3);
    },
  );

  test(
    'a derived tempo persists in the manifest even when saved with zero '
    'tracks (D6: clearing all tracks offers a tempo reset, never forces it)',
    () async {
      // Unlike baseLengthFrames (zeroed for a zero-track save, see the
      // "persists no ghost grid" test above), tempo/signature/click/
      // count-in are session-level settings, not derived-from-content
      // state — the engine's "grid survives a clear" behavior must round
      // -trip through a save exactly as the live engine reports it.
      final engine = FakeSessionEngine()
        ..tempoBpm = 140.0
        ..tempoSource = TempoSource.derived;
      final dir = '${tempDir.path}/dead-tempo';

      final session = await repoFor(engine).save(dir);
      expect(session.tracks, isEmpty);
      expect(session.baseLengthFrames, 0);
      expect(session.tempoBpm, 140.0);
      expect(session.tempoSource, TempoSource.derived);
    },
  );

  test(
    'save without chains writes an empty (but present) v2 chain list',
    () async {
      final source = FakeSessionEngine()
        ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
      final dir = '${tempDir.path}/nofx';

      final session = await repoFor(source).save(dir);
      expect(session.laneChains, isEmpty);
      expect(session.monitors, isEmpty);
    },
  );

  test('save then read returns the manifest and every decoded stem', () async {
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

    final bundle = await repoFor(FakeSessionEngine()).read(dir);

    expect(bundle.session.baseLengthFrames, 4);
    expect(bundle.session.tracks, hasLength(2));
    expect(bundle.session.tracks[1].multiple, 2);
    expect(bundle.session.tracks[1].lanes.single.muted, isTrue);
    expect(bundle.session.tracks[1].lanes.single.volume, 0.5);
    expect(bundle.laneStems[(0, 0)], [
      Float32List.fromList([1, 1, 1, 1]),
    ]);
    expect(bundle.laneStems[(1, 0)], [
      Float32List.fromList([2, 2, 2, 2, 3, 3, 3, 3]),
    ]);
  });

  test('save then read round-trips a multi-lane track per lane', () async {
    final source = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
      ..seedLane(
        0,
        1,
        Float32List.fromList([2, 2, 2, 2]),
        volume: 0.5,
        muted: true,
        outputMask: 0x2,
        inputChannel: 1,
      );
    final dir = '${tempDir.path}/multilane';
    await repoFor(source).save(dir);

    final bundle = await repoFor(FakeSessionEngine()).read(dir);
    final track = bundle.session.tracks.single;
    expect(track.lanes, hasLength(2));
    expect(track.lanes[1].volume, 0.5);
    expect(track.lanes[1].muted, isTrue);
    expect(track.lanes[1].outputMask, 0x2);
    expect(track.lanes[1].inputChannel, 1);
    expect(bundle.laneStems[(0, 0)], [
      Float32List.fromList([1, 1, 1, 1]),
    ]);
    expect(bundle.laneStems[(0, 1)], [
      Float32List.fromList([2, 2, 2, 2]),
    ]);
  });

  test(
    'save then read round-trips an 8-track Free-mode session with '
    'independent per-track lengths (B5c)',
    () async {
      // Mutually distinct lengths, none a multiple of another — proves each
      // track's own length round-trips independently rather than being
      // forced to a shared base/multiple relationship (Free mode's whole
      // point: "four un-synced, independently playing, free-form tracks",
      // extended to loopy's 8).
      const lengths = [5, 7, 9, 11, 13, 17, 19, 23];
      final source = FakeSessionEngine()..looperMode = LooperMode.free;
      for (final (channel, length) in lengths.indexed) {
        source.seedTrack(
          channel,
          Float32List.fromList(List.filled(length, channel + 1.0)),
        );
      }
      final dir = '${tempDir.path}/free8';
      await repoFor(source).save(dir);

      final bundle = await repoFor(FakeSessionEngine()).read(dir);

      expect(bundle.session.looperMode, LooperMode.free);
      expect(bundle.session.tracks, hasLength(8));
      for (final (channel, length) in lengths.indexed) {
        final track = bundle.session.tracks.firstWhere(
          (t) => t.channel == channel,
        );
        expect(track.lengthFrames, length, reason: 'track $channel');
        expect(
          bundle.laneStems[(channel, 0)]!.single,
          Float32List.fromList(List.filled(length, channel + 1.0)),
          reason: 'track $channel PCM',
        );
      }
    },
  );

  test(
    'save then read round-trips looperMode, primaryTrack, and per-track '
    'oneShot (B5c)',
    () async {
      final source = FakeSessionEngine()
        ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
        ..seedTrack(1, Float32List.fromList([2, 2, 2, 2]))
        ..looperMode = LooperMode.sync
        ..primaryTrack = 1
        ..oneShot[0] = true;
      final dir = '${tempDir.path}/mode';
      await repoFor(source).save(dir);

      final bundle = await repoFor(FakeSessionEngine()).read(dir);

      expect(bundle.session.looperMode, LooperMode.sync);
      expect(bundle.session.primaryTrack, 1);
      final track0 = bundle.session.tracks.firstWhere((t) => t.channel == 0);
      final track1 = bundle.session.tracks.firstWhere((t) => t.channel == 1);
      expect(track0.oneShot, isTrue);
      expect(track1.oneShot, isFalse);
    },
  );

  test(
    'save then read defaults looperMode/primaryTrack/oneShot when the '
    'engine reports the tempo-free/grid-off values (no data loss for a '
    'plain Multi session)',
    () async {
      final source = FakeSessionEngine()
        ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
      final dir = '${tempDir.path}/plain';
      await repoFor(source).save(dir);

      final bundle = await repoFor(FakeSessionEngine()).read(dir);

      expect(bundle.session.looperMode, LooperMode.multi);
      expect(bundle.session.primaryTrack, -1);
      expect(bundle.session.tracks.single.oneShot, isFalse);
    },
  );

  test(
    "save then read round-trips a lane's full overdub layer stack",
    () async {
      final undo0 = Float32List.fromList([1, 1, 1, 1]);
      final live = Float32List.fromList([2, 2, 2, 2]);
      final redo0 = Float32List.fromList([3, 3, 3, 3]);
      final source = FakeSessionEngine()
        ..seedLayers(0, [undo0, live, redo0], undoDepth: 1, redoDepth: 1);
      final dir = '${tempDir.path}/layers';
      await repoFor(source).save(dir);

      // One WAV per layer.
      expect(File('$dir/track0_lane0_L0.wav').existsSync(), isTrue);
      expect(File('$dir/track0_lane0_L1.wav').existsSync(), isTrue);
      expect(File('$dir/track0_lane0_L2.wav').existsSync(), isTrue);

      final bundle = await repoFor(FakeSessionEngine()).read(dir);
      final lane = bundle.session.tracks.single.lanes.single;
      expect(lane.undoCount, 1);
      expect(lane.redoCount, 1);
      expect(lane.liveIndex, 1);
      // The layers round-trip in ordinal order (undo → live → redo).
      expect(bundle.laneStems[(0, 0)], [undo0, live, redo0]);
    },
  );

  test('re-saving with fewer layers prunes the orphaned layer WAVs', () async {
    final dir = '${tempDir.path}/prune';
    // First save: a 3-layer history.
    await repoFor(
      FakeSessionEngine()..seedLayers(
        0,
        [
          Float32List.fromList([1, 1, 1, 1]),
          Float32List.fromList([2, 2, 2, 2]),
          Float32List.fromList([3, 3, 3, 3]),
        ],
        undoDepth: 1,
        redoDepth: 1,
      ),
    ).save(dir);
    expect(File('$dir/track0_lane0_L2.wav').existsSync(), isTrue);

    // Re-save the same bundle with a single-layer (no-history) track.
    await repoFor(
      FakeSessionEngine()..seedTrack(0, Float32List.fromList([9, 9, 9, 9])),
    ).save(dir);

    expect(File('$dir/track0_lane0_L0.wav').existsSync(), isTrue);
    expect(File('$dir/track0_lane0_L1.wav').existsSync(), isFalse);
    expect(File('$dir/track0_lane0_L2.wav').existsSync(), isFalse);
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

  test('mixdown sums both lanes of a multi-lane track', () async {
    // Two lanes on ONE track must both contribute — summed, never merged.
    final engine = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
      ..seedLane(0, 1, Float32List.fromList([0.25, 0.25, 0.25, 0.25]));
    final path = '${tempDir.path}/mix.wav';

    await repoFor(engine).exportMixdown(path);
    final wav = WavCodec.decodeFloat32(File(path).readAsBytesSync());

    expect(wav.frames, 4);
    for (final sample in wav.samples) {
      expect(sample, closeTo(1.25, 1e-6)); // 1.0 (lane 0) + 0.25 (lane 1)
    }
  });

  test('mixdown excludes a muted lane of a multi-lane track', () async {
    final engine = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
      ..seedLane(0, 1, Float32List.fromList([9, 9, 9, 9]), muted: true);
    final path = '${tempDir.path}/mix.wav';

    await repoFor(engine).exportMixdown(path);
    final wav = WavCodec.decodeFloat32(File(path).readAsBytesSync());

    for (final sample in wav.samples) {
      expect(sample, closeTo(1, 1e-6)); // only lane 0 contributes
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

    expect(File('$dir/track0_lane0_L0.wav').existsSync(), isTrue);
    expect(File('$dir/track1_lane0_L0.wav').existsSync(), isFalse);
  });

  test('read throws when the bundle is missing', () async {
    final engine = FakeSessionEngine();
    await expectLater(
      repoFor(engine).read('${tempDir.path}/does_not_exist'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('read refuses a session saved at a different sample rate', () async {
    final source = FakeSessionEngine(sampleRate: 44100)
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
    final dir = '${tempDir.path}/sr';
    await repoFor(source).save(dir);

    final target = FakeSessionEngine(); // 48000 Hz
    await expectLater(
      repoFor(target).read(dir),
      throwsA(isA<SessionSampleRateMismatch>()),
    );
  });

  test('save then read round-trips a single mono stem exactly', () async {
    final source = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([0.1, -0.2, 0.3, -0.4]));
    final dir = '${tempDir.path}/mono';
    await repoFor(source).save(dir);

    final bundle = await repoFor(FakeSessionEngine()).read(dir);

    expect(bundle.laneStems[(0, 0)], [
      Float32List.fromList([0.1, -0.2, 0.3, -0.4]),
    ]);
  });
}
