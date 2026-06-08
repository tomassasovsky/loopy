import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy_engine/loopy_engine.dart';
import 'package:loopy_engine/src/generated/loopy_engine_bindings.dart';

void main() {
  group('LatencyState.fromCode', () {
    test('maps each known code', () {
      expect(LatencyState.fromCode(0), LatencyState.idle);
      expect(LatencyState.fromCode(1), LatencyState.measuring);
      expect(LatencyState.fromCode(2), LatencyState.done);
      expect(LatencyState.fromCode(3), LatencyState.timeout);
    });

    test('falls back to idle for unknown codes', () {
      expect(LatencyState.fromCode(99), LatencyState.idle);
      expect(LatencyState.fromCode(-7), LatencyState.idle);
    });
  });

  group('EngineSnapshot.initial', () {
    test('represents a never-started engine', () {
      const snapshot = EngineSnapshot.initial();
      expect(snapshot.isRunning, isFalse);
      expect(snapshot.sampleRate, 0);
      expect(snapshot.framesProcessed, 0);
      expect(snapshot.latencyState, LatencyState.idle);
      expect(snapshot.measuredLatencyMs, -1);
    });
  });

  group('EngineSnapshot.fromNative', () {
    test('projects every native field', () {
      final ptr = calloc<le_snapshot>();
      try {
        ptr.ref
          ..running = 1
          ..sample_rate = 48000
          ..buffer_frames = 128
          ..channels = 2
          ..frames_processed = 123456
          ..xrun_count = 3
          ..input_rms = 0.25
          ..input_peak = 0.5
          ..output_rms = 0.125
          ..latency_state = 2
          ..measured_latency_ms = 7.5;

        final snapshot = EngineSnapshot.fromNative(ptr.ref);

        expect(snapshot.isRunning, isTrue);
        expect(snapshot.sampleRate, 48000);
        expect(snapshot.bufferFrames, 128);
        expect(snapshot.channels, 2);
        expect(snapshot.framesProcessed, 123456);
        expect(snapshot.xrunCount, 3);
        expect(snapshot.inputRms, closeTo(0.25, 1e-6));
        expect(snapshot.inputPeak, closeTo(0.5, 1e-6));
        expect(snapshot.outputRms, closeTo(0.125, 1e-6));
        expect(snapshot.latencyState, LatencyState.done);
        expect(snapshot.measuredLatencyMs, closeTo(7.5, 1e-9));
      } finally {
        calloc.free(ptr);
      }
    });

    test('maps running == 0 to isRunning false', () {
      final ptr = calloc<le_snapshot>();
      try {
        ptr.ref.running = 0;
        expect(EngineSnapshot.fromNative(ptr.ref).isRunning, isFalse);
      } finally {
        calloc.free(ptr);
      }
    });
  });

  group('value semantics', () {
    test('equal snapshots are equal and share a hashCode', () {
      const a = EngineSnapshot.initial();
      const b = EngineSnapshot.initial();
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('differing snapshots are not equal', () {
      const a = EngineSnapshot.initial();
      const b = EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        channels: 2,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: LatencyState.idle,
        measuredLatencyMs: -1,
      );
      expect(a, isNot(equals(b)));
    });

    test('toString surfaces key fields', () {
      const snapshot = EngineSnapshot.initial();
      expect(snapshot.toString(), contains('running: false'));
    });
  });
}
