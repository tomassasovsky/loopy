import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/looper/model/interaction_mode.dart';
import 'package:midi_client/midi_client.dart' show MidiDevice;
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';
import '../pedal/helpers/fake_pedal_transport.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// A real [PerformanceRepository] that additionally logs when
/// [persistLiveLanes] runs, into a shared [log] list — proves the D-CLEAR
/// ordering (persist-before-clear) without mocking file I/O, since the
/// repository itself is not mock-friendly (real disk access).
class _RecordingPerformanceRepository extends PerformanceRepository {
  _RecordingPerformanceRepository({
    required this.log,
    required super.engine,
    required super.exportsRoot,
  });

  final List<String> log;

  @override
  Future<void> persistLiveLanes() async {
    log.add('persistLiveLanes');
    await super.persistLiveLanes();
  }
}

LooperState _stateWith(
  List<Track> tracks, {
  int masterLengthFrames = 48000,
  int masterPositionFrames = 0,
  int sampleRate = 48000,
}) => LooperState(
  transport: TransportState(
    isRunning: true,
    masterLengthFrames: masterLengthFrames,
    masterPositionFrames: masterPositionFrames,
  ),
  tracks: tracks,
  status: EngineStatus(sampleRate: sampleRate),
);

List<Track> _emptyTracks([int count = 8]) => [
  for (var i = 0; i < count; i++) Track(channel: i),
];

List<Track> _tracksWith(List<Track> overrides) => [
  for (var i = 0; i < 8; i++)
    overrides.firstWhere(
      (t) => t.channel == i,
      orElse: () => Track(channel: i),
    ),
];

/// The ONE control-surface interpreter, tested over mocked engine truth: the
/// intent methods (shared by keyboard / on-screen surfaces), the stored-
/// intent invalidation reducer, and the pedal I/O it owns through
/// [PedalRepository] — footswitch decode in, projected LED frames out.
void main() {
  group('ControlCubit', () {
    late _MockLooperRepository looper;
    late StreamController<LooperState> looperStates;
    late SettingsRepository settings;
    late FakePedalTransport transport;
    late PedalRepository pedal;
    late PerformanceRepository performance;
    late ControlCubit cubit;
    late Directory tempDir;
    late DateTime clock;

    /// The repository's remembered Track-chain intent, stubbed as real state
    /// (absence == enabled) so a stomp's read-modify-write behaves like the
    /// live repository rather than a frozen `true`.
    late Map<int, bool> chainEnabled;

    /// The Track-stage chains the repository reports per channel.
    late Map<int, List<TrackEffect>> trackChains;

    /// Publishes [tracks] as engine truth: both the pull (`looper.state`) and
    /// the push (the cubit's reducer subscription) see the same snapshot.
    void setEngine(
      List<Track> tracks, {
      int masterPositionFrames = 0,
    }) {
      final state = _stateWith(
        tracks,
        masterPositionFrames: masterPositionFrames,
      );
      when(() => looper.state).thenReturn(state);
      looperStates.add(state);
    }

    setUp(() {
      looper = _MockLooperRepository();
      looperStates = StreamController<LooperState>.broadcast(sync: true);
      settings = SettingsRepository(store: FakeKeyValueStore());
      transport = FakePedalTransport(
        outputs: const [MidiDevice(id: 'out', name: 'Pedal')],
      );
      pedal = PedalRepository(transport);
      when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
      for (final stub in [
        () => looper.record(channel: any(named: 'channel')),
        () => looper.undo(channel: any(named: 'channel')),
        () => looper.redo(channel: any(named: 'channel')),
        () => looper.clear(channel: any(named: 'channel')),
        () => looper.play(channel: any(named: 'channel')),
        () => looper.stopTrack(channel: any(named: 'channel')),
      ]) {
        when(stub).thenReturn(EngineResult.ok);
      }
      when(
        () => looper.setMute(
          muted: any(named: 'muted'),
          channel: any(named: 'channel'),
        ),
      ).thenReturn(EngineResult.ok);
      when(() => looper.setMasterGain(any())).thenReturn(EngineResult.ok);
      when(
        () => looper.cancelArm(channel: any(named: 'channel')),
      ).thenReturn(EngineResult.ok);

      chainEnabled = <int, bool>{};
      when(() => looper.trackChainEnabled(any())).thenAnswer(
        (call) => chainEnabled[call.positionalArguments.first as int] ?? true,
      );
      when(
        () => looper.setTrackChainEnabled(
          channel: any(named: 'channel'),
          enabled: any(named: 'enabled'),
        ),
      ).thenAnswer((call) {
        chainEnabled[call.namedArguments[#channel] as int] =
            call.namedArguments[#enabled] as bool;
        return EngineResult.ok;
      });
      // Which channels actually HAVE a Track-stage chain. Empty by default —
      // a sweep must leave a chain-less track alone, so tests that want one
      // flipped have to give it a chain first.
      trackChains = <int, List<TrackEffect>>{};
      when(() => looper.trackEffects(any())).thenAnswer(
        (call) =>
            trackChains[call.positionalArguments.first as int] ??
            const <TrackEffect>[],
      );
      // Which channels the rig has a Track-stage chain on at all — what the
      // binding resolver consults to tell an absent chain (a stale target)
      // from a configured-but-empty one.
      when(() => looper.allTrackChains()).thenAnswer(
        (_) => {
          for (final channel in trackChains.keys)
            channel: const FxChainEnvelope(),
        },
      );
      when(
        () => looper.setTrackEffectEnabled(
          channel: any(named: 'channel'),
          index: any(named: 'index'),
          enabled: any(named: 'enabled'),
        ),
      ).thenAnswer((call) {
        final channel = call.namedArguments[#channel] as int;
        final index = call.namedArguments[#index] as int;
        final chain = trackChains[channel];
        if (chain == null || index < 0 || index >= chain.length) {
          return EngineResult.invalid;
        }
        trackChains[channel] = List<TrackEffect>.of(chain)
          ..[index] = (chain[index] as BuiltInEffect).copyWith(
            enabled: call.namedArguments[#enabled] as bool,
          );
        return EngineResult.ok;
      });

      tempDir = Directory.systemTemp.createTempSync('loopy_control_cubit');
      clock = DateTime(2026, 7, 6, 14, 30, 15);
      performance = PerformanceRepository(
        engine: FakeAudioEngine(),
        exportsRoot: () async => tempDir.path,
        now: () => clock,
      );
      cubit = ControlCubit(
        looper: looper,
        pedal: pedal,
        settings: settings,
        performance: performance,
        keepAliveInterval: Duration.zero, // deterministic: no heartbeat re-push
      );
      setEngine(_emptyTracks());
    });

    tearDown(() async {
      await cubit.close();
      await pedal.dispose();
      await looperStates.close();
      performance.dispose();
      tempDir.deleteSync(recursive: true);
    });

    group('mode', () {
      test('toggleMode cycles Record -> Mute -> FX -> Record', () {
        expect(cubit.state.mode, InteractionMode.record);
        cubit.toggleMode();
        expect(cubit.state.mode, InteractionMode.mute);
        cubit.toggleMode();
        expect(cubit.state.mode, InteractionMode.fx);
        cubit.toggleMode();
        expect(cubit.state.mode, InteractionMode.record);
      });

      test('entering Mute previews the whole content set as parkedResume', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(
              channel: 2,
              state: TrackState.stopped,
              muted: true,
              lengthFrames: 48000,
            ),
          ]),
        );
        cubit.toggleMode();
        // Stopped and muted content is included — Rec/Play resumes it all.
        expect(cubit.state.parkedResume, {0, 2});
      });

      test('entering Mute leaves a live capture recording (the mode toggle '
          'is a view change, not a transport action)', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        cubit.toggleMode();
        // No finalize: the take keeps recording until the user ends it
        // explicitly (back in Rec mode, Rec/Play — or Stop).
        verifyNever(() => looper.record(channel: any(named: 'channel')));
        verifyNever(() => looper.record());
        expect(cubit.state.mode, InteractionMode.mute);
        // The capture still previews as a parked-resume member.
        expect(cubit.state.parkedResume, {0});
      });

      test('setMode to the current mode is a no-op', () {
        cubit.setMode(InteractionMode.record);
        verifyNever(() => looper.record(channel: any(named: 'channel')));
        expect(cubit.state.mode, InteractionMode.record);
      });

      test('setDefaultMode persists the token and applies the mode', () async {
        await cubit.setDefaultMode(InteractionMode.mute);
        expect(cubit.state.defaultMode, InteractionMode.mute);
        expect(cubit.state.mode, InteractionMode.mute);
        expect(
          await settings.loadDefaultInteractionMode(),
          InteractionMode.mute.token,
        );
      });

      test('load boots the live mode into the persisted default', () async {
        await settings.saveDefaultInteractionMode(InteractionMode.mute.token);
        await cubit.load();
        expect(cubit.state.defaultMode, InteractionMode.mute);
        expect(cubit.state.mode, InteractionMode.mute);
      });

      test('load boots into mute from the legacy persisted token "play" '
          '(pre-rename installs)', () async {
        await settings.saveDefaultInteractionMode('play');
        await cubit.load();
        expect(cubit.state.defaultMode, InteractionMode.mute);
        expect(cubit.state.mode, InteractionMode.mute);
      });

      test('toggleMode does not change the persisted default mode', () async {
        cubit.toggleMode();
        expect(cubit.state.mode, InteractionMode.mute);
        expect(cubit.state.defaultMode, InteractionMode.record);
        expect(await settings.loadDefaultInteractionMode(), isNull);
      });

      test('entering FX mode leaves a LIVE capture running, exactly as Mute '
          'does — the mode toggle is not a transport action', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        cubit.setMode(InteractionMode.fx);
        // Ending it here needs a finalize that ignores quantize, and the only
        // tool available (a record press) ARMS a loop-top finalize instead —
        // which left the take running anyway AND re-armed the track. Until an
        // engine primitive exists, FX matches Mute: the take ends when the
        // user cycles back to Rec.
        verifyNever(() => looper.record(channel: any(named: 'channel')));
        verifyNever(() => looper.record());
        expect(cubit.state.mode, InteractionMode.fx);
      });

      test(
        'entering FX mode CANCELS a pending arm rather than recording it',
        () {
          setEngine(
            _tracksWith(const [Track(pending: true)]),
          );
          // The arm has not fired, so nothing is "capturing" — but leaving it
          // would start a take seconds later with every FX-mode control inert.
          cubit.setMode(InteractionMode.fx);

          // The distinction is the whole point: `record()` is only a cancel
          // for an arm whose trigger it owns, and only while the conditions
          // that created the arm still hold — with the transport parked the
          // same call STARTS the capture (pinned natively by
          // test_record_press_on_pending_arm_starts_when_parked). Asserting
          // "a record command was issued" cannot tell those apart, so pin the
          // unconditional cancel instead.
          verify(() => looper.cancelArm(channel: 0)).called(1);
          verifyNever(() => looper.record(channel: any(named: 'channel')));
          verifyNever(() => looper.record());
        },
      );

      test('an armed PUNCH-OUT on a capturing track has its arm cancelled and '
          'the take left alone', () {
        // pending AND capturing at once: a quantized punch-out waiting for the
        // loop top. Only the arm is retired — re-pressing record here would
        // have re-armed the very thing just cancelled.
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.overdubbing, pending: true),
          ]),
        );
        cubit.setMode(InteractionMode.fx);

        verify(() => looper.cancelArm(channel: 0)).called(1);
        verifyNever(() => looper.record(channel: any(named: 'channel')));
        verifyNever(() => looper.record());
      });

      test('entering FX mode reads LIVE engine truth for the arm sweep, not '
          'the polled snapshot', () {
        // The polled snapshot still shows an arm the engine has already
        // retired; the live read is what the sweep must follow.
        looperStates.add(
          _stateWith(_tracksWith(const [Track(pending: true)])),
        );
        when(() => looper.state).thenReturn(
          _stateWith(
            _tracksWith(const [
              Track(state: TrackState.playing, lengthFrames: 48000),
            ]),
          ),
        );

        cubit.setMode(InteractionMode.fx);

        verifyNever(() => looper.cancelArm(channel: any(named: 'channel')));
      });

      test('entering FX mode with nothing capturing touches the transport '
          'not at all', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit.setMode(InteractionMode.fx);
        verifyNever(() => looper.record(channel: any(named: 'channel')));
        verifyNever(() => looper.record());
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
      });

      test('side effects fire for the LANDED mode only — the cycle never '
          'runs an intermediate mode entry (A5)', () async {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        // Watch the EMITTED states, not just the final one: an implementation
        // that walked the cycle (setMode(mute) then setMode(fx)) would land
        // the same way while firing mute's entry on the way through, and a
        // final-state assertion could never see it — fx's own entry clears
        // exactly what mute's would have latched.
        final seen = <(InteractionMode, Set<int>)>[];
        final sub = cubit.stream.listen(
          (s) => seen.add((s.mode, s.parkedResume)),
        );
        addTearDown(() => unawaited(sub.cancel()));

        cubit
          ..toggleMode() // -> mute, which DOES latch (it is the landed mode)
          ..toggleMode(); // -> fx
        await pumpEventQueue();

        expect(
          seen.map((e) => e.$1),
          [InteractionMode.mute, InteractionMode.fx],
          reason: 'each tap lands exactly one mode',
        );
        expect(seen.first.$2, {0}, reason: 'mute landed, so mute latched');
        expect(seen.last.$2, isEmpty, reason: 'fx landed, so fx cleared');

        // ...and jumping straight to FX skips mute's entry entirely: no
        // intermediate state is emitted at all.
        seen.clear();
        cubit
          ..setMode(InteractionMode.record)
          ..setMode(InteractionMode.fx);
        await pumpEventQueue();
        expect(seen.map((e) => e.$1), [
          InteractionMode.record,
          InteractionMode.fx,
        ]);
      });

      test('FX entry clears the stored mute-mode intent', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        cubit.toggleMode(); // -> mute, parkedResume = {0}
        expect(cubit.state.parkedResume, {0});
        cubit.toggleMode(); // -> fx
        expect(cubit.state.parkedResume, isEmpty);
        expect(cubit.state.excluded, isEmpty);
      });

      test('a stored "fx" boot default falls back to record (R12)', () async {
        await settings.saveDefaultInteractionMode(InteractionMode.fx.token);
        await cubit.load();
        expect(cubit.state.defaultMode, InteractionMode.record);
        expect(cubit.state.mode, InteractionMode.record);
      });

      test(
        'setDefaultMode refuses FX — it is never a boot mode (R12)',
        () async {
          // Debug builds fail loudly — a caller offering FX here has a bug...
          await expectLater(
            cubit.setDefaultMode(InteractionMode.fx),
            throwsA(isA<AssertionError>()),
          );
          // ...and nothing is applied or persisted either way, which is what
          // keeps a release build off the dead boot surface.
          expect(cubit.state.defaultMode, InteractionMode.record);
          expect(cubit.state.mode, InteractionMode.record);
          expect(await settings.loadDefaultInteractionMode(), isNull);
        },
      );
    });

    // The FX-mode button matrix: every one of the ten controls is defined,
    // and the three inert ones are proven inert (A2/A4) — a stray stomp must
    // never erase the set.
    group('FX mode', () {
      /// Presses and releases [button] on the wire, letting the decoded event
      /// reach the cubit.
      Future<void> stomp(PedalButton button) async {
        transport
          ..emit(0x90, button.note, 127)
          ..emit(0x80, button.note, 0);
        await pumpEventQueue();
      }

      /// Holds [button] past the 500 ms long-press threshold, then releases.
      /// Real delays (not fake_async) — the wire events reach the cubit
      /// through the repository's stream, which a fake clock cannot pump.
      Future<void> hold(PedalButton button) async {
        transport.emit(0x90, button.note, 127);
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 600));
        transport.emit(0x80, button.note, 0);
        await pumpEventQueue();
      }

      setUp(() {
        setEngine(_emptyTracks());
        cubit.setMode(InteractionMode.fx);
      });

      test('a track stomp toggles that track Track-stage chain', () async {
        await stomp(PedalButton.track1);
        verify(
          () => looper.setTrackChainEnabled(channel: 0, enabled: false),
        ).called(1);

        await stomp(PedalButton.track1);
        verify(
          () => looper.setTrackChainEnabled(channel: 0, enabled: true),
        ).called(1);
      });

      test('track stomps are bank-aware (A3): bank B stomps 4..7', () async {
        cubit.browseBank(1);
        await stomp(PedalButton.track2);
        verify(
          () => looper.setTrackChainEnabled(channel: 5, enabled: false),
        ).called(1);
        verifyNever(
          () => looper.setTrackChainEnabled(channel: 1, enabled: false),
        );
      });

      test(
        'a stomp persists the chain envelope so a reboot keeps it',
        () async {
          await stomp(PedalButton.track1);
          expect(await settings.loadTrackFxChain(0), isNotNull);
        },
      );

      test('Stop is FX panic: every Track chain off', () async {
        trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];
        trackChains[5] = [BuiltInEffect(type: TrackEffectType.reverb)];

        await stomp(PedalButton.stop);

        for (final channel in [1, 5]) {
          verify(
            () => looper.setTrackChainEnabled(channel: channel, enabled: false),
          ).called(1);
        }
      });

      test('FX panic leaves a track with NO chain alone — a bypass persisted '
          'for an empty chain would silently mute the effects added to that '
          'track later, and the boot restore replays it forever', () async {
        trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];

        await stomp(PedalButton.stop);

        expect(chainEnabled, {1: false}, reason: 'only the real chain flips');
        for (final channel in [0, 2, 3, 4, 5, 6, 7]) {
          verifyNever(
            () => looper.setTrackChainEnabled(channel: channel, enabled: false),
          );
          expect(await settings.loadTrackFxChain(channel), isNull);
        }
      });

      test('the FX panic fires on the PRESS, so a synthetic release (the '
          'plate releasing a held switch as it leaves the tree) cannot '
          'bypass anything on its own', () async {
        trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];

        // Press only — no release yet.
        transport.emit(0x90, PedalButton.stop.note, 127);
        await pumpEventQueue();
        expect(chainEnabled[1], isFalse, reason: 'panic landed on the press');

        // A release on its own is inert: it only retires the pending hold.
        chainEnabled.clear();
        transport.emit(0x80, PedalButton.stop.note, 0);
        await pumpEventQueue();
        expect(chainEnabled, isEmpty);
      });

      test('a Stop LONG-PRESS follows the panic with a restore', () async {
        trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];

        await hold(PedalButton.stop);

        // The press panicked, the hold restored — landing on the state the
        // restore promises regardless of what the pattern was before.
        verify(
          () => looper.setTrackChainEnabled(channel: 1, enabled: false),
        ).called(1);
        verify(
          () => looper.setTrackChainEnabled(channel: 1, enabled: true),
        ).called(1);
        expect(chainEnabled[1], isTrue);
      });

      test('a Stop hold that leaves FX mode before the threshold does not '
          'restore from a mode with no chain LEDs', () async {
        trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];

        transport.emit(0x90, PedalButton.stop.note, 127);
        await pumpEventQueue();
        expect(chainEnabled[1], isFalse); // the press panicked

        cubit.setMode(InteractionMode.record); // foot leaves FX mid-hold
        await Future<void>.delayed(const Duration(milliseconds: 600));
        transport.emit(0x80, PedalButton.stop.note, 0);
        await pumpEventQueue();

        verifyNever(
          () => looper.setTrackChainEnabled(channel: 1, enabled: true),
        );
        expect(chainEnabled[1], isFalse);
      });

      test(
        'Stop in Rec/Mute mode still acts on the PRESS (no gesture split)',
        () async {
          cubit.setMode(InteractionMode.record);
          setEngine(
            _tracksWith(const [
              Track(state: TrackState.playing, lengthFrames: 48000),
            ]),
          );
          transport.emit(0x90, PedalButton.stop.note, 127);
          await pumpEventQueue();
          verify(() => looper.setMute(muted: true)).called(1);
        },
      );

      test('Clear is INERT — a stray stomp never erases the set', () async {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        await stomp(PedalButton.clear);
        verifyNever(() => looper.clear(channel: any(named: 'channel')));
        expect(cubit.state.mode, InteractionMode.fx); // no home-and-reset
      });

      test('Rec/Play is INERT (reserved, A4)', () async {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        await stomp(PedalButton.recPlay);
        verifyNever(() => looper.record(channel: any(named: 'channel')));
        verifyNever(() => looper.record());
        verifyNever(() => looper.play(channel: any(named: 'channel')));
        verifyNever(() => looper.play());
      });

      test(
        'Undo is INERT until the #219 contract — tap AND long-press',
        () async {
          await stomp(PedalButton.undo);
          await hold(PedalButton.undo); // past the redo threshold too
          verifyNever(() => looper.undo(channel: any(named: 'channel')));
          verifyNever(() => looper.undo());
          verifyNever(() => looper.redo(channel: any(named: 'channel')));
          verifyNever(() => looper.redo());
        },
      );

      test('Bank still switches banks', () async {
        await stomp(PedalButton.bank);
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.cursor, 4);
      });

      test('the encoder still drives master gain', () async {
        transport.emit(0xB0, PedalCodec.encoderCc, 64 + 4);
        await pumpEventQueue();
        verify(() => looper.setMasterGain(any())).called(1);
      });

      test(
        'MODE long-press still arms performance recording (unchanged)',
        () async {
          await hold(PedalButton.mode);
          expect(performance.armedDirectory, isNotNull);
          expect(cubit.state.mode, InteractionMode.fx); // not a mode cycle
        },
      );

      test('a MODE tap cycles out of FX back to record', () async {
        await stomp(PedalButton.mode);
        expect(cubit.state.mode, InteractionMode.record);
      });

      test('toggleTrackChain ignores out-of-range channels', () {
        cubit
          ..toggleTrackChain(-1)
          ..toggleTrackChain(8);
        verifyNever(
          () => looper.setTrackChainEnabled(
            channel: any(named: 'channel'),
            enabled: any(named: 'enabled'),
          ),
        );
      });

      test('a panic over already-disabled chains writes nothing twice', () {
        trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];
        cubit
          ..panicTrackChains()
          ..panicTrackChains();
        verify(
          () => looper.setTrackChainEnabled(channel: 1, enabled: false),
        ).called(1);
      });
    });

    group('cursor / bank', () {
      test('selectTrack moves the cursor into its bank', () {
        cubit.selectTrack(5);
        expect(cubit.state.cursor, 5);
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.bankBaseChannel, 4);
        expect(cubit.state.bankContains(5), isTrue);
        expect(cubit.state.bankContains(2), isFalse);
      });

      test('selectTrack ignores out-of-range channels', () {
        cubit
          ..selectTrack(-1)
          ..selectTrack(8);
        expect(cubit.state.cursor, 0);
      });

      test('browseBank reveals the bank WITHOUT moving the cursor', () {
        cubit.browseBank(1);
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.cursor, 0); // browse only

        cubit
          ..browseBank(-1)
          ..browseBank(2);
        expect(cubit.state.activeBank, 1); // out-of-range ignored
      });

      test('toggleBankWithCursor moves the cursor to the new bank base', () {
        cubit.toggleBankWithCursor();
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.cursor, 4);

        cubit.toggleBankWithCursor();
        expect(cubit.state.activeBank, 0);
        expect(cubit.state.cursor, 0);
      });
    });

    group('recPlay in Rec mode', () {
      test('drives the cursor track record cycle', () {
        cubit.recPlay();
        verify(() => looper.record()).called(1);
      });

      test('unmutes and overdubs a muted, still-running track', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, muted: true, lengthFrames: 48000),
          ]),
        );
        cubit.recPlay();
        verify(() => looper.setMute(muted: false)).called(1);
        verify(() => looper.record()).called(1);
      });

      test('resumes a muted, parked track without overdub', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, muted: true, lengthFrames: 48000),
          ]),
        );
        cubit.recPlay();
        verify(() => looper.setMute(muted: false)).called(1);
        verify(() => looper.play()).called(1);
        verifyNever(() => looper.record(channel: any(named: 'channel')));
      });
    });

    group('recPlay in Mute mode', () {
      test('parked: resumes the latched set and consumes it', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        cubit
          ..toggleMode() // -> mute, parkedResume = {0, 1}
          ..recPlay();
        verify(() => looper.play()).called(1);
        verify(() => looper.play(channel: 1)).called(1);
        verifyNever(() => looper.play(channel: 2));
        expect(cubit.state.parkedResume, isEmpty); // consumed
      });

      test('parked with an empty resume set falls back to ALL content', () {
        // Enter Play with nothing recorded: the latch is empty. Content
        // appearing afterwards (e.g. a session load while parked) never
        // re-latches — the reducer only prunes — so Rec/Play falls back.
        cubit.toggleMode();
        expect(cubit.state.parkedResume, isEmpty);
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        cubit.recPlay();
        verify(() => looper.play()).called(1);
        verify(() => looper.play(channel: 1)).called(1);
      });

      test('nothing recorded: a no-op', () {
        cubit
          ..toggleMode()
          ..recPlay();
        verifyNever(() => looper.play(channel: any(named: 'channel')));
      });

      test('running: expands to the whole content set', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        cubit
          ..toggleMode()
          ..recPlay();
        // ch1 (parked content) joins; ch0 is re-asserted too.
        verify(() => looper.play()).called(1);
        verify(() => looper.play(channel: 1)).called(1);
      });

      test('running with the full audible set already in: a no-op', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit
          ..toggleMode()
          ..recPlay();
        verifyNever(() => looper.play(channel: any(named: 'channel')));
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
      });
    });

    group('stop', () {
      test('Rec mode: mutes the cursor track', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit.stop();
        verify(() => looper.setMute(muted: true)).called(1);
        // ch1 keeps sounding: no park.
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
      });

      test('Rec mode: finalizes a capture before muting', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        cubit.stop();
        verify(() => looper.record()).called(1); // finalize first
        verify(() => looper.setMute(muted: true)).called(1);
      });

      test('Rec mode: muting the sole audible track parks everything', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit.stop();
        verify(() => looper.setMute(muted: true)).called(1);
        verify(() => looper.stopTrack()).called(1);
      });

      test(
        'Mute mode: parks every running track and latches the resume set',
        () {
          setEngine(
            _tracksWith(const [
              Track(state: TrackState.playing, lengthFrames: 48000),
              Track(
                channel: 1,
                state: TrackState.playing,
                muted: true,
                lengthFrames: 48000,
              ),
            ]),
          );
          cubit
            ..toggleMode()
            ..stop();
          // Muted-but-running ch1 is frozen too (mute silences, park
          // freezes).
          verify(() => looper.stopTrack()).called(1);
          verify(() => looper.stopTrack(channel: 1)).called(1);
          // The latch captured the running set at INTENT time.
          expect(cubit.state.parkedResume, {0, 1});
        },
      );

      test('Mute mode: stop while already parked keeps the resume set', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        cubit
          ..toggleMode() // parkedResume = {0}
          ..stop();
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
        expect(cubit.state.parkedResume, {0});
      });
    });

    group('trackPressed in Rec mode', () {
      test('selects the track while idle', () {
        cubit.trackPressed(2);
        expect(cubit.state.cursor, 2);
        verifyNever(() => looper.record(channel: any(named: 'channel')));
      });

      test('finishes the loop when the capturing track is pressed', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        cubit.trackPressed(0);
        verify(() => looper.record()).called(1);
      });

      test('hands off a live recording to the pressed track', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        cubit.trackPressed(2);
        verify(() => looper.record()).called(1); // finalize
        verify(() => looper.record(channel: 2)).called(1); // start pressed
        expect(cubit.state.cursor, 2);
      });
    });

    group('trackPressed in Mute mode', () {
      test('an empty track is a no-op', () {
        cubit
          ..toggleMode()
          ..trackPressed(3);
        verifyNever(() => looper.play(channel: any(named: 'channel')));
        expect(cubit.state.parkedResume, isEmpty);
      });

      test('parked: toggles resume membership, unmuting a joining track', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
            Track(
              channel: 1,
              state: TrackState.stopped,
              muted: true,
              lengthFrames: 48000,
            ),
          ]),
        );
        cubit
          ..toggleMode() // parkedResume = {0, 1}
          ..trackPressed(0); // leave the set
        expect(cubit.state.parkedResume, {1});
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));

        cubit.trackPressed(0); // rejoin
        expect(cubit.state.parkedResume, {0, 1});

        // A muted member leaving then rejoining: the rejoin is a muted
        // NON-member arming, so it unmutes to read green.
        cubit.trackPressed(1); // leave -> {0}
        expect(cubit.state.parkedResume, {0});
        cubit.trackPressed(1); // rejoin: muted non-member -> unmute
        verify(() => looper.setMute(muted: false, channel: 1)).called(1);
        expect(cubit.state.parkedResume, {0, 1});
      });

      test('running: a live track press toggles its mute', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit
          ..toggleMode()
          ..trackPressed(0);
        verify(() => looper.setMute(muted: true)).called(1);
        // ch1 keeps sounding: no park.
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));

        // Engine reflects the mute; pressing again unmutes (out-of-mix join).
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, muted: true, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit.trackPressed(0);
        verify(() => looper.setMute(muted: false)).called(1);
      });

      test('muting the last audible track parks with an empty latch', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, muted: true, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit
          ..toggleMode()
          ..trackPressed(1); // mute the only audible track
        verify(() => looper.setMute(muted: true, channel: 1)).called(1);
        // Every running track parks (the muted one too).
        verify(() => looper.stopTrack()).called(1);
        verify(() => looper.stopTrack(channel: 1)).called(1);
        // Empty latch: the next Rec/Play falls back to ALL content.
        expect(cubit.state.parkedResume, isEmpty);
      });

      test('running: a parked content track joins the mix', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(
              channel: 1,
              state: TrackState.stopped,
              muted: true,
              lengthFrames: 48000,
            ),
          ]),
        );
        cubit
          ..toggleMode()
          ..trackPressed(1);
        verify(() => looper.setMute(muted: false, channel: 1)).called(1);
        verify(() => looper.play(channel: 1)).called(1);
      });
    });

    group('clearAll', () {
      test(
        'wipes content AND redo-able tracks, unmuting and persisting',
        () async {
          setEngine(
            _tracksWith(const [
              Track(
                state: TrackState.playing,
                muted: true,
                lengthFrames: 48000,
              ),
              Track(channel: 1, redoDepth: 2), // undone-to-empty
            ]),
          );
          cubit
            ..toggleMode()
            ..selectTrack(5);
          unawaited(cubit.clearAll());

          verify(() => looper.clear()).called(1);
          verify(() => looper.clear(channel: 1)).called(1); // redo path wiped
          verifyNever(() => looper.clear(channel: 2));
          verify(() => looper.setMute(muted: false)).called(1);
          verify(() => looper.setMute(muted: false, channel: 1)).called(1);

          // The whole-rig reset: overlay home again.
          expect(cubit.state.mode, InteractionMode.record);
          expect(cubit.state.cursor, 0);
          expect(cubit.state.parkedResume, isEmpty);

          // The unmute persists per lane (lane 0 default when none reported).
          await Future<void>.delayed(Duration.zero);
          expect(await settings.loadLaneMute(0, 0), isFalse);
          expect(await settings.loadLaneMute(1, 0), isFalse);
        },
      );

      test(
        'while armed, persistLiveLanes runs BEFORE any looper.clear (D-CLEAR)',
        () async {
          final log = <String>[];
          final recordingPerformance = _RecordingPerformanceRepository(
            log: log,
            engine: FakeAudioEngine(),
            exportsRoot: () async => tempDir.path,
          );
          addTearDown(recordingPerformance.dispose);
          final armedCubit = ControlCubit(
            looper: looper,
            pedal: pedal,
            settings: settings,
            performance: recordingPerformance,
            keepAliveInterval: Duration.zero,
          );
          addTearDown(armedCubit.close);

          await recordingPerformance.arm();
          await pumpEventQueue(); // deliver captureStatus.armed to the cubit

          setEngine(
            _tracksWith(const [
              Track(state: TrackState.playing, lengthFrames: 48000),
            ]),
          );
          when(() => looper.clear(channel: any(named: 'channel'))).thenAnswer((
            _,
          ) {
            log.add('looper.clear');
            return EngineResult.ok;
          });

          await armedCubit.clearAll();

          expect(log, ['persistLiveLanes', 'looper.clear']);
        },
      );

      test('while NOT armed, clearAll never calls persistLiveLanes', () async {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        final log = <String>[];
        final unarmedPerformance = _RecordingPerformanceRepository(
          log: log,
          engine: FakeAudioEngine(),
          exportsRoot: () async => tempDir.path,
        );
        addTearDown(unarmedPerformance.dispose);
        final unarmedCubit = ControlCubit(
          looper: looper,
          pedal: pedal,
          settings: settings,
          performance: unarmedPerformance,
          keepAliveInterval: Duration.zero,
        );
        addTearDown(unarmedCubit.close);

        await unarmedCubit.clearAll();

        expect(log, isEmpty);
        verify(() => looper.clear()).called(1);
      });
    });

    group('performance recording (D-PEDAL)', () {
      test(
        'togglePerformanceRecord arms the repository when unarmed, then '
        'disarms it on a second call',
        () async {
          expect(performance.armedDirectory, isNull);

          cubit.togglePerformanceRecord();
          await pumpEventQueue();
          expect(performance.armedDirectory, isNotNull);
          expect(
            await performance.captureStatus.first,
            PerformanceCaptureStatus.armed,
          );

          // Past disarm's double-press guard window (D-GUARD) — this test
          // proves the toggle mechanic, not the guard itself.
          clock = clock.add(PerformanceRepository.disarmGuardWindow * 2);

          cubit.togglePerformanceRecord();
          await pumpEventQueue();
          expect(performance.armedDirectory, isNull);
        },
      );

      test(
        'the pedal arm stamps the provider chains into the snapshot',
        () async {
          // The pedal gesture must record the same rig the toolbar path does —
          // before this was wired both armed with an empty chain set, so a
          // capture documented no FX at all.
          final wired = ControlCubit(
            looper: looper,
            pedal: pedal,
            settings: settings,
            performance: performance,
            keepAliveInterval: Duration.zero,
            currentChains: () => const PerformanceChains(
              monitors: [
                PerformanceMonitorState(
                  input: 1,
                  enabled: true,
                  outputMask: 0x2,
                  volume: 1,
                  muted: false,
                  effects: [],
                ),
              ],
              limiterEnabled: true,
              limiterCeiling: 0.8,
            ),
          );
          addTearDown(wired.close);

          wired.togglePerformanceRecord();

          await pumpEventQueue();

          final snapshot =
              jsonDecode(
                    File(
                      '${performance.armedDirectory}/arm-snapshot.json',
                    ).readAsStringSync(),
                  )
                  as Map<String, dynamic>;
          expect(snapshot['limiterOn'], isTrue);
          expect(snapshot['limiterCeiling'], 0.8);
          expect(
            (snapshot['monitors'] as List).single,
            containsPair('input', 1),
          );
        },
      );

      test(
        '_onPerformanceStatus reactivity: an external arm() (bypassing '
        "this cubit's own method) is still reflected in the projected frame",
        () async {
          pedal.bind('out');
          transport.sent.clear();

          // Drive the repository directly — not through
          // cubit.togglePerformanceRecord() — to prove the cubit reacts to
          // the shared captureStatus stream regardless of who triggered it
          // (mirrors PerformanceRecorderCubit's own reactive design).
          await performance.arm();
          await pumpEventQueue();

          final frame = PedalCodec.decodeFrame(transport.sent.last);
          expect(frame?.performanceArmed, isTrue);

          await performance.disarmAndFinalize();
          await pumpEventQueue();

          final disarmedFrame = PedalCodec.decodeFrame(transport.sent.last);
          expect(disarmedFrame?.performanceArmed, isFalse);
        },
      );
    });

    group('undo / redo / encoder', () {
      test('undo and redo pass straight through to the repository', () {
        cubit
          ..undo(3)
          ..redo(5);
        verify(() => looper.undo(channel: 3)).called(1);
        verify(() => looper.redo(channel: 5)).called(1);
        verifyNever(() => looper.clear(channel: any(named: 'channel')));
      });

      test('encoderTurned accumulates the master gain and clamps at 0', () {
        cubit.encoderTurned(-8); // 1.0 - 8/64
        final captured = verify(
          () => looper.setMasterGain(captureAny()),
        ).captured;
        expect(captured.single, closeTo(1 - 8 / 64, 1e-9));

        cubit.encoderTurned(-64); // clamps at 0
        final clamped = verify(
          () => looper.setMasterGain(captureAny()),
        ).captured;
        expect(clamped.single, 0.0);
      });
    });

    group('looper reducer (the invalidation table)', () {
      test('clamps the cursor when the track list shrinks', () {
        cubit.selectTrack(7);
        expect(cubit.state.cursor, 7);

        setEngine(_emptyTracks(4));
        expect(cubit.state.cursor, 3);
        expect(cubit.state.activeBank, 0); // follows the clamped cursor
      });

      test('prunes parkedResume of emptied tracks', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        cubit.toggleMode(); // parkedResume = {0, 1}
        // Track 1 empties (undo-to-empty / clear): it drops from the set.
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        expect(cubit.state.parkedResume, {0});
      });

      test('keeps capturing tracks in the stored sets', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        cubit.toggleMode(); // capture survives; parkedResume = {0}
        expect(cubit.state.parkedResume, {0});
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        expect(cubit.state.parkedResume, {0}); // finishing a loop: kept
      });

      test('a no-change snapshot does not emit', () {
        final emits = <ControlState>[];
        final sub = cubit.stream.listen(emits.add);

        setEngine(_emptyTracks());
        expect(emits, isEmpty);
        unawaited(sub.cancel());
      });
    });

    group('pedal decode (events in via PedalRepository)', () {
      test('Rec/Play decodes into the record intent on the cursor', () async {
        transport.emit(0x90, PedalButton.recPlay.note, 100);
        await pumpEventQueue();
        verify(() => looper.record()).called(1);
      });

      test('Mode toggles the shared mode', () async {
        // A tap (press + quick release) — mode now rides the same
        // tap-vs-long-press split as undo (D-PEDAL): a bare press alone no
        // longer toggles it.
        transport
          ..emit(0x90, PedalButton.mode.note, 100)
          ..emit(0x80, PedalButton.mode.note, 0);
        await pumpEventQueue();
        expect(cubit.state.mode, InteractionMode.mute);
      });

      test('Bank toggles the active bank and moves the cursor', () async {
        transport.emit(0x90, PedalButton.bank.note, 100);
        await pumpEventQueue();
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.cursor, 4);
      });

      test('a track press targets the visible bank base', () async {
        transport.emit(0x90, PedalButton.bank.note, 100); // -> bank B
        await pumpEventQueue();
        transport.emit(0x90, PedalButton.track3.note, 100);
        await pumpEventQueue();
        // track3 == index 2, bank B base 4 -> channel 6 (idle press selects).
        expect(cubit.state.cursor, 6);
      });

      test('the encoder drives the master gain', () async {
        transport.emit(0xB0, PedalCodec.encoderCc, 64 - 8); // -8 detents
        await pumpEventQueue();
        verify(() => looper.setMasterGain(any())).called(1);
      });

      test('Clear decodes into the unified clear-all', () async {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, muted: true, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        transport.emit(0x90, PedalButton.clear.note, 100);
        await pumpEventQueue();

        verify(() => looper.clear()).called(1);
        verify(() => looper.clear(channel: 1)).called(1);
        verifyNever(() => looper.clear(channel: 2));
        verify(() => looper.setMute(muted: false, channel: 1)).called(1);
        expect(cubit.state.mode, InteractionMode.record);
        expect(cubit.state.cursor, 0);
      });

      group('undo press timing', () {
        test('tap undoes the cursor track', () async {
          transport
            ..emit(0x90, PedalButton.undo.note, 100) // press
            ..emit(0x80, PedalButton.undo.note, 0); // quick release == tap
          await pumpEventQueue();

          verify(() => looper.undo()).called(1);
          verifyNever(() => looper.redo(channel: any(named: 'channel')));
          verifyNever(() => looper.clear(channel: any(named: 'channel')));
        });

        test('the undo target is latched at press time', () async {
          transport.emit(0x90, PedalButton.undo.note, 100); // press, cursor 0
          await pumpEventQueue();
          // An on-screen click mid-hold must not retarget the committed
          // action.
          cubit.selectTrack(3);
          transport.emit(0x80, PedalButton.undo.note, 0);
          await pumpEventQueue();

          verify(() => looper.undo()).called(1); // channel 0, not 3
          verifyNever(() => looper.undo(channel: 3));
        });

        test('long-press redoes instead', () async {
          transport.emit(0x90, PedalButton.undo.note, 100);
          // Default long-press threshold is 500 ms.
          await Future<void>.delayed(const Duration(milliseconds: 600));
          transport.emit(0x80, PedalButton.undo.note, 0);
          await pumpEventQueue();

          verify(() => looper.redo()).called(1);
          verifyNever(() => looper.undo(channel: any(named: 'channel')));
        });

        test('a release with no matching press is inert — the on-screen '
            'plate note-offs every held switch as it leaves the tree, and an '
            'unpaired one must not fire a tap', () async {
          transport.emit(0x80, PedalButton.undo.note, 0); // release only
          await pumpEventQueue();

          verifyNever(() => looper.undo(channel: any(named: 'channel')));
          verifyNever(() => looper.redo(channel: any(named: 'channel')));
        });

        test('a second release after a completed tap fires nothing', () async {
          transport
            ..emit(0x90, PedalButton.undo.note, 100)
            ..emit(0x80, PedalButton.undo.note, 0);
          await pumpEventQueue();
          verify(() => looper.undo()).called(1);

          transport.emit(0x80, PedalButton.undo.note, 0);
          await pumpEventQueue();

          verifyNever(() => looper.undo(channel: any(named: 'channel')));
        });
      });

      group('mode press timing (D-PEDAL)', () {
        test('tap toggles mode and does NOT arm/disarm performance '
            'recording', () async {
          expect(cubit.state.mode, InteractionMode.record);
          transport
            ..emit(0x90, PedalButton.mode.note, 100) // press
            ..emit(0x80, PedalButton.mode.note, 0); // quick release == tap
          await pumpEventQueue();

          expect(cubit.state.mode, InteractionMode.mute);
          expect(performance.armedDirectory, isNull);
        });

        test(
          'long-press arms performance recording and does NOT flip mode',
          () async {
            transport.emit(0x90, PedalButton.mode.note, 100);
            // Default long-press threshold is 500 ms.
            await Future<void>.delayed(const Duration(milliseconds: 600));
            transport.emit(0x80, PedalButton.mode.note, 0);
            await pumpEventQueue();

            expect(cubit.state.mode, InteractionMode.record); // unchanged
            expect(performance.armedDirectory, isNotNull);
          },
        );

        test('a long-press then a second long-press disarms again', () async {
          transport.emit(0x90, PedalButton.mode.note, 100);
          await Future<void>.delayed(const Duration(milliseconds: 600));
          transport.emit(0x80, PedalButton.mode.note, 0);
          await pumpEventQueue();
          expect(performance.armedDirectory, isNotNull);

          // Past disarm's double-press guard window (D-GUARD) — the fake
          // clock does not advance with the real 600ms long-press delay
          // above, so it must be moved explicitly for the second long-press
          // to actually disarm rather than be guarded.
          clock = clock.add(PerformanceRepository.disarmGuardWindow * 2);

          transport.emit(0x90, PedalButton.mode.note, 100);
          await Future<void>.delayed(const Duration(milliseconds: 600));
          transport.emit(0x80, PedalButton.mode.note, 0);
          await pumpEventQueue();

          expect(performance.armedDirectory, isNull);
        });

        test(
          'a release with no matching press does not cycle the mode',
          () async {
            transport.emit(0x80, PedalButton.mode.note, 0); // release only
            await pumpEventQueue();

            expect(cubit.state.mode, InteractionMode.record); // unchanged
            expect(performance.armedDirectory, isNull);
          },
        );
      });
    });

    group('pedal remap (part 6b)', () {
      /// The Track-stage chain on channel 3, and one slot inside it.
      const chain3 = FxChainTarget(FxAddress(stage: FxStage.track, index: 3));
      const slotB = FxSlotTarget(
        address: FxAddress(stage: FxStage.track, index: 3),
        slotId: 'b',
      );

      PedalBinding bind(
        PedalButton button, {
        int? bank,
        FxBindingTarget target = chain3,
        BindingBehavior behavior = BindingBehavior.toggle,
        String? rawTarget,
      }) => PedalBinding(
        key: PedalBindingKey(button: button, bank: bank),
        target: rawTarget ?? target.canonicalString(),
        behavior: behavior,
      );

      Future<void> stomp(PedalButton button) async {
        transport
          ..emit(0x90, button.note, 127)
          ..emit(0x80, button.note, 0);
        await pumpEventQueue();
      }

      Future<void> press(PedalButton button) async {
        transport.emit(0x90, button.note, 127);
        await pumpEventQueue();
      }

      Future<void> release(PedalButton button) async {
        transport.emit(0x80, button.note, 0);
        await pumpEventQueue();
      }

      setUp(() {
        // A real chain on channel 3 so its flag is stompable, with two slots
        // so a slot binding has something to point at.
        trackChains[3] = [
          BuiltInEffect(type: TrackEffectType.drive, slotId: 'a'),
          BuiltInEffect(type: TrackEffectType.reverb, slotId: 'b'),
        ];
        setEngine(_emptyTracks());
        cubit.setMode(InteractionMode.fx);
      });

      group('dispatch', () {
        test('a bound button overrides its contextual default', () async {
          // Unbound, track1 in bank A stomps channel 0's own chain.
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.track1, bank: 0)]),
          );
          await stomp(PedalButton.track1);

          expect(chainEnabled[3], isFalse, reason: 'the BOUND chain flipped');
          verifyNever(
            () => looper.setTrackChainEnabled(channel: 0, enabled: false),
          );
        });

        test(
          'an UNBOUND button keeps its part 5b contextual behavior',
          () async {
            await cubit.setGlobalBindings(
              PedalBindingSet([bind(PedalButton.track1, bank: 0)]),
            );
            await stomp(PedalButton.track2);

            expect(chainEnabled[1], isFalse, reason: 'contextual: channel 1');
            expect(chainEnabled.containsKey(3), isFalse);
          },
        );

        test('bindings are INERT outside FX mode — the transport modes are '
            'not a surface a remap may shadow', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.stop)]),
          );
          cubit.setMode(InteractionMode.record);
          await stomp(PedalButton.stop);

          expect(chainEnabled.containsKey(3), isFalse);
        });

        test('a toggle binding flips the target back and forth', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.recPlay)]),
          );
          await stomp(PedalButton.recPlay);
          expect(chainEnabled[3], isFalse);
          await stomp(PedalButton.recPlay);
          expect(chainEnabled[3], isTrue);
        });

        test('a SLOT binding flips one effect, leaving the chain flag '
            'alone (A9)', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.recPlay, target: slotB)]),
          );
          await stomp(PedalButton.recPlay);

          expect(trackChains[3]![1].enabled, isFalse);
          expect(
            trackChains[3]![0].enabled,
            isTrue,
            reason: 'slot a untouched',
          );
          expect(chainEnabled.containsKey(3), isFalse, reason: 'chain flag');
        });

        test('a slot binding survives an INSERT above it — positional churn '
            'never retargets (A9)', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.recPlay, target: slotB)]),
          );
          trackChains[3] = [
            BuiltInEffect(type: TrackEffectType.delay, slotId: 'new'),
            ...trackChains[3]!,
          ];
          await stomp(PedalButton.recPlay);

          final byId = {
            for (final fx in trackChains[3]!) fx.slotId: fx.enabled,
          };
          expect(byId['b'], isFalse, reason: 'the bound slot flipped');
          expect(byId['new'], isTrue, reason: 'the inserted one did not');
          expect(byId['a'], isTrue);
        });

        test('track bindings are per-bank (A3)', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.track1, bank: 1)]),
          );
          // Bank A: unbound, so track1 acts contextually on channel 0.
          await stomp(PedalButton.track1);
          expect(chainEnabled[0], isFalse);
          expect(chainEnabled.containsKey(3), isFalse);

          cubit.browseBank(1);
          await stomp(PedalButton.track1);
          expect(chainEnabled[3], isFalse, reason: 'bank B is bound');
        });
      });

      group('MODE and Bank are never remappable (B12)', () {
        test('the model refuses to hold a binding on either', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.mode), bind(PedalButton.bank)]),
          );
          expect(cubit.globalBindings.isEmpty, isTrue);
        });

        test(
          'MODE still cycles the mode and Bank still switches banks',
          () async {
            await cubit.setGlobalBindings(
              PedalBindingSet([bind(PedalButton.mode), bind(PedalButton.bank)]),
            );

            await stomp(PedalButton.bank);
            expect(cubit.state.activeBank, 1);
            expect(chainEnabled.containsKey(3), isFalse);

            await stomp(PedalButton.mode);
            expect(cubit.state.mode, InteractionMode.record);
          },
        );
      });

      group('long-press system gestures survive a remap (B12)', () {
        test('a bound Stop runs its binding on the press but KEEPS the '
            'restore-all hold — the panic\'s only undo must stay reachable '
            'whatever the user mapped', () async {
          trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.stop)]),
          );

          await press(PedalButton.stop);
          expect(chainEnabled[3], isFalse, reason: 'the binding ran');
          expect(chainEnabled.containsKey(1), isFalse, reason: 'no panic');

          await Future<void>.delayed(const Duration(milliseconds: 600));
          await release(PedalButton.stop);

          // The hold restored every Track chain, the one the binding had just
          // bypassed included. Channel 1 was never bypassed (the binding took
          // the press instead of the panic), so the sweep skips it as a no-op
          // rather than writing a flag it already holds.
          expect(chainEnabled[3], isTrue, reason: 'the hold restored it');
          expect(chainEnabled.containsKey(1), isFalse);
        });

        test('MODE long-press still arms performance recording', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.mode)]),
          );
          await press(PedalButton.mode);
          await Future<void>.delayed(const Duration(milliseconds: 600));
          await release(PedalButton.mode);

          expect(performance.armedDirectory, isNotNull);
        });
      });

      group('momentary (B1)', () {
        Future<void> bindMomentary({FxBindingTarget target = chain3}) =>
            cubit.setGlobalBindings(
              PedalBindingSet([
                bind(
                  PedalButton.recPlay,
                  target: target,
                  behavior: BindingBehavior.momentary,
                ),
              ]),
            );

        test(
          'press enables and release restores what the press captured',
          () async {
            chainEnabled[3] = false; // starts bypassed
            await bindMomentary();

            await press(PedalButton.recPlay);
            expect(chainEnabled[3], isTrue, reason: 'held = enabled');

            await release(PedalButton.recPlay);
            expect(chainEnabled[3], isFalse, reason: 'restored to prior');
          },
        );

        test('a press over an ALREADY-enabled target restores it enabled — '
            'the release writes the captured state, not a blind off', () async {
          await bindMomentary();
          await press(PedalButton.recPlay);
          await release(PedalButton.recPlay);
          expect(cubit.state.mode, InteractionMode.fx);
          expect(chainEnabled[3] ?? true, isTrue);
        });

        test('last-writer-wins: a UI toggle mid-hold is overwritten by the '
            'release, which restores what THIS press saw', () async {
          chainEnabled[3] = false;
          await bindMomentary();

          await press(PedalButton.recPlay);
          // Another writer flips it while the foot is down.
          cubit.toggleTrackChain(3);
          expect(chainEnabled[3], isFalse);

          await release(PedalButton.recPlay);
          expect(chainEnabled[3], isFalse, reason: 'the capture won');
        });

        test('works on a slot target too', () async {
          await bindMomentary(target: slotB);
          trackChains[3] = [
            trackChains[3]![0],
            (trackChains[3]![1] as BuiltInEffect).copyWith(enabled: false),
          ];

          await press(PedalButton.recPlay);
          expect(trackChains[3]![1].enabled, isTrue);

          await release(PedalButton.recPlay);
          expect(trackChains[3]![1].enabled, isFalse);
        });

        group('no stuck momentary (flow SC-2) — every path that strands a '
            'press without its release restores at the ONE enforcement '
            'point', () {
          setUp(() async {
            chainEnabled[3] = false;
            await bindMomentary();
            await press(PedalButton.recPlay);
            expect(chainEnabled[3], isTrue, reason: 'held');
          });

          test('a MODE switch out of FX', () async {
            cubit.setMode(InteractionMode.record);
            expect(chainEnabled[3], isFalse);
          });

          test(
            'a pedal disconnect — the release note-off never arrives',
            () async {
              pedal
                ..bind('out')
                ..unbind();
              await pumpEventQueue();
              expect(chainEnabled[3], isFalse);
            },
          );

          test('a session load replacing the binding set', () async {
            cubit.applySessionBindings(
              PedalBindingSet([bind(PedalButton.stop)]),
            );
            expect(chainEnabled[3], isFalse);
          });

          test('a live edit from the assignment screen', () async {
            await cubit.setGlobalBindings(PedalBindingSet.empty);
            expect(chainEnabled[3], isFalse);
          });

          test('and a late release afterwards writes nothing more', () async {
            cubit.setMode(InteractionMode.record);
            chainEnabled.remove(3);
            await release(PedalButton.recPlay);
            expect(chainEnabled.containsKey(3), isFalse);
          });
        });

        test('a bank change mid-hold still releases the pressed binding — '
            'the release is matched by BUTTON, not the live bank', () async {
          chainEnabled[3] = false;
          await cubit.setGlobalBindings(
            PedalBindingSet([
              bind(
                PedalButton.track1,
                bank: 0,
                behavior: BindingBehavior.momentary,
              ),
            ]),
          );

          await press(PedalButton.track1);
          expect(chainEnabled[3], isTrue);

          cubit.browseBank(1); // foot still down
          await release(PedalButton.track1);
          expect(chainEnabled[3], isFalse);
        });
      });

      group('stale targets (R25)', () {
        test('a mid-song stomp on a stale binding is a NO-OP', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([
              bind(
                PedalButton.recPlay,
                target: const FxChainTarget(
                  FxAddress(stage: FxStage.track, index: 7),
                ),
              ),
            ]),
          );
          await stomp(PedalButton.recPlay);

          expect(chainEnabled, isEmpty);
          verifyNever(
            () => looper.setTrackChainEnabled(
              channel: any(named: 'channel'),
              enabled: any(named: 'enabled'),
            ),
          );
        });

        test('a target string that no longer parses is a no-op, not a '
            'crash', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.recPlay, rawTarget: 'garbage')]),
          );
          await stomp(PedalButton.recPlay);
          expect(chainEnabled, isEmpty);
        });

        test('a slot deleted out from under a binding never falls back to '
            'the chain or to its old neighbour', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.recPlay, target: slotB)]),
          );
          trackChains[3] = [trackChains[3]![0]]; // slot b deleted
          await stomp(PedalButton.recPlay);

          expect(trackChains[3]!.single.enabled, isTrue);
          expect(chainEnabled, isEmpty);
        });

        test('a stale MOMENTARY press captures nothing, so its release has '
            'nothing to restore', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([
              bind(
                PedalButton.recPlay,
                rawTarget: 'garbage',
                behavior: BindingBehavior.momentary,
              ),
            ]),
          );
          await press(PedalButton.recPlay);
          await release(PedalButton.recPlay);
          expect(chainEnabled, isEmpty);
        });
      });

      group('merge rule (A12)', () {
        test(
          'a session with bindings overrides the globals WHOLESALE',
          () async {
            await cubit.setGlobalBindings(
              PedalBindingSet([
                bind(PedalButton.recPlay),
                bind(PedalButton.stop),
              ]),
            );
            cubit.applySessionBindings(
              PedalBindingSet([bind(PedalButton.undo)]),
            );

            // The session's own button acts...
            await stomp(PedalButton.undo);
            expect(chainEnabled[3], isFalse);

            // ...and a global-only button is back to its contextual default.
            chainEnabled.clear();
            await stomp(PedalButton.recPlay);
            expect(
              chainEnabled,
              isEmpty,
              reason: 'recPlay is inert in FX (A4)',
            );
          },
        );

        test('a session with NO bindings falls back to the globals', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.recPlay)]),
          );
          cubit.applySessionBindings(PedalBindingSet.empty);

          await stomp(PedalButton.recPlay);
          expect(chainEnabled[3], isFalse);
        });
      });

      test('the global set persists and reloads through settings', () async {
        final set = PedalBindingSet([
          bind(PedalButton.stop, behavior: BindingBehavior.momentary),
          bind(PedalButton.track2, bank: 1, target: slotB),
        ]);
        await cubit.setGlobalBindings(set);

        expect(
          PedalBindingSet.decode(await settings.loadPedalBindings() ?? ''),
          set,
        );

        final reloaded = ControlCubit(
          looper: looper,
          pedal: pedal,
          settings: settings,
          performance: performance,
          keepAliveInterval: Duration.zero,
        );
        addTearDown(reloaded.close);
        await reloaded.load();
        expect(reloaded.globalBindings, set);
      });
    });

    group('frame projection (frames out via PedalRepository)', () {
      test('pushes an encoded frame to the bound pedal', () async {
        pedal.bind('out');
        transport.sent.clear();

        // Rec mode (default): the cursor track (0) is red; a playing
        // non-cursor track is off (green-for-playing is a Mute-mode concern).
        setEngine(
          _tracksWith(const [
            Track(), // track 0 (cursor) -> red indicator
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        await pumpEventQueue();

        expect(transport.sent, isNotEmpty);
        final frame = PedalCodec.decodeFrame(transport.sent.last);
        expect(frame, isNotNull);
        expect(frame!.trackLeds[0], PedalTrackLed.red);
        expect(frame.trackLeds[1], PedalTrackLed.off);
      });

      test('an encoder turn pushes the new master gain in the frame', () async {
        pedal.bind('out');
        setEngine(_tracksWith(const [Track()]));
        await pumpEventQueue();
        transport.sent.clear();

        // -8 detents at step 1/64 -> gain 0.875 (the pedal renders this).
        transport.emit(0xB0, PedalCodec.encoderCc, 64 - 8);
        await pumpEventQueue();

        expect(transport.sent, isNotEmpty);
        final frame = PedalCodec.decodeFrame(transport.sent.last);
        expect(frame, isNotNull);
        expect(frame!.masterGain, closeTo(0.875, 0.01));
      });

      test('a stored-intent change re-projects without a looper tick', () {
        pedal.bind('out');
        setEngine(_emptyTracks());
        transport.sent.clear();

        cubit.selectTrack(3); // cursor moves -> the red LED must follow

        final frame = PedalCodec.decodeFrame(transport.sent.last);
        expect(frame!.selectedTrack, 3);
        expect(frame.trackLeds[3], PedalTrackLed.red);
        expect(frame.trackLeds[0], PedalTrackLed.off);
      });

      test('re-pushes the current frame on the keep-alive heartbeat', () {
        fakeAsync((async) {
          pedal.bind('out');
          final beat = ControlCubit(
            looper: looper,
            pedal: pedal,
            settings: settings,
            performance: performance,
            keepAliveInterval: const Duration(milliseconds: 500),
          );
          setEngine(_emptyTracks()); // sync stream delivers state to `beat`
          async.flushMicrotasks();
          transport.sent.clear();

          // Nothing changes, but the heartbeat keeps re-sending the frame so
          // the pedal's link watchdog can tell "idle" from "disconnected".
          async.elapse(const Duration(seconds: 3));
          expect(transport.sent.length, greaterThanOrEqualTo(3));

          unawaited(beat.close()); // cancel the periodic timer
          async.flushMicrotasks();
        });
      });

      test('keep-alive lights the pedal from the repository snapshot even '
          'before any LooperState streams (regression: a null _looperState '
          'left the LEDs dark)', () {
        fakeAsync((async) {
          pedal.bind('out');
          // NB: no setEngine() — this cubit never receives a streamed
          // LooperState (the broadcast stream emits nothing after it
          // subscribes), so `_looperState` stays null. Only the synchronous
          // `looper.state` snapshot (an idle empty set from the outer setUp) is
          // available. The setUp cubit has keepAliveInterval: zero, so the
          // heartbeat frames below come only from `idle`.
          final idle = ControlCubit(
            looper: looper,
            pedal: pedal,
            settings: settings,
            performance: performance,
            keepAliveInterval: const Duration(milliseconds: 500),
          );
          async.flushMicrotasks();
          transport.sent.clear();

          // The heartbeat must still project from `looper.state` and push
          // frames; before the fix the null guard silenced every push and the
          // pedal stayed dark on an idle engine.
          async.elapse(const Duration(seconds: 2));
          expect(transport.sent, isNotEmpty);
          expect(PedalCodec.decodeFrame(transport.sent.last), isNotNull);

          unawaited(idle.close());
          async.flushMicrotasks();
        });
      });

      test('a rebind force-pushes the CURRENT state', () async {
        setEngine(_emptyTracks());
        cubit.toggleMode(); // mode changes while unbound
        pedal.bind('out');
        await pumpEventQueue();

        final frame = PedalCodec.decodeFrame(transport.sent.last);
        expect(frame!.mode, PedalMode.play);
      });

      test('Clear LED lights while the footswitch is held and darkens on '
          'release', () async {
        pedal.bind('out');
        setEngine(_emptyTracks());
        transport.sent.clear();

        // Press: the Clear LED bit is set.
        transport.emit(0x90, PedalButton.clear.note, 100);
        await pumpEventQueue();
        expect(
          PedalCodec.decodeFrame(transport.sent.last)?.clearFadeActive,
          isTrue,
        );

        // Release (note-off): the bit clears again.
        transport.emit(0x80, PedalButton.clear.note, 0);
        await pumpEventQueue();
        expect(
          PedalCodec.decodeFrame(transport.sent.last)?.clearFadeActive,
          isFalse,
        );
      });

      test('sends a loop-top pulse when the playhead wraps', () async {
        pedal.bind('out');
        setEngine(_emptyTracks(), masterPositionFrames: 40000);
        await pumpEventQueue();
        transport.sent.clear();
        setEngine(_emptyTracks(), masterPositionFrames: 10);
        await pumpEventQueue();

        expect(
          transport.sent.any((m) => m.length == 1 && m.first == 0xFA),
          isTrue,
        );
      });

      test(
        'global_color carries the ring activity color (recording = red)',
        () async {
          pedal.bind('out');
          transport.sent.clear();
          setEngine(
            _tracksWith(const [Track(state: TrackState.recording)]),
          );
          await pumpEventQueue();

          final frame = PedalCodec.decodeFrame(transport.sent.last);
          expect(frame?.globalColor, GlobalColor.red);
        },
      );

      test(
        'the pushed frame carries the per-track LED projection',
        () async {
          pedal.bind('out');
          transport.sent.clear();
          setEngine(
            _tracksWith(const [
              Track(), // ch0 cursor by default -> red
              Track(channel: 1, state: TrackState.recording),
            ]),
          );
          await pumpEventQueue();

          final leds = PedalCodec.decodeFrame(transport.sent.last)?.trackLeds;
          expect(leds?[0], PedalTrackLed.red);
          expect(leds?[1], PedalTrackLed.red);
          expect(leds?[2], PedalTrackLed.off);

          cubit.selectTrack(2);
          await pumpEventQueue();
          expect(
            PedalCodec.decodeFrame(transport.sent.last)?.trackLeds[2],
            PedalTrackLed.red,
          );
        },
      );
    });
  });
}
