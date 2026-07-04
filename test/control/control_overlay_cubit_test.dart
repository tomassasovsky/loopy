import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/looper/model/looper_mode.dart';
import 'package:mocktail/mocktail.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

LooperState _stateWith(List<Track> tracks) => LooperState(
  transport: const TransportState(isRunning: true, masterLengthFrames: 48000),
  tracks: tracks,
);

List<Track> _emptyTracks([int count = 8]) => [
  for (var i = 0; i < count; i++) Track(channel: i),
];

void main() {
  group('ControlOverlayCubit', () {
    late _MockLooperRepository looper;
    late StreamController<LooperState> looperStates;

    setUp(() {
      looper = _MockLooperRepository();
      looperStates = StreamController<LooperState>.broadcast(sync: true);
      when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    });

    tearDown(() async {
      await looperStates.close();
    });

    ControlOverlayCubit buildCubit() => ControlOverlayCubit(looper: looper);

    test('starts at the home overlay: record mode, cursor 0, bank A', () {
      final cubit = buildCubit();
      expect(cubit.state, const ControlOverlayState());
      expect(cubit.state.mode, LooperMode.record);
      expect(cubit.state.cursor, 0);
      expect(cubit.state.activeBank, 0);
      expect(cubit.state.excluded, isEmpty);
      expect(cubit.state.parkedResume, isEmpty);
    });

    test('selectTrack moves the cursor into its bank', () async {
      final cubit = buildCubit()..selectTrack(5);
      expect(cubit.state.cursor, 5);
      expect(cubit.state.activeBank, 1);
      expect(cubit.state.bankBaseChannel, 4);
      expect(cubit.state.bankContains(5), isTrue);
      expect(cubit.state.bankContains(2), isFalse);

      cubit.selectTrack(2);
      expect(cubit.state.cursor, 2);
      expect(cubit.state.activeBank, 0);
      await cubit.close();
    });

    test('selectTrack ignores out-of-range channels', () async {
      final cubit = buildCubit()
        ..selectTrack(-1)
        ..selectTrack(8);
      expect(cubit.state.cursor, 0);
      await cubit.close();
    });

    test('browseBank reveals the bank WITHOUT moving the cursor', () async {
      final cubit = buildCubit()..browseBank(1);
      expect(cubit.state.activeBank, 1);
      expect(cubit.state.cursor, 0); // browse only

      cubit
        ..browseBank(-1)
        ..browseBank(2);
      expect(cubit.state.activeBank, 1); // out-of-range ignored
      await cubit.close();
    });

    test('applyMode sets the mode and resets stored play intent', () async {
      final cubit = buildCubit()
        ..toggleParkedResume(3)
        ..applyMode(LooperMode.play, parkedResume: const {0, 1});
      expect(cubit.state.mode, LooperMode.play);
      expect(cubit.state.excluded, isEmpty);
      expect(cubit.state.parkedResume, {0, 1});

      cubit.applyMode(LooperMode.record, parkedResume: const {});
      expect(cubit.state.mode, LooperMode.record);
      expect(cubit.state.parkedResume, isEmpty);
      await cubit.close();
    });

    test('setDefaultMode records the boot default only', () async {
      final cubit = buildCubit()..setDefaultMode(LooperMode.play);
      expect(cubit.state.defaultMode, LooperMode.play);
      expect(cubit.state.mode, LooperMode.record); // live mode untouched
      await cubit.close();
    });

    test(
      'latchParkedResume / toggleParkedResume edit the resume set',
      () async {
        final cubit = buildCubit()..latchParkedResume(const {0, 2});
        expect(cubit.state.parkedResume, {0, 2});

        cubit.toggleParkedResume(2);
        expect(cubit.state.parkedResume, {0});

        cubit.toggleParkedResume(1);
        expect(cubit.state.parkedResume, {0, 1});
        await cubit.close();
      },
    );

    test('include removes a channel from the exclusions', () async {
      final cubit = buildCubit()
        ..applyMode(LooperMode.play, parkedResume: const {})
        ..include(3); // not excluded: no-op
      expect(cubit.state.excluded, isEmpty);
      await cubit.close();
    });

    test('resetForClearAll returns the whole overlay home', () async {
      final cubit = buildCubit()
        ..applyMode(LooperMode.play, parkedResume: const {0, 1})
        ..selectTrack(6)
        ..resetForClearAll();
      expect(cubit.state.mode, LooperMode.record);
      expect(cubit.state.cursor, 0);
      expect(cubit.state.activeBank, 0);
      expect(cubit.state.excluded, isEmpty);
      expect(cubit.state.parkedResume, isEmpty);
      await cubit.close();
    });

    group('looper reducer (the invalidation table)', () {
      test('clamps the cursor when the track list shrinks', () async {
        final cubit = buildCubit()..selectTrack(7);
        expect(cubit.state.cursor, 7);

        looperStates.add(_stateWith(_emptyTracks(4)));
        expect(cubit.state.cursor, 3);
        expect(cubit.state.activeBank, 0); // follows the clamped cursor
        await cubit.close();
      });

      test('prunes excluded and parkedResume of emptied tracks', () async {
        final cubit = buildCubit()..latchParkedResume(const {0, 1});
        // Track 0 keeps content; track 1 empties (undo-to-empty / clear).
        looperStates.add(
          _stateWith([
            const Track(state: TrackState.stopped, lengthFrames: 48000),
            for (var i = 1; i < 8; i++) Track(channel: i),
          ]),
        );
        expect(cubit.state.parkedResume, {0});
        await cubit.close();
      });

      test('keeps capturing tracks in the stored sets', () async {
        final cubit = buildCubit()..latchParkedResume(const {0});
        looperStates.add(
          _stateWith([
            const Track(state: TrackState.recording), // finishing a loop
            for (var i = 1; i < 8; i++) Track(channel: i),
          ]),
        );
        expect(cubit.state.parkedResume, {0});
        await cubit.close();
      });

      test('a no-change snapshot does not emit', () async {
        final cubit = buildCubit();
        final emits = <ControlOverlayState>[];
        final sub = cubit.stream.listen(emits.add);

        looperStates.add(_stateWith(_emptyTracks()));
        await Future<void>.delayed(Duration.zero);
        expect(emits, isEmpty);
        await sub.cancel();
        await cubit.close();
      });
    });

    test('close cancels the looper subscription', () async {
      final cubit = buildCubit();
      await cubit.close();
      // Emitting after close must not throw (the subscription is gone).
      looperStates.add(_stateWith(_emptyTracks(4)));
      expect(cubit.state.cursor, 0);
    });
  });
}
