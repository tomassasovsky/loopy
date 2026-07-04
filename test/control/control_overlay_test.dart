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
  group('ControlOverlay', () {
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

    ControlOverlay buildOverlay() => ControlOverlay(looper: looper);

    test('starts at the home overlay: record mode, cursor 0, bank A', () {
      final overlay = buildOverlay();
      expect(overlay.state, const ControlOverlayState());
      expect(overlay.state.mode, LooperMode.record);
      expect(overlay.state.cursor, 0);
      expect(overlay.state.activeBank, 0);
      expect(overlay.state.excluded, isEmpty);
      expect(overlay.state.parkedResume, isEmpty);
    });

    test('selectTrack moves the cursor into its bank', () async {
      final overlay = buildOverlay()..selectTrack(5);
      expect(overlay.state.cursor, 5);
      expect(overlay.state.activeBank, 1);
      expect(overlay.state.bankBaseChannel, 4);
      expect(overlay.state.bankContains(5), isTrue);
      expect(overlay.state.bankContains(2), isFalse);

      overlay.selectTrack(2);
      expect(overlay.state.cursor, 2);
      expect(overlay.state.activeBank, 0);
      await overlay.dispose();
    });

    test('selectTrack ignores out-of-range channels', () async {
      final overlay = buildOverlay()
        ..selectTrack(-1)
        ..selectTrack(8);
      expect(overlay.state.cursor, 0);
      await overlay.dispose();
    });

    test('browseBank reveals the bank WITHOUT moving the cursor', () async {
      final overlay = buildOverlay()..browseBank(1);
      expect(overlay.state.activeBank, 1);
      expect(overlay.state.cursor, 0); // browse only

      overlay
        ..browseBank(-1)
        ..browseBank(2);
      expect(overlay.state.activeBank, 1); // out-of-range ignored
      await overlay.dispose();
    });

    test('applyMode sets the mode and resets stored play intent', () async {
      final overlay = buildOverlay()
        ..toggleParkedResume(3)
        ..applyMode(LooperMode.play, parkedResume: const {0, 1});
      expect(overlay.state.mode, LooperMode.play);
      expect(overlay.state.excluded, isEmpty);
      expect(overlay.state.parkedResume, {0, 1});

      overlay.applyMode(LooperMode.record, parkedResume: const {});
      expect(overlay.state.mode, LooperMode.record);
      expect(overlay.state.parkedResume, isEmpty);
      await overlay.dispose();
    });

    test('setDefaultMode records the boot default only', () async {
      final overlay = buildOverlay()..setDefaultMode(LooperMode.play);
      expect(overlay.state.defaultMode, LooperMode.play);
      expect(overlay.state.mode, LooperMode.record); // live mode untouched
      await overlay.dispose();
    });

    test(
      'latchParkedResume / toggleParkedResume edit the resume set',
      () async {
        final overlay = buildOverlay()..latchParkedResume(const {0, 2});
        expect(overlay.state.parkedResume, {0, 2});

        overlay.toggleParkedResume(2);
        expect(overlay.state.parkedResume, {0});

        overlay.toggleParkedResume(1);
        expect(overlay.state.parkedResume, {0, 1});
        await overlay.dispose();
      },
    );

    test('include removes a channel from the exclusions', () async {
      final overlay = buildOverlay()
        ..applyMode(LooperMode.play, parkedResume: const {})
        ..include(3); // not excluded: no-op
      expect(overlay.state.excluded, isEmpty);
      await overlay.dispose();
    });

    test('resetForClearAll returns the whole overlay home', () async {
      final overlay = buildOverlay()
        ..applyMode(LooperMode.play, parkedResume: const {0, 1})
        ..selectTrack(6)
        ..resetForClearAll();
      expect(overlay.state.mode, LooperMode.record);
      expect(overlay.state.cursor, 0);
      expect(overlay.state.activeBank, 0);
      expect(overlay.state.excluded, isEmpty);
      expect(overlay.state.parkedResume, isEmpty);
      await overlay.dispose();
    });

    group('looper reducer (the invalidation table)', () {
      test('clamps the cursor when the track list shrinks', () async {
        final overlay = buildOverlay()..selectTrack(7);
        expect(overlay.state.cursor, 7);

        looperStates.add(_stateWith(_emptyTracks(4)));
        expect(overlay.state.cursor, 3);
        expect(overlay.state.activeBank, 0); // follows the clamped cursor
        await overlay.dispose();
      });

      test('prunes excluded and parkedResume of emptied tracks', () async {
        final overlay = buildOverlay()..latchParkedResume(const {0, 1});
        // Track 0 keeps content; track 1 empties (undo-to-empty / clear).
        looperStates.add(
          _stateWith([
            const Track(state: TrackState.stopped, lengthFrames: 48000),
            for (var i = 1; i < 8; i++) Track(channel: i),
          ]),
        );
        expect(overlay.state.parkedResume, {0});
        await overlay.dispose();
      });

      test('keeps capturing tracks in the stored sets', () async {
        final overlay = buildOverlay()..latchParkedResume(const {0});
        looperStates.add(
          _stateWith([
            const Track(state: TrackState.recording), // finishing a loop
            for (var i = 1; i < 8; i++) Track(channel: i),
          ]),
        );
        expect(overlay.state.parkedResume, {0});
        await overlay.dispose();
      });

      test('a no-change snapshot does not notify', () async {
        final overlay = buildOverlay();
        final emits = <ControlOverlayState>[];
        overlay.addListener(emits.add);

        looperStates.add(_stateWith(_emptyTracks()));
        expect(emits, isEmpty);

        overlay.removeListener(emits.add);
        await overlay.dispose();
      });
    });

    test('close cancels the looper subscription', () async {
      final overlay = buildOverlay();
      await overlay.dispose();
      // Emitting after close must not throw (the subscription is gone).
      looperStates.add(_stateWith(_emptyTracks(4)));
      expect(overlay.state.cursor, 0);
    });
  });
}
