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
      expect(snapshot.masterGain, 1);
      expect(snapshot.activeBackend, AudioBackend.miniaudio);
      expect(snapshot.isPerfArmed, isFalse);
      expect(snapshot.perfFrames, 0);
      expect(snapshot.perfOverruns, 0);
      // Tempo grid + click/count-in (A1/A2) grid-off defaults.
      expect(snapshot.tempoBpm, 0);
      expect(snapshot.tempoSource, TempoSource.none);
      expect(snapshot.tsNum, 4);
      expect(snapshot.tsDen, 4);
      expect(snapshot.syncTempo, isTrue);
      expect(snapshot.quantizeDiv, GridDivision.off);
      expect(snapshot.loopBars, 0);
      expect(snapshot.currentBeat, 0);
      expect(snapshot.clickMode, ClickMode.off);
      expect(snapshot.clickMask, 0);
      expect(snapshot.clickVolume, 1);
      expect(snapshot.countInBars, 0);
      expect(snapshot.countingIn, isFalse);
      expect(snapshot.countInBeatsLeft, 0);
      // Looper mode (B2a) default.
      expect(snapshot.looperMode, LooperMode.multi);
    });
  });

  group('TempoSource.fromCode', () {
    test('maps each known code', () {
      expect(TempoSource.fromCode(0), TempoSource.none);
      expect(TempoSource.fromCode(1), TempoSource.manual);
      expect(TempoSource.fromCode(2), TempoSource.tapped);
      expect(TempoSource.fromCode(3), TempoSource.derived);
      expect(TempoSource.fromCode(4), TempoSource.external);
    });

    test('falls back to none for unknown codes', () {
      expect(TempoSource.fromCode(99), TempoSource.none);
      expect(TempoSource.fromCode(-1), TempoSource.none);
    });
  });

  group('GridDivision', () {
    test('fromCode maps each known code', () {
      expect(GridDivision.fromCode(0), GridDivision.off);
      expect(GridDivision.fromCode(1), GridDivision.bar);
      expect(GridDivision.fromCode(2), GridDivision.half);
      expect(GridDivision.fromCode(3), GridDivision.quarter);
      expect(GridDivision.fromCode(4), GridDivision.eighth);
      expect(GridDivision.fromCode(5), GridDivision.sixteenth);
    });

    test('falls back to off for unknown codes', () {
      expect(GridDivision.fromCode(99), GridDivision.off);
      expect(GridDivision.fromCode(-1), GridDivision.off);
    });

    test('code round-trips through fromCode for every value', () {
      for (final div in GridDivision.values) {
        expect(GridDivision.fromCode(div.code), div);
      }
    });

    test('code matches the native le_grid_div integer values', () {
      expect(GridDivision.off.code, 0);
      expect(GridDivision.bar.code, 1);
      expect(GridDivision.half.code, 2);
      expect(GridDivision.quarter.code, 3);
      expect(GridDivision.eighth.code, 4);
      expect(GridDivision.sixteenth.code, 5);
    });
  });

  group('ClickMode', () {
    test('fromCode maps each known code', () {
      expect(ClickMode.fromCode(0), ClickMode.off);
      expect(ClickMode.fromCode(1), ClickMode.rec);
      expect(ClickMode.fromCode(2), ClickMode.recFirst);
      expect(ClickMode.fromCode(3), ClickMode.playRec);
    });

    test('falls back to off for unknown codes', () {
      expect(ClickMode.fromCode(99), ClickMode.off);
      expect(ClickMode.fromCode(-1), ClickMode.off);
    });

    test('code round-trips through fromCode for every value', () {
      for (final mode in ClickMode.values) {
        expect(ClickMode.fromCode(mode.code), mode);
      }
    });

    test('code matches the native le_click_mode integer values', () {
      expect(ClickMode.off.code, 0);
      expect(ClickMode.rec.code, 1);
      expect(ClickMode.recFirst.code, 2);
      expect(ClickMode.playRec.code, 3);
    });
  });

  group('LooperMode', () {
    test('fromCode maps each known code', () {
      expect(LooperMode.fromCode(0), LooperMode.multi);
      expect(LooperMode.fromCode(1), LooperMode.sync);
      expect(LooperMode.fromCode(2), LooperMode.song);
      expect(LooperMode.fromCode(3), LooperMode.band);
      expect(LooperMode.fromCode(4), LooperMode.free);
    });

    test('falls back to multi for unknown codes', () {
      expect(LooperMode.fromCode(99), LooperMode.multi);
      expect(LooperMode.fromCode(-1), LooperMode.multi);
    });

    test('code round-trips through fromCode for every value', () {
      for (final mode in LooperMode.values) {
        expect(LooperMode.fromCode(mode.code), mode);
      }
    });

    test('code matches the native le_looper_mode integer values', () {
      expect(LooperMode.multi.code, 0);
      expect(LooperMode.sync.code, 1);
      expect(LooperMode.song.code, 2);
      expect(LooperMode.band.code, 3);
      expect(LooperMode.free.code, 4);
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
          ..output_mask = 0x5
          ..length_preset_bars = 8;

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
        expect(track.lengthPresetBars, 8);
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

    test('a differing length preset breaks equality', () {
      final a = build();
      const b = TrackSnapshot(
        state: TrackState.playing,
        volume: 0.5,
        muted: false,
        lengthFrames: 100,
        undoDepth: 0,
        rms: 0.1,
        peak: 0.2,
        lengthPresetBars: 4,
      );
      expect(a, isNot(equals(b)));
      expect(a.hashCode, isNot(b.hashCode));
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
          ..fx_added_latency_frames = 1024
          ..master_gain = 0.5
          ..active_backend = 1
          ..perf_armed = 1
          ..perf_frames = 96000
          ..perf_overruns = 7
          ..track_count = 2
          ..tempo_bpm = 128.5
          ..ts_num = 7
          ..ts_den = 8
          ..sync_tempo = 1
          ..quantize_div = 3
          ..tempo_source = 2
          ..loop_bars = 4
          ..current_beat = 3
          ..click_mode = 1
          ..click_mask = 0x5
          ..click_volume = 0.8
          ..count_in_bars = 2
          ..counting_in = 1
          ..count_in_beats_left = 5
          ..looper_mode = 3;

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
        expect(snapshot.fxAddedLatencyFrames, 1024);
        // 1024 frames at 48 kHz ~= 21.3 ms.
        expect(snapshot.fxAddedLatencyMs, closeTo(1024 * 1000 / 48000, 1e-9));
        expect(snapshot.masterGain, closeTo(0.5, 1e-6));
        expect(snapshot.activeBackend, AudioBackend.asio);
        expect(snapshot.isPerfArmed, isTrue);
        expect(snapshot.perfFrames, 96000);
        expect(snapshot.perfOverruns, 7);
        expect(snapshot.trackCount, 2);
        // Back-compat single-track accessors read track 0.
        expect(snapshot.trackState, TrackState.playing);
        expect(snapshot.trackVolume, closeTo(0.75, 1e-6));
        expect(snapshot.trackMuted, isTrue);
        expect(snapshot.tracks, tracks);
        // Tempo grid + click/count-in (A1/A2) trailing fields.
        expect(snapshot.tempoBpm, closeTo(128.5, 1e-4));
        expect(snapshot.tsNum, 7);
        expect(snapshot.tsDen, 8);
        expect(snapshot.syncTempo, isTrue);
        expect(snapshot.quantizeDiv, GridDivision.quarter);
        expect(snapshot.tempoSource, TempoSource.tapped);
        expect(snapshot.loopBars, 4);
        expect(snapshot.currentBeat, 3);
        expect(snapshot.clickMode, ClickMode.rec);
        expect(snapshot.clickMask, 0x5);
        expect(snapshot.clickVolume, closeTo(0.8, 1e-6));
        expect(snapshot.countInBars, 2);
        expect(snapshot.countingIn, isTrue);
        expect(snapshot.countInBeatsLeft, 5);
        // Looper mode (B2a) trailing field.
        expect(snapshot.looperMode, LooperMode.band);
      } finally {
        calloc.free(ptr);
      }
    });

    test('sync_tempo == 0 maps to syncTempo false', () {
      final ptr = calloc<le_snapshot>();
      try {
        ptr.ref.sync_tempo = 0;
        expect(
          EngineSnapshot.fromNative(ptr.ref, const []).syncTempo,
          isFalse,
        );
      } finally {
        calloc.free(ptr);
      }
    });

    test('counting_in == 0 maps to countingIn false', () {
      final ptr = calloc<le_snapshot>();
      try {
        ptr.ref.counting_in = 0;
        expect(
          EngineSnapshot.fromNative(ptr.ref, const []).countingIn,
          isFalse,
        );
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

    test('active_backend maps to activeBackend (default 0 => miniaudio)', () {
      final ptr = calloc<le_snapshot>();
      try {
        // Zero-initialized struct: active_backend defaults to 0 => miniaudio.
        expect(
          EngineSnapshot.fromNative(ptr.ref, const []).activeBackend,
          AudioBackend.miniaudio,
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

    test('active_backend maps to activeBackend (1 => asio)', () {
      final ptr = calloc<le_snapshot>();
      try {
        // Zero-initialized struct: active_backend defaults to 0 => miniaudio.
        expect(
          EngineSnapshot.fromNative(ptr.ref, const []).activeBackend,
          AudioBackend.miniaudio,
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

    test('perf_armed == 0 maps to isPerfArmed false', () {
      final ptr = calloc<le_snapshot>();
      try {
        ptr.ref.perf_armed = 0;
        expect(
          EngineSnapshot.fromNative(ptr.ref, const []).isPerfArmed,
          isFalse,
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
      AudioBackend activeBackend = AudioBackend.miniaudio,
      double masterGain = 1,
      int fxAddedLatencyFrames = 0,
      int outputEnabledMask = 0xFFFFFFFF,
      bool isPerfArmed = false,
      int perfFrames = 0,
      int perfOverruns = 0,
      double tempoBpm = 0,
      TempoSource tempoSource = TempoSource.none,
      int tsNum = 4,
      int tsDen = 4,
      bool syncTempo = true,
      GridDivision quantizeDiv = GridDivision.off,
      int loopBars = 0,
      int currentBeat = 0,
      ClickMode clickMode = ClickMode.off,
      int clickMask = 0,
      double clickVolume = 1,
      int countInBars = 0,
      bool countingIn = false,
      int countInBeatsLeft = 0,
      LooperMode looperMode = LooperMode.multi,
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
      masterGain: masterGain,
      fxAddedLatencyFrames: fxAddedLatencyFrames,
      activeBackend: activeBackend,
      outputEnabledMask: outputEnabledMask,
      isPerfArmed: isPerfArmed,
      perfFrames: perfFrames,
      perfOverruns: perfOverruns,
      tempoBpm: tempoBpm,
      tempoSource: tempoSource,
      tsNum: tsNum,
      tsDen: tsDen,
      syncTempo: syncTempo,
      quantizeDiv: quantizeDiv,
      loopBars: loopBars,
      currentBeat: currentBeat,
      clickMode: clickMode,
      clickMask: clickMask,
      clickVolume: clickVolume,
      countInBars: countInBars,
      countingIn: countingIn,
      countInBeatsLeft: countInBeatsLeft,
      looperMode: looperMode,
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

    test('masterGain participates in equality', () {
      expect(build(), isNot(equals(build(masterGain: 0.5))));
    });

    test('fxAddedLatencyFrames participates in equality', () {
      expect(build(), isNot(equals(build(fxAddedLatencyFrames: 1024))));
    });

    test('outputEnabledMask participates in equality', () {
      expect(build(), isNot(equals(build(outputEnabledMask: 0x1))));
    });

    test('isPerfArmed participates in equality', () {
      expect(build(), isNot(equals(build(isPerfArmed: true))));
    });

    test('perfFrames participates in equality', () {
      expect(build(), isNot(equals(build(perfFrames: 48000))));
    });

    test('perfOverruns participates in equality', () {
      expect(build(), isNot(equals(build(perfOverruns: 3))));
    });

    test('tempoBpm participates in equality', () {
      expect(build(), isNot(equals(build(tempoBpm: 120))));
    });

    test('tempoSource participates in equality', () {
      expect(
        build(),
        isNot(equals(build(tempoSource: TempoSource.manual))),
      );
    });

    test('tsNum participates in equality', () {
      expect(build(), isNot(equals(build(tsNum: 3))));
    });

    test('tsDen participates in equality', () {
      expect(build(), isNot(equals(build(tsDen: 8))));
    });

    test('syncTempo participates in equality', () {
      expect(build(), isNot(equals(build(syncTempo: false))));
    });

    test('quantizeDiv participates in equality', () {
      expect(build(), isNot(equals(build(quantizeDiv: GridDivision.bar))));
    });

    test('loopBars participates in equality', () {
      expect(build(), isNot(equals(build(loopBars: 4))));
    });

    test('currentBeat participates in equality', () {
      expect(build(), isNot(equals(build(currentBeat: 2))));
    });

    test('clickMode participates in equality', () {
      expect(build(), isNot(equals(build(clickMode: ClickMode.rec))));
    });

    test('clickMask participates in equality', () {
      expect(build(), isNot(equals(build(clickMask: 0x3))));
    });

    test('clickVolume participates in equality', () {
      expect(build(), isNot(equals(build(clickVolume: 0.5))));
    });

    test('countInBars participates in equality', () {
      expect(build(), isNot(equals(build(countInBars: 2))));
    });

    test('countingIn participates in equality', () {
      expect(build(), isNot(equals(build(countingIn: true))));
    });

    test('countInBeatsLeft participates in equality', () {
      expect(build(), isNot(equals(build(countInBeatsLeft: 3))));
    });

    test('looperMode participates in equality', () {
      expect(build(), isNot(equals(build(looperMode: LooperMode.sync))));
    });

    test('fxAddedLatencyMs is 0 when the sample rate is unknown', () {
      // The initial snapshot has sampleRate 0; the ms getter must not divide by
      // zero (and is informational only, so 0 is the right "unknown" value).
      expect(const EngineSnapshot.initial().fxAddedLatencyMs, 0);
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
      expect(snapshot.toString(), contains('backend: miniaudio'));
    });
  });
}
