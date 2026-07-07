import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loopy_engine/loopy_engine.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:wav_codec/wav_codec.dart';

import 'helpers/fake_performance_engine.dart';
import 'helpers/native_capture_fixture.dart';

void main() {
  late Directory tempDir;
  late FakePerformanceEngine engine;
  late PerformanceRepository repo;
  late DateTime clock;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('loopy_perf');
    engine = FakePerformanceEngine();
    clock = DateTime(2026, 7, 6, 14, 30, 15);
    repo = PerformanceRepository(
      engine: engine,
      exportsRoot: () async => '${tempDir.path}/exports',
      now: () => clock,
    );
  });

  tearDown(() {
    repo.dispose();
    tempDir.deleteSync(recursive: true);
  });

  group('arm', () {
    test('creates the slugged bundle directory and arms the engine', () async {
      final result = await repo.arm();
      expect(result, EngineResult.ok);
      expect(
        repo.armedDirectory,
        '${tempDir.path}/exports/perf-20260706-143015',
      );
      expect(Directory(repo.armedDirectory!).existsSync(), isTrue);
      expect(engine.perfArmed, isTrue);
      expect(engine.lastPerfCaptureDir, repo.armedDirectory);
    });

    test('writes the arm-time snapshot for every settled lane', () async {
      engine
        ..seedLane(0, 0, Float32List.fromList([1, 1, 1, 1]))
        ..seedLane(1, 0, Float32List.fromList([0.5, 0.5]));

      await repo.arm();
      final dir = repo.armedDirectory!;

      final armJson =
          jsonDecode(File('$dir/arm-snapshot.json').readAsStringSync())
              as Map<String, dynamic>;
      final armSnapshot = PerformanceArmSnapshot.fromJson(armJson);
      expect(armSnapshot.tracks, hasLength(2));

      final track0 = armSnapshot.tracks.firstWhere((t) => t.channel == 0);
      expect(track0.lanes, hasLength(1));
      expect(track0.lanes.single.deferred, isFalse);
      expect(track0.lanes.single.pcmFile, 'loops/track0-lane0.wav');
      expect(
        File('$dir/loops/track0-lane0.wav').existsSync(),
        isTrue,
        reason: 'settled lane PCM is written as a WAV immediately at arm',
      );

      final decoded = WavCodec.decodeFloat32(
        File('$dir/loops/track0-lane0.wav').readAsBytesSync(),
      );
      expect(decoded.samples, Float32List.fromList([1, 1, 1, 1]));
    });

    test(
      "marks a mid-overdub track's lanes as deferred, no PCM export",
      () async {
        engine.markCapturing(0);

        await repo.arm();
        final dir = repo.armedDirectory!;
        final armSnapshot = PerformanceArmSnapshot.fromJson(
          jsonDecode(File('$dir/arm-snapshot.json').readAsStringSync())
              as Map<String, dynamic>,
        );

        final track0 = armSnapshot.tracks.firstWhere((t) => t.channel == 0);
        expect(track0.lanes.single.deferred, isTrue);
        expect(track0.lanes.single.pcmFile, isNull);
        expect(Directory('$dir/loops').existsSync(), isFalse);
      },
    );

    test(
      'also defers a track mid-first-pass (TrackState.recording), not just '
      'mid-overdub',
      () async {
        engine.markCapturing(0, state: TrackState.recording);

        await repo.arm();
        final dir = repo.armedDirectory!;
        final armSnapshot = PerformanceArmSnapshot.fromJson(
          jsonDecode(File('$dir/arm-snapshot.json').readAsStringSync())
              as Map<String, dynamic>,
        );

        final track0 = armSnapshot.tracks.firstWhere((t) => t.channel == 0);
        expect(track0.lanes.single.deferred, isTrue);
        expect(Directory('$dir/loops').existsSync(), isFalse);
      },
    );

    test(
      'embeds the lane + monitor effect chains supplied via PerformanceChains',
      () async {
        engine.seedLane(0, 0, Float32List.fromList([1, 1]));
        final chain = BuiltInEffect(type: TrackEffectType.delay);

        await repo.arm(
          chains: PerformanceChains(
            laneChains: [
              PerformanceLaneChain(channel: 0, lane: 0, effects: [chain]),
            ],
            monitors: [
              PerformanceMonitorState(
                input: 0,
                enabled: true,
                outputMask: 0x3,
                volume: 0.75,
                muted: false,
                effects: [BuiltInEffect(type: TrackEffectType.reverb)],
              ),
            ],
            limiterEnabled: true,
            limiterCeiling: 0.9,
          ),
        );
        final dir = repo.armedDirectory!;
        final armSnapshot = PerformanceArmSnapshot.fromJson(
          jsonDecode(File('$dir/arm-snapshot.json').readAsStringSync())
              as Map<String, dynamic>,
        );
        final lane = armSnapshot.tracks.single.lanes.single;
        expect(lane.effects, hasLength(1));
        expect(lane.effects.single.typeCode, TrackEffectType.delay.code);

        expect(armSnapshot.limiterEnabled, isTrue);
        expect(armSnapshot.limiterCeiling, 0.9);
        expect(armSnapshot.monitors, hasLength(1));
        final monitor = armSnapshot.monitors.single;
        expect(monitor['input'], 0);
        expect(monitor['volume'], 0.75);
        final monitorEffects = monitor['effects'] as List<dynamic>;
        expect(
          (monitorEffects.single as Map<String, dynamic>)['type'],
          TrackEffectType.reverb.code,
        );
      },
    );

    test(
      'is idempotent while already armed: no new directory, no re-arm',
      () async {
        await repo.arm();
        final firstDir = repo.armedDirectory;
        final callsBefore = engine.perfArmCalls;

        final result = await repo.arm();
        expect(result, EngineResult.ok);
        expect(repo.armedDirectory, firstDir);
        expect(engine.perfArmCalls, callsBefore);
      },
    );

    test(
      'cleans up the created directory when the engine refuses to arm',
      () async {
        engine.perfArmResult = EngineResult.device;
        final result = await repo.arm();
        expect(result, EngineResult.device);
        expect(repo.armedDirectory, isNull);
        expect(
          Directory(
            '${tempDir.path}/exports/perf-20260706-143015',
          ).existsSync(),
          isFalse,
        );
      },
    );

    test(
      'disambiguates the slug when the directory already exists, without '
      'touching the pre-existing bundle',
      () async {
        final existing = Directory(
          '${tempDir.path}/exports/perf-20260706-143015',
        )..createSync(recursive: true);
        final marker = File('${existing.path}/master.wav')
          ..writeAsStringSync('pre-existing bundle content');

        await repo.arm();

        expect(
          repo.armedDirectory,
          '${tempDir.path}/exports/perf-20260706-143015-1',
        );
        expect(
          marker.readAsStringSync(),
          'pre-existing bundle content',
          reason:
              'the collision-avoidance path must never overwrite '
              'an existing bundle',
        );
      },
    );

    test(
      'propagates when the exports root cannot be created (system boundary)',
      () async {
        // A plain file sitting where the exports root directory needs to go:
        // Directory.create() cannot succeed over it.
        File('${tempDir.path}/exports').createSync(recursive: true);
        await expectLater(repo.arm(), throwsA(isA<FileSystemException>()));
      },
    );

    test('publishes armed on captureStatus', () async {
      final statuses = <PerformanceCaptureStatus>[];
      final sub = repo.captureStatus.listen(statuses.add);
      await repo.arm();
      await pumpEventQueue();
      await sub.cancel();
      expect(statuses, [
        PerformanceCaptureStatus.idle,
        PerformanceCaptureStatus.armed,
      ]);
    });
  });

  group('disarm', () {
    Future<void> armAndSeedNative(
      FakePerformanceEngine e,
      PerformanceRepository r,
    ) async {
      await r.arm();
      writeNativeSidecar(
        r.armedDirectory!,
        capturedInputs: const [0],
      );
      writeRawPcm(
        '${r.armedDirectory!}/master.pcm',
        Float32List.fromList([0.1, 0.2, 0.3, 0.4]),
      );
      writeRawPcm(
        '${r.armedDirectory!}/input-0.pcm',
        Float32List.fromList([0.5, 0.6, 0.7, 0.8]),
      );
    }

    test('converts master + captured-input raw PCM to WAV', () async {
      await armAndSeedNative(engine, repo);
      final dir = repo.armedDirectory!;

      final result = await repo.disarm();
      expect(result, EngineResult.ok);
      expect(engine.perfArmed, isFalse);

      final master = WavCodec.decodeFloat32(
        File('$dir/master.wav').readAsBytesSync(),
      );
      expect(master.channels, 2);
      expect(master.samples, Float32List.fromList([0.1, 0.2, 0.3, 0.4]));

      final input0 = WavCodec.decodeFloat32(
        File('$dir/live-input-0.wav').readAsBytesSync(),
      );
      expect(input0.channels, 2);
      expect(input0.samples, Float32List.fromList([0.5, 0.6, 0.7, 0.8]));
    });

    test(
      'merges arm + disarm snapshots into performance.json, finalized true',
      () async {
        engine.seedLane(0, 0, Float32List.fromList([1, 1]));
        await armAndSeedNative(engine, repo);
        final dir = repo.armedDirectory!;

        await repo.disarm();

        final manifest = PerformanceManifest.fromJson(
          jsonDecode(File('$dir/performance.json').readAsStringSync())
              as Map<String, dynamic>,
        );
        expect(manifest.finalized, isTrue);
        expect(manifest.armSnapshot, isNotNull);
        expect(manifest.disarmSnapshot, isNotNull);
        expect(manifest.armSnapshot!.tracks.single.channel, 0);
        // Native fields survive the merge untouched.
        expect(manifest.sampleRate, 48000);
      },
    );

    test(
      'a track recorded fresh while armed has its PCM in the disarm snapshot',
      () async {
        await armAndSeedNative(engine, repo);
        final dir = repo.armedDirectory!;
        // Recorded (and finished) only AFTER arm — the arm snapshot saw an
        // empty track.
        engine.seedLane(2, 0, Float32List.fromList([0.9, 0.9, 0.9]));

        await repo.disarm();

        final manifest = PerformanceManifest.fromJson(
          jsonDecode(File('$dir/performance.json').readAsStringSync())
              as Map<String, dynamic>,
        );
        expect(
          manifest.armSnapshot!.tracks.where((t) => t.channel == 2),
          isEmpty,
          reason: 'track 2 was empty at arm time',
        );
        final disarmTrack = manifest.disarmSnapshot!.tracks.firstWhere(
          (t) => t.channel == 2,
        );
        expect(disarmTrack.lanes.single.deferred, isFalse);
        expect(
          File('$dir/${disarmTrack.lanes.single.pcmFile}').existsSync(),
          isTrue,
        );
      },
    );

    test(
      'deletes the crash-survival arm-snapshot.json after finalize',
      () async {
        await armAndSeedNative(engine, repo);
        final dir = repo.armedDirectory!;
        await repo.disarm();
        expect(File('$dir/arm-snapshot.json').existsSync(), isFalse);
      },
    );

    test('is a no-op success when not armed', () async {
      expect(await repo.disarm(), EngineResult.ok);
    });

    test(
      'leaves capture armed and skips finalize when the engine refuses to '
      'disarm',
      () async {
        await armAndSeedNative(engine, repo);
        final dir = repo.armedDirectory!;
        engine.perfDisarmResult = EngineResult.device;

        final result = await repo.disarm();
        expect(result, EngineResult.device);
        expect(repo.armedDirectory, dir);

        final native =
            jsonDecode(File('$dir/performance.json').readAsStringSync())
                as Map<String, dynamic>;
        expect(native['finalized'], isFalse);
      },
    );

    test('disarmAndFinalize is equivalent to disarm', () async {
      await armAndSeedNative(engine, repo);
      final dir = repo.armedDirectory!;
      await repo.disarmAndFinalize();
      final manifest =
          jsonDecode(File('$dir/performance.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(manifest['finalized'], isTrue);
    });

    test(
      'starts the offline dry-stem render (part 7) once finalized, exposed '
      'via renderProgress/renderTrackStatuses',
      () async {
        await armAndSeedNative(engine, repo);
        final dir = repo.armedDirectory!;
        engine.mockRenderTrackStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];

        expect(repo.renderProgress, PerformanceRenderProgress.empty);
        expect(repo.renderTrackStatuses, isEmpty);

        await repo.disarm();

        expect(engine.renderBeginCalls, 1);
        expect(engine.lastRenderCaptureDir, dir);
        expect(repo.renderProgress.done, isTrue);
        expect(repo.renderTrackStatuses, hasLength(1));
        expect(repo.renderTrackStatuses.single.succeeded, isTrue);
      },
    );

    test(
      'still finalizes the bundle when renderBegin fails to even start '
      '(e.g. a render already in flight)',
      () async {
        await armAndSeedNative(engine, repo);
        final dir = repo.armedDirectory!;
        engine.renderBeginResult = EngineResult.alreadyRunning;

        await repo.disarm();

        expect(engine.renderBeginCalls, 1);
        final manifest =
            jsonDecode(File('$dir/performance.json').readAsStringSync())
                as Map<String, dynamic>;
        expect(
          manifest['finalized'],
          isTrue,
          reason:
              'the bundle is already complete and valid without its '
              'stems — a render that never started must not block that',
        );
      },
    );
  });

  group('persistLiveLanes', () {
    test(
      'exports settled lanes but skips a capturing track (D-CLEAR)',
      () async {
        await repo.arm();
        final dir = repo.armedDirectory!;
        engine
          ..seedLane(0, 0, Float32List.fromList([1, 1]))
          ..markCapturing(1);

        await repo.persistLiveLanes();

        expect(File('$dir/loops/track0-lane0.wav').existsSync(), isTrue);
        expect(File('$dir/loops/track1-lane0.wav').existsSync(), isFalse);
      },
    );

    test('is a no-op when not armed', () async {
      await repo.persistLiveLanes();
      // No exception, no directory created.
      expect(Directory('${tempDir.path}/exports').existsSync(), isFalse);
    });

    test('overwrites a prior export when called again (idempotent)', () async {
      await repo.arm();
      final dir = repo.armedDirectory!;
      engine.seedLane(0, 0, Float32List.fromList([1, 1]));
      await repo.persistLiveLanes();
      engine.seedLane(0, 0, Float32List.fromList([2, 2, 2]));
      await repo.persistLiveLanes();

      final decoded = WavCodec.decodeFloat32(
        File('$dir/loops/track0-lane0.wav').readAsBytesSync(),
      );
      expect(decoded.samples, Float32List.fromList([2, 2, 2]));
    });
  });

  group('findUnfinalized / recoverCapture', () {
    test('finds a capture dir whose sidecar lacks finalized: true', () async {
      final root = Directory('${tempDir.path}/exports');
      final crashed = Directory('${root.path}/perf-crashed')
        ..createSync(recursive: true);
      writeNativeSidecar(crashed.path);

      final finished = Directory('${root.path}/perf-finished')
        ..createSync(recursive: true);
      writeNativeSidecar(finished.path, finalized: true);

      final found = await repo.findUnfinalized();
      expect(
        found,
        [UnfinalizedCapture(directory: crashed.path, slug: 'perf-crashed')],
      );
    });

    test('treats an unreadable (corrupt) sidecar as unfinalized', () async {
      final root = Directory('${tempDir.path}/exports');
      final corrupt = Directory('${root.path}/perf-corrupt')
        ..createSync(recursive: true);
      File(
        '${corrupt.path}/performance.json',
      ).writeAsStringSync('{not valid json');

      final found = await repo.findUnfinalized();
      expect(
        found,
        [UnfinalizedCapture(directory: corrupt.path, slug: 'perf-corrupt')],
      );
    });

    test(
      'recoverCapture finalizes a crashed capture without a live disarm pass',
      () async {
        final root = Directory('${tempDir.path}/exports');
        final dir = Directory('${root.path}/perf-crashed')
          ..createSync(recursive: true);
        writeNativeSidecar(dir.path);
        writeRawPcm(
          '${dir.path}/master.pcm',
          Float32List.fromList([0.25, 0.5]),
        );

        await repo.recoverCapture(dir.path);

        expect(File('${dir.path}/master.wav').existsSync(), isTrue);
        final manifest =
            jsonDecode(File('${dir.path}/performance.json').readAsStringSync())
                as Map<String, dynamic>;
        expect(manifest['finalized'], isTrue);
        expect(manifest['disarmSnapshot'], isNull);
      },
    );

    test(
      'recoverCapture restores the arm snapshot from its crash-survival file',
      () async {
        engine.seedLane(0, 0, Float32List.fromList([1, 1]));
        await repo
            .arm(); // writes arm-snapshot.json, never disarmed (the "crash")
        final dir = repo.armedDirectory!;
        writeNativeSidecar(
          dir,
        ); // the drain thread's last (finalized: false) write

        await repo.recoverCapture(dir);

        final manifest = PerformanceManifest.fromJson(
          jsonDecode(File('$dir/performance.json').readAsStringSync())
              as Map<String, dynamic>,
        );
        expect(manifest.armSnapshot, isNotNull);
        expect(manifest.finalized, isTrue);
      },
    );

    test(
      'recoverCapture is a graceful no-op when performance.json is missing',
      () async {
        final dir = Directory('${tempDir.path}/exports/perf-no-sidecar')
          ..createSync(recursive: true);
        await repo.recoverCapture(dir.path); // must not throw
        expect(File('${dir.path}/performance.json').existsSync(), isFalse);
      },
    );

    test(
      'recoverCapture is a graceful no-op when performance.json is corrupt',
      () async {
        final dir = Directory('${tempDir.path}/exports/perf-corrupt')
          ..createSync(recursive: true);
        File('${dir.path}/performance.json').writeAsStringSync('{not json');

        await repo.recoverCapture(dir.path); // must not throw

        expect(
          File('${dir.path}/performance.json').readAsStringSync(),
          '{not json',
          reason: 'an unparseable sidecar is left untouched, not overwritten',
        );
      },
    );

    test(
      "does not leak a prior finalize's armSnapshot/disarmSnapshot into a "
      'later re-finalize that has none of its own',
      () async {
        engine.seedLane(0, 0, Float32List.fromList([1, 1]));
        await repo.arm();
        final dir = repo.armedDirectory!;
        writeNativeSidecar(dir);

        await repo.recoverCapture(dir); // first finalize: has an armSnapshot
        var manifest = PerformanceManifest.fromJson(
          jsonDecode(File('$dir/performance.json').readAsStringSync())
              as Map<String, dynamic>,
        );
        expect(manifest.armSnapshot, isNotNull);

        // arm-snapshot.json was deleted by the first finalize; a second
        // recovery pass has nothing of its own to contribute.
        await repo.recoverCapture(dir);
        manifest = PerformanceManifest.fromJson(
          jsonDecode(File('$dir/performance.json').readAsStringSync())
              as Map<String, dynamic>,
        );
        expect(
          manifest.armSnapshot,
          isNull,
          reason:
              "the first finalize's armSnapshot must not leak through "
              'a second finalize pass that supplies none',
        );
      },
    );
  });
}
