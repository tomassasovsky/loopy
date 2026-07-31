import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_controller_source.dart';

/// The part 7 dispatch surface: CC values flowing through both trigger shapes,
/// the smoothing ramp under a fake clock, learn hygiene, and the inert states.
void main() {
  const expression = MappingTrigger(
    kind: ControllerSourceKind.midiCc,
    id: 11,
    midiChannel: 0,
  );
  const stomp = MappingTrigger(
    kind: ControllerSourceKind.midiCc,
    id: 21,
    midiChannel: 0,
  );

  late FakeControllerSource source;

  setUp(() => source = FakeControllerSource());

  ControllerRepository build({
    ControllerBindingSet bindings = ControllerBindingSet.empty,
    bool Function(RawControllerInput)? learnIgnore,
    List<ControllerSource>? sources,
    Duration smoothing = const Duration(milliseconds: 60),
    Duration tick = const Duration(milliseconds: 10),
  }) => ControllerRepository(
    sources: sources ?? [source],
    bindings: bindings,
    learnIgnore: learnIgnore,
    smoothing: smoothing,
    smoothingTick: tick,
  );

  void cc(int id, int value, {int channel = 0}) => source.emit(
    RawControllerInput(
      kind: ControllerSourceKind.midiCc,
      id: id,
      value: value,
      midiChannel: channel,
    ),
  );

  group('continuous bindings', () {
    test('the first move jumps straight to the mapped value (B9)', () async {
      final repo = build(
        bindings: ControllerBindingSet(const [
          ContinuousBinding(
            trigger: expression,
            target: 'cutoff',
            lo: 0.2,
          ),
        ]),
      );
      addTearDown(repo.dispose);
      final events = <ControllerBindingEvent>[];
      repo.bindingEvents.listen(events.add);

      cc(11, 127);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect((events.single as ControllerValueEvent).value, closeTo(1, 1e-9));
      expect(events.single.target, 'cutoff');
    });

    test('later moves ramp to the new value and land exactly on it', () {
      fakeAsync((async) {
        final repo = build(
          bindings: ControllerBindingSet(const [
            ContinuousBinding(trigger: expression, target: 'cutoff'),
          ]),
        );
        final values = <double>[];
        repo.bindingEvents.listen(
          (e) => values.add((e as ControllerValueEvent).value),
        );

        cc(11, 0); // first move: jumps to 0
        async.flushMicrotasks();
        cc(11, 127); // second move: ramps 0 -> 1 over six ticks
        async
          ..elapse(const Duration(milliseconds: 60))
          ..flushMicrotasks();

        expect(values.first, 0);
        expect(values.last, closeTo(1, 1e-9));
        expect(values.length, 7, reason: 'the jump plus one per 10ms tick');
        // Monotonic and evenly spaced: the trajectory the ear expects between
        // two CC positions.
        for (var i = 1; i < values.length; i++) {
          expect(values[i], greaterThan(values[i - 1]));
        }
        expect(values[3], closeTo(0.5, 1e-9));

        unawaited(repo.dispose());
        async.flushMicrotasks();
      });
    });

    test('dispose leaves no pending timer', () {
      fakeAsync((async) {
        final repo = build(
          bindings: ControllerBindingSet(const [
            ContinuousBinding(trigger: expression, target: 'cutoff'),
          ]),
        );
        repo.bindingEvents.listen((_) {});

        cc(11, 0);
        async.flushMicrotasks();
        cc(11, 127); // starts the ramp ticker
        async.elapse(const Duration(milliseconds: 10));
        expect(async.pendingTimers, isNotEmpty);

        unawaited(repo.dispose());
        async.flushMicrotasks();

        expect(async.pendingTimers, isEmpty);
      });
    });

    test('the ramp stops on its own once it lands', () {
      fakeAsync((async) {
        final repo = build(
          bindings: ControllerBindingSet(const [
            ContinuousBinding(trigger: expression, target: 'cutoff'),
          ]),
        );
        repo.bindingEvents.listen((_) {});

        cc(11, 0);
        async.flushMicrotasks();
        cc(11, 64);
        async.elapse(const Duration(milliseconds: 200));

        expect(async.pendingTimers, isEmpty);

        unawaited(repo.dispose());
        async.flushMicrotasks();
      });
    });

    test('one control fans out to every target it drives (B8)', () async {
      final repo = build(
        bindings: ControllerBindingSet(const [
          ContinuousBinding(trigger: expression, target: 'cutoff'),
          ContinuousBinding(trigger: expression, target: 'volume'),
        ]),
      );
      addTearDown(repo.dispose);
      final events = <ControllerBindingEvent>[];
      repo.bindingEvents.listen(events.add);

      cc(11, 127);
      await Future<void>.delayed(Duration.zero);

      expect(events.map((e) => e.target), ['cutoff', 'volume']);
    });

    test('many controls on one target are last-writer-wins', () async {
      final repo = build(
        bindings: ControllerBindingSet(const [
          ContinuousBinding(trigger: expression, target: 'cutoff'),
          ContinuousBinding(trigger: stomp, target: 'cutoff', hi: 0.5),
        ]),
      );
      addTearDown(repo.dispose);
      final values = <double>[];
      repo.bindingEvents.listen(
        (e) => values.add((e as ControllerValueEvent).value),
      );

      cc(11, 127); // first mapping: 1.0
      await Future<void>.delayed(Duration.zero);
      cc(21, 127); // second mapping on the same target: 0.5, and it wins
      await Future<void>.delayed(Duration.zero);

      expect(values, [closeTo(1, 1e-9), closeTo(0.5, 1e-9)]);
    });

    test('a repeated CC value emits nothing new', () async {
      final repo = build(
        bindings: ControllerBindingSet(const [
          ContinuousBinding(trigger: expression, target: 'cutoff'),
        ]),
      );
      addTearDown(repo.dispose);
      final events = <ControllerBindingEvent>[];
      repo.bindingEvents.listen(events.add);

      cc(11, 40);
      await Future<void>.delayed(Duration.zero);
      cc(11, 40);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
    });
  });

  group('discrete bindings', () {
    ControllerRepository buildDiscrete({
      BindingBehavior behavior = BindingBehavior.toggle,
    }) => build(
      bindings: ControllerBindingSet([
        DiscreteBinding(trigger: stomp, target: 'chain', behavior: behavior),
      ]),
    );

    test('fires on the way up and on the way down', () async {
      final repo = buildDiscrete(behavior: BindingBehavior.momentary);
      addTearDown(repo.dispose);
      final events = <ControllerSwitchEvent>[];
      repo.bindingEvents.listen((e) => events.add(e as ControllerSwitchEvent));

      cc(21, 127);
      await Future<void>.delayed(Duration.zero);
      cc(21, 0);
      await Future<void>.delayed(Duration.zero);

      expect(events.map((e) => e.pressed), [true, false]);
      expect(events.first.behavior, BindingBehavior.momentary);
      expect(events.first.target, 'chain');
    });

    test('sitting on the boundary fires once, and only once', () async {
      final repo = buildDiscrete();
      addTearDown(repo.dispose);
      final events = <ControllerSwitchEvent>[];
      repo.bindingEvents.listen((e) => events.add(e as ControllerSwitchEvent));

      cc(21, 64);
      cc(21, 64);
      cc(21, 70);
      await Future<void>.delayed(Duration.zero);

      expect(events.map((e) => e.pressed), [true]);
    });

    test('jitter around the threshold does not double-fire', () async {
      final repo = buildDiscrete();
      addTearDown(repo.dispose);
      final events = <ControllerSwitchEvent>[];
      repo.bindingEvents.listen((e) => events.add(e as ControllerSwitchEvent));

      cc(21, 64); // on
      cc(21, 63); // inside the hysteresis band: still on
      cc(21, 64);
      cc(21, 62);
      await Future<void>.delayed(Duration.zero);

      expect(events.map((e) => e.pressed), [true]);
    });

    test('a value clear of the band below the threshold releases', () async {
      final repo = buildDiscrete();
      addTearDown(repo.dispose);
      final events = <ControllerSwitchEvent>[];
      repo.bindingEvents.listen((e) => events.add(e as ControllerSwitchEvent));

      cc(21, 127);
      cc(21, 64 - DiscreteBinding.hysteresis - 1);
      await Future<void>.delayed(Duration.zero);

      expect(events.map((e) => e.pressed), [true, false]);
    });
  });

  group('learn', () {
    test(
      'captures a CC at any value, with the channel it arrived on',
      () async {
        final repo = build();
        addTearDown(repo.dispose);

        final captured = repo.learnNext();
        cc(11, 0, channel: 4); // rest position: still a real capture
        final input = await captured;

        expect(input, isNotNull);
        expect(input!.channelTrigger.midiChannel, 4);
        expect(input.channelTrigger.id, 11);
      },
    );

    test('a note is captured on its press, not its release', () async {
      final repo = build();
      addTearDown(repo.dispose);

      final captured = repo.learnNext();
      source
        ..emit(
          const RawControllerInput(
            kind: ControllerSourceKind.midiNote,
            id: 60,
            value: 0,
          ),
        )
        ..emit(
          const RawControllerInput(
            kind: ControllerSourceKind.midiNote,
            id: 61,
            value: 100,
          ),
        );

      expect((await captured)!.id, 61);
    });

    test(
      'ignores filtered (pedal) traffic and catches the next control',
      () async {
        // Stands in for `isPedalProtocolInput`, whose real note/CC tables are
        // covered by pedal_repository's own test — what matters here is that a
        // filtered input cannot end a capture.
        final repo = build(learnIgnore: (input) => input.id == 16);
        addTearDown(repo.dispose);

        final captured = repo.learnNext();
        cc(16, 65); // pedal encoder chatter
        cc(11, 40); // the control the user actually moved
        final input = await captured;

        expect(input!.id, 11);
      },
    );

    test('bindings do not dispatch while a capture is pending', () async {
      final repo = build(
        bindings: ControllerBindingSet(const [
          ContinuousBinding(trigger: expression, target: 'cutoff'),
        ]),
      );
      addTearDown(repo.dispose);
      final events = <ControllerBindingEvent>[];
      repo.bindingEvents.listen(events.add);

      unawaited(repo.learnNext());
      cc(11, 100);
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);
    });
  });

  group('inert states', () {
    test(
      'a rig with no MIDI source produces no events and disposes cleanly',
      () async {
        final repo = build(
          sources: const [],
          bindings: ControllerBindingSet(const [
            ContinuousBinding(trigger: expression, target: 'cutoff'),
            DiscreteBinding(trigger: stomp, target: 'chain'),
          ]),
        );
        final events = <ControllerBindingEvent>[];
        repo.bindingEvents.listen(events.add);

        await Future<void>.delayed(Duration.zero);
        await repo.dispose();

        expect(events, isEmpty);
      },
    );

    test(
      'a mapping the set no longer carries stops driving anything',
      () async {
        final repo = build(
          bindings: ControllerBindingSet(const [
            ContinuousBinding(trigger: expression, target: 'cutoff'),
          ]),
        );
        addTearDown(repo.dispose);
        final events = <ControllerBindingEvent>[];
        repo.bindingEvents.listen(events.add);

        repo.setBindings(ControllerBindingSet.empty);
        cc(11, 127);
        await Future<void>.delayed(Duration.zero);

        expect(events, isEmpty);
      },
    );

    test(
      'a re-added mapping jumps again rather than ramping from a stale value',
      () async {
        const binding = ContinuousBinding(
          trigger: expression,
          target: 'cutoff',
        );
        final repo = build(bindings: ControllerBindingSet(const [binding]));
        addTearDown(repo.dispose);
        final values = <double>[];
        repo.bindingEvents.listen(
          (e) => values.add((e as ControllerValueEvent).value),
        );

        cc(11, 0);
        await Future<void>.delayed(Duration.zero);
        repo
          ..setBindings(ControllerBindingSet.empty)
          ..setBindings(ControllerBindingSet(const [binding]));
        cc(11, 127);
        await Future<void>.delayed(Duration.zero);

        expect(values, [0, closeTo(1, 1e-9)]);
      },
    );
  });
}
