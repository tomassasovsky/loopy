import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/performance/cubit/performance_recorder_cubit.dart';
import 'package:loopy_engine/loopy_engine.dart'
    show PerformanceRenderProgress, PerformanceRenderTrackStatus;
import 'package:performance_repository/performance_repository.dart';

import '../../helpers/helpers.dart';

/// `events.log`'s 12-byte header: `PLEV` magic + 4 reserved bytes + a
/// little-endian int32 sample rate (docs/design/performance-event-log-format
/// .md), reproduced here the same way `EventLogReader` itself does, so a test
/// fixture can write a log with at least one entry.
Uint8List _eventLogHeader({int sampleRate = 48000}) {
  final out = Uint8List(12)..setRange(0, 4, 'PLEV'.codeUnits);
  ByteData.sublistView(out).setInt32(8, sampleRate, Endian.little);
  return out;
}

Uint8List _eventLogEntry({int frame = 0, int code = 7}) {
  final bytes = ByteData(28)
    ..setUint64(0, frame, Endian.little)
    ..setInt32(8, code, Endian.little);
  return bytes.buffer.asUint8List();
}

void writeManifest(
  String dir, {
  String? stoppedEarly,
  bool finalized = true,
}) {
  final json = {
    'slug': dir.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last,
    'sample_rate': 48000,
    'channel_layout': {'master_channels': 2, 'captured_inputs': <int>[]},
    'capture_frames': 4800,
    'overrun_count': 0,
    'overrun_gaps': <Map<String, dynamic>>[],
    'layers': <Map<String, dynamic>>[],
    'stopped_early': ?stoppedEarly,
    'finalized': finalized,
  };
  File(
    '$dir/performance.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
}

/// Waits for [cubit] to reach [PerformanceRecorderCompleted] — the render
/// pipeline's tail writes `.als`/`fx-chains.txt` via real (non-microtask)
/// file I/O, so `pumpEventQueue()` alone cannot reliably observe it; this
/// polls the actual stream instead, with a generous timeout so a genuine
/// regression still fails loudly rather than hanging.
Future<PerformanceRecorderCompleted> waitForCompleted(
  PerformanceRecorderCubit cubit,
) async {
  final state = cubit.state;
  if (state is PerformanceRecorderCompleted) return state;
  return cubit.stream
      .firstWhere((s) => s is PerformanceRecorderCompleted)
      .timeout(const Duration(seconds: 5))
      .then((s) => s as PerformanceRecorderCompleted);
}

void main() {
  late Directory tempDir;
  late FakeAudioEngine engine;
  late PerformanceRepository performance;
  late DateTime clock;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('loopy_perf_cubit');
    engine = FakeAudioEngine();
    clock = DateTime(2026, 7, 6, 14, 30, 15);
    performance = PerformanceRepository(
      engine: engine,
      exportsRoot: () async => '${tempDir.path}/exports',
      now: () => clock,
    );
  });

  tearDown(() {
    performance.dispose();
    tempDir.deleteSync(recursive: true);
  });

  PerformanceRecorderCubit build({
    DateTime Function()? now,
    Future<int?> Function(String path)? freeSpaceBytes,
  }) => PerformanceRecorderCubit(
    performance: performance,
    armedTickInterval: const Duration(milliseconds: 10),
    renderPollInterval: const Duration(milliseconds: 10),
    now: now ?? (() => clock),
    freeSpaceBytes: freeSpaceBytes ?? (_) async => null,
  );

  /// Arms via the repository directly and seeds a real `events.log` +
  /// `performance.json` in the armed directory so a subsequent disarm has
  /// something non-trivial to finalize/render — mirrors
  /// `performance_repository_test.dart`'s own native-sidecar fixture style.
  Future<String> armWithLog(
    PerformanceRepository repo, {
    int entries = 1,
  }) async {
    await repo.arm();
    final dir = repo.armedDirectory!;
    final bytes = BytesBuilder()..add(_eventLogHeader());
    for (var i = 0; i < entries; i++) {
      bytes.add(_eventLogEntry(frame: i * 100));
    }
    File('$dir/events.log').writeAsBytesSync(bytes.toBytes());
    writeManifest(dir, finalized: false);
    return dir;
  }

  group('load', () {
    blocTest<PerformanceRecorderCubit, PerformanceRecorderState>(
      'finds an unfinalized capture at boot and surfaces recoveryDirectory',
      setUp: () {
        final dir = Directory('${tempDir.path}/exports/perf-crashed')
          ..createSync(recursive: true);
        writeManifest(dir.path, finalized: false);
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        isA<PerformanceRecorderIdle>().having(
          (s) => s.recoveryDirectory,
          'recoveryDirectory',
          '${tempDir.path}/exports/perf-crashed',
        ),
      ],
    );

    blocTest<PerformanceRecorderCubit, PerformanceRecorderState>(
      'stays plain idle when there is nothing unfinalized',
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => <PerformanceRecorderState>[],
    );

    test('is idempotent: a second call is a no-op', () async {
      final dir = Directory('${tempDir.path}/exports/perf-crashed')
        ..createSync(recursive: true);
      writeManifest(dir.path, finalized: false);
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.load();
      final afterFirst = cubit.state;
      await cubit.load();

      expect(cubit.state, afterFirst);
    });
  });

  group('recoverBootCapture / discardBootCapture', () {
    test(
      'recover finalizes the crashed capture then renders to completion',
      () async {
        final dir = Directory('${tempDir.path}/exports/perf-crashed')
          ..createSync(recursive: true);
        writeManifest(dir.path, finalized: false);
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.load();

        final states = <PerformanceRecorderState>[];
        final sub = cubit.stream.listen(states.add);

        await cubit.recoverBootCapture();
        final completed = await waitForCompleted(cubit);
        await sub.cancel();

        expect(states.first, isA<PerformanceRecorderFinalizing>());
        expect(completed.result, isA<PerformanceRecordDone>());

        final manifest =
            jsonDecode(File('${dir.path}/performance.json').readAsStringSync())
                as Map<String, dynamic>;
        expect(manifest['finalized'], isTrue);
      },
    );

    test(
      'discard removes the capture directory and returns to plain idle',
      () async {
        final dir = Directory('${tempDir.path}/exports/perf-crashed')
          ..createSync(recursive: true);
        writeManifest(dir.path, finalized: false);
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.load();
        expect(
          (cubit.state as PerformanceRecorderIdle).recoveryDirectory,
          isNotNull,
        );

        await cubit.discardBootCapture();

        expect(cubit.state, const PerformanceRecorderIdle());
        expect(dir.existsSync(), isFalse);
      },
    );

    test('both are a no-op when there is nothing pending recovery', () async {
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.load();

      await cubit.recoverBootCapture();
      expect(cubit.state, const PerformanceRecorderIdle());

      await cubit.discardBootCapture();
      expect(cubit.state, const PerformanceRecorderIdle());
    });
  });

  group('toggleArm', () {
    test('idle -> armed on first call', () async {
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.toggleArm();
      await pumpEventQueue();

      expect(cubit.state, isA<PerformanceRecorderArmed>());
    });

    test(
      'armed -> disarm path on a second call after the guard window',
      () async {
        var now = clock;
        final cubit = build(now: () => now);
        addTearDown(cubit.close);

        await cubit.toggleArm();
        await pumpEventQueue();
        expect(cubit.state, isA<PerformanceRecorderArmed>());

        now = now.add(const Duration(seconds: 2));
        await cubit.toggleArm();
        await pumpEventQueue();

        expect(cubit.state, isNot(isA<PerformanceRecorderArmed>()));
      },
    );

    test(
      'a disarm attempted within 1s of arm is ignored (double-press guard)',
      () async {
        var now = clock;
        final cubit = build(now: () => now);
        addTearDown(cubit.close);

        await cubit.toggleArm();
        await pumpEventQueue();
        expect(cubit.state, isA<PerformanceRecorderArmed>());

        now = now.add(const Duration(milliseconds: 500));
        await cubit.toggleArm();
        await pumpEventQueue();

        // Still armed: the disarm was swallowed by the guard.
        expect(cubit.state, isA<PerformanceRecorderArmed>());
        expect(engine.perfDisarmCalls, 0);
      },
    );

    test('is refused (a no-op) while finalizing/rendering', () async {
      // A render that never finishes on its own, so the cubit is
      // deterministically caught mid-Rendering rather than racing a real
      // disarm+render pipeline that might settle before the assertions run.
      engine.renderProgress = const PerformanceRenderProgress(
        done: false,
        progressPercent: 50,
      );
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.toggleArm();
      await pumpEventQueue();

      // Kick off a disarm directly on the repository so the cubit is driven
      // into finalizing/rendering without going through toggleArm's own
      // guard, then attempt an arm mid-flight.
      unawaited(performance.disarmAndFinalize());
      await cubit.stream.firstWhere(
        (s) => s is! PerformanceRecorderIdle && s is! PerformanceRecorderArmed,
      );
      expect(cubit.state, isNot(isA<PerformanceRecorderIdle>()));

      await cubit.toggleArm(); // refused: not idle
      expect(engine.perfArmCalls, 1, reason: 'no second arm went through');
    });

    test(
      'is refused while a boot-recovery prompt is unresolved',
      () async {
        final dir = Directory('${tempDir.path}/exports/perf-crashed')
          ..createSync(recursive: true);
        writeManifest(dir.path, finalized: false);
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.load();
        expect(
          (cubit.state as PerformanceRecorderIdle).recoveryDirectory,
          isNotNull,
        );

        await cubit.toggleArm();

        expect(engine.perfArmCalls, 0);
      },
    );
  });

  group('reactive status-stream driving', () {
    test(
      'disarmAndFinalize called directly on the repository still drives the '
      "cubit through Finalizing -> Rendering -> Completed (SessionCubit's "
      'auto-disarm path)',
      () async {
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
        final cubit = build();
        addTearDown(cubit.close);
        await armWithLog(performance);
        await pumpEventQueue();
        // Advance the clock past the 2s short-capture window so this counts
        // as a real (long enough) capture.
        clock = clock.add(const Duration(seconds: 5));

        final states = <PerformanceRecorderState>[];
        final sub = cubit.stream.listen(states.add);

        await performance.disarmAndFinalize(); // bypasses cubit.toggleArm
        await waitForCompleted(cubit);
        await sub.cancel();

        expect(
          states.any((s) => s is PerformanceRecorderFinalizing),
          isTrue,
        );
        expect(
          states.any((s) => s is PerformanceRecorderRendering),
          isTrue,
        );
        expect(states.last, isA<PerformanceRecorderCompleted>());
      },
    );
  });

  group('render polling outcomes', () {
    test('PerformanceRecordDone when every track succeeds', () async {
      engine.renderStatuses = const [
        PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        PerformanceRenderTrackStatus(channel: 1, succeeded: true),
      ];
      final cubit = build();
      addTearDown(cubit.close);
      await armWithLog(performance);
      await pumpEventQueue();
      clock = clock.add(const Duration(seconds: 5));

      await cubit.toggleArm();
      final completed = await waitForCompleted(cubit);
      expect(completed.result, isA<PerformanceRecordDone>());
    });

    test('PerformanceRecordPartial when at least one track fails', () async {
      engine.renderStatuses = const [
        PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        PerformanceRenderTrackStatus(channel: 1, succeeded: false),
      ];
      final cubit = build();
      addTearDown(cubit.close);
      await armWithLog(performance);
      await pumpEventQueue();
      clock = clock.add(const Duration(seconds: 5));

      await cubit.toggleArm();
      final completed = await waitForCompleted(cubit);
      expect(completed.result, isA<PerformanceRecordPartial>());
    });

    test(
      'PerformanceRecordStoppedEarly when performance.json carries '
      'stopped_early',
      () async {
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
        final cubit = build();
        addTearDown(cubit.close);
        final dir = await armWithLog(performance);
        await pumpEventQueue();
        // perf_drain.c writes stopped_early into the STILL-armed sidecar
        // (finalized: false) the moment its own self-stop fires — finalize
        // then preserves that native field verbatim, so the fixture mirrors
        // that ordering rather than editing the manifest after the fact.
        writeManifest(dir, stoppedEarly: 'disk_full', finalized: false);
        clock = clock.add(const Duration(seconds: 5));

        await cubit.toggleArm();
        final completed = await waitForCompleted(cubit);
        expect(completed.result, isA<PerformanceRecordStoppedEarly>());
        final result = completed.result! as PerformanceRecordStoppedEarly;
        expect(result.reason, PerformanceStopReason.diskFull);
      },
    );

    test(
      'PerformanceRecordStoppedEarly reports deviceChanged for that field '
      'value',
      () async {
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
        final cubit = build();
        addTearDown(cubit.close);
        final dir = await armWithLog(performance);
        await pumpEventQueue();
        writeManifest(dir, stoppedEarly: 'device_changed', finalized: false);
        clock = clock.add(const Duration(seconds: 5));

        await cubit.toggleArm();
        final completed = await waitForCompleted(cubit);
        final result = completed.result! as PerformanceRecordStoppedEarly;
        expect(result.reason, PerformanceStopReason.deviceChanged);
      },
    );
  });

  group('short-capture auto-discard', () {
    test(
      'an armed period under 2s with no events.log auto-discards without '
      'rendering, deleting the capture directory',
      () async {
        final cubit = build();
        addTearDown(cubit.close);

        await cubit.toggleArm();
        await pumpEventQueue();
        final dir = performance.armedDirectory!;
        // Past the 1s double-press guard, but still under the 2s
        // short-capture threshold.
        clock = clock.add(const Duration(milliseconds: 1500));

        await cubit.toggleArm(); // disarm
        final completed = await waitForCompleted(cubit);

        expect(completed.discarded, isTrue);
        expect(completed.result, isNull);
        expect(Directory(dir).existsSync(), isFalse);
        expect(
          engine.lastRenderCaptureDir,
          isNull,
          reason: 'a short empty capture skips the render pipeline entirely',
        );
      },
    );

    test(
      'an armed period under 2s with only the 12-byte PLEV header (zero '
      'entries) also auto-discards',
      () async {
        final cubit = build();
        addTearDown(cubit.close);

        await cubit.toggleArm();
        await pumpEventQueue();
        final dir = performance.armedDirectory!;
        File('$dir/events.log').writeAsBytesSync(_eventLogHeader());
        // Past the 1s double-press guard, but still under the 2s
        // short-capture threshold.
        clock = clock.add(const Duration(milliseconds: 1500));

        await cubit.toggleArm();
        final completed = await waitForCompleted(cubit);
        expect(completed.discarded, isTrue);
        expect(Directory(dir).existsSync(), isFalse);
      },
    );

    test(
      'a long-enough capture (>= 2s) with events runs the render pipeline '
      'instead of discarding',
      () async {
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
        final cubit = build();
        addTearDown(cubit.close);
        await armWithLog(performance);
        await pumpEventQueue();
        clock = clock.add(const Duration(seconds: 5));

        await cubit.toggleArm();
        final completed = await waitForCompleted(cubit);
        expect(completed.discarded, isFalse);
        expect(completed.result, isNotNull);
      },
    );
  });

  group('renameCompletedCapture', () {
    Future<PerformanceRecorderCubit> completedCubit() async {
      engine.renderStatuses = const [
        PerformanceRenderTrackStatus(channel: 0, succeeded: true),
      ];
      final cubit = build();
      addTearDown(cubit.close);
      await armWithLog(performance);
      await pumpEventQueue();
      clock = clock.add(const Duration(seconds: 5));
      await cubit.toggleArm();
      await waitForCompleted(cubit);
      return cubit;
    }

    test('renames via the repository and updates the result path', () async {
      final cubit = await completedCubit();
      final before = cubit.state as PerformanceRecorderCompleted;
      final oldPath = (before.result! as PerformanceRecordDone).path;

      await cubit.renameCompletedCapture('My Take');

      final after = cubit.state as PerformanceRecorderCompleted;
      final newPath = (after.result! as PerformanceRecordDone).path;
      expect(newPath, isNot(oldPath));
      expect(newPath, endsWith('My Take'));
      expect(Directory(newPath).existsSync(), isTrue);
    });

    test(
      'a PerformanceNameCollision from the repository propagates (rethrows)',
      () async {
        final cubit = await completedCubit();
        Directory(
          '${tempDir.path}/exports/Taken',
        ).createSync(recursive: true);

        await expectLater(
          cubit.renameCompletedCapture('Taken'),
          throwsA(isA<PerformanceNameCollision>()),
        );
      },
    );
  });

  group('low-disk warning', () {
    test(
      'lowDiskWarning becomes true when freeSpaceBytes reports below the '
      'threshold',
      () async {
        final cubit = build(
          freeSpaceBytes: (_) async =>
              PerformanceRecorderCubit.lowDiskThresholdBytes - 1,
        );
        addTearDown(cubit.close);

        await cubit.toggleArm();
        await pumpEventQueue();

        expect(
          (cubit.state as PerformanceRecorderArmed).lowDiskWarning,
          isTrue,
        );
      },
    );

    test(
      'stays false when free space is comfortably above the threshold',
      () async {
        final cubit = build(
          freeSpaceBytes: (_) async =>
              PerformanceRecorderCubit.lowDiskThresholdBytes * 2,
        );
        addTearDown(cubit.close);

        await cubit.toggleArm();
        await pumpEventQueue();

        expect(
          (cubit.state as PerformanceRecorderArmed).lowDiskWarning,
          isFalse,
        );
      },
    );
  });

  group('salvage boot (D-SALVAGE)', () {
    test(
      'a capture dir left unfinalized on disk (performance.json without '
      'finalized: true) surfaces as recoveryDirectory at boot, and '
      'recoverBootCapture finalizes + renders it end-to-end',
      () async {
        final dir = Directory('${tempDir.path}/exports/perf-20260706-140000')
          ..createSync(recursive: true);
        writeManifest(dir.path, finalized: false);
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];

        final cubit = build();
        addTearDown(cubit.close);
        await cubit.load();

        expect(
          (cubit.state as PerformanceRecorderIdle).recoveryDirectory,
          dir.path,
        );

        await cubit.recoverBootCapture();
        final completed = await waitForCompleted(cubit);
        expect(completed.result, isA<PerformanceRecordDone>());
        final manifest =
            jsonDecode(File('${dir.path}/performance.json').readAsStringSync())
                as Map<String, dynamic>;
        expect(manifest['finalized'], isTrue);
      },
    );

    test(
      'discardBootCapture removes the unfinalized dir instead of rendering',
      () async {
        final dir = Directory('${tempDir.path}/exports/perf-20260706-140000')
          ..createSync(recursive: true);
        writeManifest(dir.path, finalized: false);

        final cubit = build();
        addTearDown(cubit.close);
        await cubit.load();

        await cubit.discardBootCapture();

        expect(dir.existsSync(), isFalse);
        expect(engine.lastRenderCaptureDir, isNull);
        expect(cubit.state, const PerformanceRecorderIdle());
      },
    );
  });
}
