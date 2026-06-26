import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:led_client/led_client.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/led/led.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/fake_led_transport.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

LooperState _stateWith(
  List<Track> tracks, {
  int masterLengthFrames = 48000,
  bool isRunning = true,
  int sampleRate = 48000,
}) => LooperState(
  transport: TransportState(
    isRunning: isRunning,
    masterLengthFrames: masterLengthFrames,
  ),
  tracks: tracks,
  status: EngineStatus(sampleRate: sampleRate),
);

List<Track> _emptyTracks() => [for (var i = 0; i < 8; i++) Track(channel: i)];

void main() {
  group('LedCubit', () {
    late FakeLedTransport transport;
    late LedRepository led;
    late _MockLooperRepository looper;
    late StreamController<LooperState> looperStates;

    setUp(() {
      transport = FakeLedTransport();
      led = LedRepository(transport);
      looper = _MockLooperRepository();
      looperStates = StreamController<LooperState>.broadcast();
      when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
      when(() => looper.state).thenReturn(_stateWith(_emptyTracks()));
    });

    LedCubit buildCubit() => LedCubit(led: led, looper: looper);

    tearDown(() => looperStates.close());

    group('load (health handshake)', () {
      test('emits ok when the driver acknowledges', () async {
        final cubit = buildCubit();
        addTearDown(cubit.close);

        await cubit.load();

        expect(cubit.state.health, LedHealth.ok);
      });

      test('emits missing when the driver does not ack', () async {
        transport.pingAck = false;
        final cubit = buildCubit();
        addTearDown(cubit.close);

        await cubit.load();

        expect(cubit.state.health, LedHealth.missing);
      });

      test('pushes an initial frame on load', () async {
        final cubit = buildCubit();
        addTearDown(cubit.close);

        await cubit.load();

        expect(transport.sent, isNotEmpty);
      });
    });

    group('projection', () {
      test('a recording track makes the ring red and that track red', () async {
        final cubit = buildCubit();
        addTearDown(cubit.close);

        looperStates.add(
          _stateWith([
            const Track(state: TrackState.recording, lengthFrames: 48000),
            for (var i = 1; i < 8; i++) Track(channel: i),
          ]),
        );
        await pumpEventQueue();

        expect(led.lastFrame?.global, LedGlobalColor.red);
        expect(led.lastFrame?.tracks.first, LedTrackColor.red);
      });

      test('a playing track makes the ring green', () async {
        final cubit = buildCubit();
        addTearDown(cubit.close);

        looperStates.add(
          _stateWith([
            const Track(state: TrackState.playing, lengthFrames: 48000),
            for (var i = 1; i < 8; i++) Track(channel: i),
          ]),
        );
        await pumpEventQueue();

        expect(led.lastFrame?.global, LedGlobalColor.green);
        expect(led.lastFrame?.tracks.first, LedTrackColor.green);
      });

      test('recording + playing makes the ring amber', () async {
        final cubit = buildCubit();
        addTearDown(cubit.close);

        looperStates.add(
          _stateWith([
            const Track(state: TrackState.recording, lengthFrames: 48000),
            const Track(channel: 1, state: TrackState.playing),
            for (var i = 2; i < 8; i++) Track(channel: i),
          ]),
        );
        await pumpEventQueue();

        expect(led.lastFrame?.global, LedGlobalColor.amber);
      });

      test('a pure overdub makes the ring and that track amber', () async {
        final cubit = buildCubit();
        addTearDown(cubit.close);

        looperStates.add(
          _stateWith([
            const Track(state: TrackState.overdubbing, lengthFrames: 48000),
            for (var i = 1; i < 8; i++) Track(channel: i),
          ]),
        );
        await pumpEventQueue();

        expect(led.lastFrame?.global, LedGlobalColor.amber);
        expect(led.lastFrame?.tracks.first, LedTrackColor.amber);
      });

      test('all-empty tracks leave the ring off and not running', () async {
        final cubit = buildCubit();
        addTearDown(cubit.close);

        looperStates.add(_stateWith(_emptyTracks(), isRunning: false));
        await pumpEventQueue();

        expect(led.lastFrame?.global, LedGlobalColor.off);
        expect(led.lastFrame?.running, isFalse);
      });

      test('a zero sample rate yields a zero loop length', () async {
        final cubit = buildCubit();
        addTearDown(cubit.close);

        looperStates.add(_stateWith(_emptyTracks(), sampleRate: 0));
        await pumpEventQueue();

        expect(led.lastFrame?.loopLengthUs, 0);
      });

      test('a muted playing track shows no colour', () async {
        final cubit = buildCubit();
        addTearDown(cubit.close);

        looperStates.add(
          _stateWith([
            const Track(state: TrackState.playing, muted: true),
            for (var i = 1; i < 8; i++) Track(channel: i),
          ]),
        );
        await pumpEventQueue();

        expect(led.lastFrame?.tracks.first, LedTrackColor.off);
      });

      test('converts the loop length to microseconds', () async {
        final cubit = buildCubit();
        addTearDown(cubit.close);

        looperStates.add(
          _stateWith(_emptyTracks()),
        );
        await pumpEventQueue();

        // 48000 frames at 48 kHz == 1_000_000 µs.
        expect(led.lastFrame?.loopLengthUs, 1000000);
      });
    });

    test('close cancels the subscription and disposes the channel', () async {
      final cubit = buildCubit();
      await cubit.close();

      expect(transport.calls, contains('close'));
    });
  });
}
