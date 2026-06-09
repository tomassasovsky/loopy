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

  group('TrackSnapshot.fromNative', () {
    test('projects every native track field', () {
      final ptr = calloc<le_track_snapshot>();
      try {
        ptr.ref
          ..state = 3
          ..volume = 0.75
          ..muted = 1
          ..length_frames = 96000
          ..multiple = 2
          ..undo_depth = 1
          ..redo_depth = 2
          ..rms = 0.4
          ..peak = 0.6
          ..input_channel = 1
          ..output_mask = 0x5;

        final track = TrackSnapshot.fromNative(ptr.ref);
        expect(track.state, TrackState.playing);
        expect(track.volume, closeTo(0.75, 1e-6));
        expect(track.muted, isTrue);
        expect(track.lengthFrames, 96000);
        expect(track.multiple, 2);
        expect(track.undoDepth, 1);
        expect(track.redoDepth, 2);
        expect(track.rms, closeTo(0.4, 1e-6));
        expect(track.peak, closeTo(0.6, 1e-6));
        expect(track.inputChannel, 1);
        expect(track.outputMask, 0x5);
      } finally {
        calloc.free(ptr);
      }
    });

    test('maps every TrackState code', () {
      expect(TrackState.fromCode(0), TrackState.empty);
      expect(TrackState.fromCode(1), TrackState.recording);
      expect(TrackState.fromCode(2), TrackState.overdubbing);
      expect(TrackState.fromCode(3), TrackState.playing);
      expect(TrackState.fromCode(4), TrackState.stopped);
      expect(TrackState.fromCode(99), TrackState.empty);
    });
  });

  group('EngineSnapshot.fromNative', () {
    test('projects scalar fields and the supplied tracks', () {
      final ptr = calloc<le_snapshot>();
      try {
        ptr.ref
          ..running = 1
          ..sample_rate = 48000
          ..buffer_frames = 128
          ..input_channels = 2
          ..output_channels = 4
          ..frames_processed = 123456
          ..xrun_count = 3
          ..input_rms = 0.25
          ..input_peak = 0.5
          ..output_rms = 0.125
          ..latency_state = 2
          ..measured_latency_ms = 7.5
          ..master_length_frames = 96000
          ..master_position_frames = 1200
          ..record_offset_frames = 480
          ..track_count = 2;

        const tracks = [
          TrackSnapshot(
            state: TrackState.playing,
            volume: 0.75,
            muted: true,
            lengthFrames: 96000,
            undoDepth: 1,
            rms: 0.4,
            peak: 0.6,
          ),
          TrackSnapshot.empty(),
        ];
        final snapshot = EngineSnapshot.fromNative(ptr.ref, tracks);

        expect(snapshot.isRunning, isTrue);
        expect(snapshot.sampleRate, 48000);
        expect(snapshot.inputChannels, 2);
        expect(snapshot.outputChannels, 4);
        expect(snapshot.framesProcessed, 123456);
        expect(snapshot.latencyState, LatencyState.done);
        expect(snapshot.measuredLatencyMs, closeTo(7.5, 1e-9));
        expect(snapshot.masterLengthFrames, 96000);
        expect(snapshot.recordOffsetFrames, 480);
        expect(snapshot.trackCount, 2);
        // Back-compat single-track accessors read track 0.
        expect(snapshot.trackState, TrackState.playing);
        expect(snapshot.trackVolume, closeTo(0.75, 1e-6));
        expect(snapshot.trackMuted, isTrue);
        expect(snapshot.tracks, tracks);
      } finally {
        calloc.free(ptr);
      }
    });

    test('maps running == 0 to isRunning false', () {
      final ptr = calloc<le_snapshot>();
      try {
        ptr.ref.running = 0;
        expect(
          EngineSnapshot.fromNative(ptr.ref, const []).isRunning,
          isFalse,
        );
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
