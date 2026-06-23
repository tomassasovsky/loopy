import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart' show MonitorState;
import 'package:loopy/looper/view/signal_graph/signal_rows.dart';

void main() {
  group('SignalRows.from', () {
    const status = EngineStatus(
      inputChannels: 4,
      outputChannels: 4,
      isConnected: true,
    );

    test('builds one input row per channel with routed-output tags', () {
      const monitor = MonitorState(
        inputs: {
          0: InputMonitor(input: 0, enabled: true),
        },
      );
      final rows = SignalRows.from(
        monitor,
        const LooperState(status: status),
      );

      expect(rows.inputs, hasLength(4));
      expect(rows.inputCount, 4);
      final in0 = rows.inputs.first;
      expect(in0.routes, [0, 1]); // mask 0x3 -> outs 0 and 1
      expect(in0.tags, {inTag(0), outTag(0), outTag(1)});
    });

    test('marks loopback inputs excluded with no routes', () {
      const monitor = MonitorState();
      final rows = SignalRows.from(
        monitor,
        const LooperState(
          status: EngineStatus(
            inputChannels: 4,
            outputChannels: 2,
            excludedInputMask: 0x4, // input 2 is loopback
          ),
        ),
      );

      expect(rows.inputs[2].excluded, isTrue);
      expect(rows.inputs[2].routes, isEmpty);
      expect(rows.inputs[2].tags, {inTag(2)});
    });

    test('collapses a single-lane track and tags its take', () {
      final rows = SignalRows.from(
        const MonitorState(),
        const LooperState(
          tracks: [
            Track(lanes: [Lane(inputChannel: 1, outputMask: 0x2)]),
          ],
          status: status,
        ),
      );

      expect(rows.tracks, hasLength(1));
      final g = rows.tracks.first;
      expect(g.single, isTrue);
      expect(g.takes, hasLength(1));
      expect(g.takes.first.tags, {trkTag(0), inTag(1), outTag(1)});
    });

    test('keeps a multi-lane track as nested takes', () {
      final rows = SignalRows.from(
        const MonitorState(),
        const LooperState(
          tracks: [
            Track(
              lanes: [Lane(inputChannel: 0), Lane(inputChannel: 1)],
            ),
          ],
          status: status,
        ),
      );

      final g = rows.tracks.first;
      expect(g.single, isFalse);
      expect(g.takes, hasLength(2));
      expect(g.takes[1].laneIndex, 1);
    });

    test('skips laneless tracks', () {
      final rows = SignalRows.from(
        const MonitorState(),
        const LooperState(
          tracks: [
            Track(),
            Track(channel: 1, lanes: [Lane()]),
          ],
          status: status,
        ),
      );

      expect(rows.tracks, hasLength(1));
      expect(rows.tracks.first.track, 1);
    });

    test('reflects each output gate', () {
      final rows = SignalRows.from(
        const MonitorState(),
        const LooperState(
          status: status,
          outputEnabledMask: 0x5, // outs 0 and 2 on
        ),
      );

      expect(rows.outputs.map((o) => o.enabled), [true, false, true, false]);
    });

    test('derives feeders for an output (inputs + tracks)', () {
      const monitor = MonitorState(
        inputs: {0: InputMonitor(input: 0, enabled: true, outputMask: 0x2)},
      );
      final rows = SignalRows.from(
        monitor,
        const LooperState(
          tracks: [
            Track(lanes: [Lane(inputChannel: 3, outputMask: 0x2)]),
          ],
          status: status,
        ),
      );

      expect(rows.inputsFeeding(1), [0]); // In 0 -> Out 1
      expect(rows.tracksFeeding(1), [0]); // Track 0 -> Out 1
      expect(rows.inputsFeeding(0), isEmpty);
    });

    test('falls back to 4 in / 2 out when the engine is stopped', () {
      final rows = SignalRows.from(
        const MonitorState(),
        const LooperState(),
      );
      expect(rows.inputCount, 4);
      expect(rows.outputCount, 2);
    });
  });

  group('TraceState', () {
    test('inactive lights nothing', () {
      const t = TraceState.none();
      expect(t.active, isFalse);
      expect(t.lit({inTag(0)}), isFalse);
    });

    test('lights rows sharing any lit tag', () {
      final t = TraceState({outTag(1)});
      expect(t.active, isTrue);
      expect(t.lit({inTag(0), outTag(1)}), isTrue);
      expect(t.lit({inTag(0)}), isFalse);
    });
  });
}
