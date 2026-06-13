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
      expect(snapshot.devicePresent, isFalse);
      expect(snapshot.sampleRate, 0);
      expect(snapshot.framesProcessed, 0);
      expect(snapshot.latencyState, LatencyState.idle);
      expect(snapshot.measuredLatencyMs, -1);
      expect(snapshot.activeBackend, AudioBackend.wasapi);
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
          ..input_mask = 0x2
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
        expect(track.inputMask, 0x2);
        expect(track.outputMask, 0x5);
        // No lanes supplied => empty list, so the derived count is 0.
        expect(track.lanes, isEmpty);
        expect(track.laneCount, 0);
      } finally {
        calloc.free(ptr);
      }
    });

    test('carries the lanes passed alongside the native struct', () {
      final ptr = calloc<le_track_snapshot>();
      try {
        const lanes = [
          LaneSnapshot(
            inputChannel: 0,
            outputMask: 0x3,
            volume: 1,
            muted: false,
            lengthFrames: 48000,
            rms: 0.2,
            peak: 0.3,
          ),
          LaneSnapshot(
            inputChannel: 1,
            outputMask: 0x1,
            volume: 0.5,
            muted: true,
            lengthFrames: 48000,
            rms: 0,
            peak: 0,
          ),
        ];

        final track = TrackSnapshot.fromNative(ptr.ref, lanes);
        expect(track.lanes, lanes);
        expect(track.lanes.first.inputChannel, 0);
        expect(track.lanes[1].muted, isTrue);
        // laneCount derives from the supplied lanes.
        expect(track.laneCount, 2);
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

  group('TrackSnapshot value semantics', () {
    TrackSnapshot build({int inputMask = 0x1, int outputMask = 0x3}) =>
        TrackSnapshot(
          state: TrackState.playing,
          volume: 0.5,
          muted: false,
          lengthFrames: 100,
          undoDepth: 0,
          rms: 0.1,
          peak: 0.2,
          inputMask: inputMask,
          outputMask: outputMask,
        );

    test('equal tracks are equal and share a hashCode', () {
      expect(build(), equals(build()));
      expect(build().hashCode, build().hashCode);
    });

    test('a differing input or output mask breaks equality', () {
      expect(build(), isNot(equals(build(inputMask: 0x2))));
      expect(build(), isNot(equals(build(outputMask: 0x1))));
    });

    TrackSnapshot withLanes(List<LaneSnapshot> lanes) => TrackSnapshot(
      state: TrackState.playing,
      volume: 0.5,
      muted: false,
      lengthFrames: 100,
      undoDepth: 0,
      rms: 0.1,
      peak: 0.2,
      lanes: lanes,
    );

    test('a differing lane count breaks equality', () {
      expect(build(), isNot(equals(withLanes(const [LaneSnapshot.empty()]))));
    });

    test('same-length lanes with differing content break equality', () {
      final a = withLanes(const [LaneSnapshot.empty()]);
      final b = withLanes(const [
        LaneSnapshot(
          inputChannel: 1,
          outputMask: 0x1,
          volume: 1,
          muted: false,
          lengthFrames: 0,
          rms: 0,
          peak: 0,
        ),
      ]);
      expect(a, isNot(equals(b)));
    });
  });

  group('LaneSnapshot', () {
    test('fromNative projects every native lane field', () {
      final ptr = calloc<le_lane_snapshot>();
      try {
        ptr.ref
          ..input_channel = 1
          ..output_mask = 0x5
          ..volume = 0.6
          ..muted = 1
          ..length_frames = 48000
          ..rms = 0.3
          ..peak = 0.45;

        final lane = LaneSnapshot.fromNative(ptr.ref);
        expect(lane.inputChannel, 1);
        expect(lane.outputMask, 0x5);
        expect(lane.volume, closeTo(0.6, 1e-6));
        expect(lane.muted, isTrue);
        expect(lane.lengthFrames, 48000);
        expect(lane.rms, closeTo(0.3, 1e-6));
        expect(lane.peak, closeTo(0.45, 1e-6));
      } finally {
        calloc.free(ptr);
      }
    });

    test('empty lane records no input', () {
      const lane = LaneSnapshot.empty();
      expect(lane.inputChannel, -1);
      expect(lane.lengthFrames, 0);
      expect(lane.muted, isFalse);
    });

    LaneSnapshot build({
      int inputChannel = 0,
      int outputMask = 0x3,
      double volume = 1,
      bool muted = false,
      double peak = 0.2,
    }) => LaneSnapshot(
      inputChannel: inputChannel,
      outputMask: outputMask,
      volume: volume,
      muted: muted,
      lengthFrames: 100,
      rms: 0.1,
      peak: peak,
    );

    test('equal lanes are equal and share a hashCode', () {
      expect(build(), equals(build()));
      expect(build().hashCode, build().hashCode);
    });

    test('any differing field breaks equality', () {
      expect(build(), isNot(equals(build(inputChannel: 1))));
      expect(build(), isNot(equals(build(outputMask: 0x1))));
      expect(build(), isNot(equals(build(volume: 0.5))));
      expect(build(), isNot(equals(build(muted: true))));
      expect(build(), isNot(equals(build(peak: 0.9))));
    });
  });

  group('EngineSnapshot.fromNative', () {
    test('projects scalar fields and the supplied tracks', () {
      final ptr = calloc<le_snapshot>();
      try {
        ptr.ref
          ..running = 1
          ..device_present = 1
          ..sample_rate = 48000
          ..buffer_frames = 128
          ..input_channels = 2
          ..output_channels = 4
          ..excluded_input_mask = 0x4
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
          ..active_backend = 1
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
        expect(snapshot.devicePresent, isTrue);
        expect(snapshot.sampleRate, 48000);
        expect(snapshot.inputChannels, 2);
        expect(snapshot.outputChannels, 4);
        expect(snapshot.excludedInputMask, 0x4);
        expect(snapshot.framesProcessed, 123456);
        expect(snapshot.latencyState, LatencyState.done);
        expect(snapshot.measuredLatencyMs, closeTo(7.5, 1e-9));
        expect(snapshot.masterLengthFrames, 96000);
        expect(snapshot.recordOffsetFrames, 480);
        expect(snapshot.activeBackend, AudioBackend.asio);
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

    test('active_backend maps to activeBackend (default 0 => wasapi)', () {
      final ptr = calloc<le_snapshot>();
      try {
        // Zero-initialized struct: active_backend defaults to 0 => WASAPI.
        expect(
          EngineSnapshot.fromNative(ptr.ref, const []).activeBackend,
          AudioBackend.wasapi,
        );
        ptr.ref.active_backend = 1;
        expect(
          EngineSnapshot.fromNative(ptr.ref, const []).activeBackend,
          AudioBackend.asio,
        );
      } finally {
        calloc.free(ptr);
      }
    });

    test('active_backend maps to activeBackend (default 0 => wasapi)', () {
      final ptr = calloc<le_snapshot>();
      try {
        // Zero-initialized struct: active_backend defaults to 0 => wasapi.
        expect(
          EngineSnapshot.fromNative(ptr.ref, const []).activeBackend,
          AudioBackend.wasapi,
        );
        ptr.ref.active_backend = 1;
        expect(
          EngineSnapshot.fromNative(ptr.ref, const []).activeBackend,
          AudioBackend.asio,
        );
      } finally {
        calloc.free(ptr);
      }
    });

    test('device_present is independent of running', () {
      final ptr = calloc<le_snapshot>();
      try {
        // A device can be lost (device_present == 0) while the engine object
        // still reports running == 1.
        ptr.ref
          ..running = 1
          ..device_present = 0;
        final snapshot = EngineSnapshot.fromNative(ptr.ref, const []);
        expect(snapshot.isRunning, isTrue);
        expect(snapshot.devicePresent, isFalse);
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

    // Distinct (non-const) instances so the `==` body runs rather than being
    // short-circuited by `identical`, exercising every field comparison.
    EngineSnapshot build({
      bool devicePresent = true,
      AudioBackend activeBackend = AudioBackend.wasapi,
    }) => EngineSnapshot(
      isRunning: true,
      devicePresent: devicePresent,
      sampleRate: 48000,
      bufferFrames: 128,
      framesProcessed: 10,
      xrunCount: 0,
      inputRms: 0,
      inputPeak: 0,
      outputRms: 0,
      latencyState: LatencyState.idle,
      measuredLatencyMs: -1,
      activeBackend: activeBackend,
    );

    test('distinct equal snapshots compare equal and share a hashCode', () {
      expect(build(), equals(build()));
      expect(build().hashCode, build().hashCode);
    });

    test('devicePresent participates in equality', () {
      expect(build(), isNot(equals(build(devicePresent: false))));
    });

    test('activeBackend participates in equality', () {
      expect(
        build(),
        isNot(equals(build(activeBackend: AudioBackend.asio))),
      );
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
      expect(snapshot.toString(), contains('backend: wasapi'));
    });
  });
}
