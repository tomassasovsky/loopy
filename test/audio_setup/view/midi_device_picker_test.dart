import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:midi_client/midi_client.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/helpers.dart';

class _MockMidiSetupCubit extends MockCubit<MidiSetupState>
    implements MidiSetupCubit {}

void main() {
  const dev1 = MidiDevice(id: 'id-1', name: 'FCB1010');
  const dev2 = MidiDevice(id: 'id-2', name: 'SoftStep');

  late _MockMidiSetupCubit cubit;

  setUp(() {
    cubit = _MockMidiSetupCubit();
    when(() => cubit.select(any())).thenAnswer((_) async {});
  });

  void seed(MidiSetupState state) {
    when(() => cubit.state).thenReturn(state);
    whenListen(
      cubit,
      const Stream<MidiSetupState>.empty(),
      initialState: state,
    );
  }

  Future<void> pumpPicker(WidgetTester tester) => tester.pumpApp(
    BlocProvider<MidiSetupCubit>.value(
      value: cubit,
      child: const Material(
        child: SingleChildScrollView(child: MidiDevicePicker()),
      ),
    ),
  );

  testWidgets('shows the empty state when no devices and no selection', (
    tester,
  ) async {
    seed(const MidiSetupState());
    await pumpPicker(tester);

    expect(find.byKey(const Key('midiSettings_empty')), findsOneWidget);
    expect(
      find.byKey(const Key('midiSettings_device_picker')),
      findsNothing,
    );
    expect(find.text('No MIDI input devices found'), findsOneWidget);
  });

  testWidgets('shows the required-CC hint', (tester) async {
    seed(const MidiSetupState(devices: [dev1]));
    await pumpPicker(tester);

    expect(
      find.text('CC 80 record · 81 stop · 82 undo · 83 clear'),
      findsOneWidget,
    );
  });

  testWidgets('renders the dropdown with a single device', (tester) async {
    seed(const MidiSetupState(devices: [dev1]));
    await pumpPicker(tester);

    expect(
      find.byKey(const Key('midiSettings_device_picker')),
      findsOneWidget,
    );
    // With no selection the button shows "None"; the device is in the menu.
    await tester.tap(find.byKey(const Key('midiSettings_device_picker')));
    await tester.pumpAndSettle();
    expect(find.text('FCB1010'), findsOneWidget);
  });

  testWidgets('lists many devices plus a None item in the menu', (
    tester,
  ) async {
    seed(const MidiSetupState(devices: [dev1, dev2]));
    await pumpPicker(tester);

    await tester.tap(find.byKey(const Key('midiSettings_device_picker')));
    await tester.pumpAndSettle();

    expect(find.text('None'), findsWidgets);
    expect(find.text('FCB1010'), findsWidgets);
    expect(find.text('SoftStep'), findsWidgets);
  });

  testWidgets('duplicate names: selecting opens the correct id', (
    tester,
  ) async {
    const dupA = MidiDevice(id: 'id-A', name: 'USB MIDI');
    const dupB = MidiDevice(id: 'id-B', name: 'USB MIDI');
    seed(const MidiSetupState(devices: [dupA, dupB]));
    await pumpPicker(tester);

    await tester.tap(find.byKey(const Key('midiSettings_device_picker')));
    await tester.pumpAndSettle();

    // Two identically-named items are shown; tapping the second opens id-B.
    final items = find.text('USB MIDI');
    expect(items, findsNWidgets(2));
    await tester.tap(items.last);
    await tester.pumpAndSettle();

    verify(() => cubit.select('id-B')).called(1);
  });

  testWidgets('absent pinned device stays selectable as "(not found)"', (
    tester,
  ) async {
    seed(
      const MidiSetupState(
        devices: [dev1], // id-9 absent
        selectedId: 'id-9',
        selectedName: 'Ghost',
        status: MidiSetupStatus.deviceGone,
      ),
    );
    await pumpPicker(tester);

    expect(find.text('Ghost (not found)'), findsOneWidget);
    expect(find.byKey(const Key('midiSettings_status')), findsOneWidget);
  });

  testWidgets('selecting None deselects the device', (tester) async {
    seed(
      const MidiSetupState(
        devices: [dev1],
        selectedId: 'id-1',
        selectedName: 'FCB1010',
        status: MidiSetupStatus.connected,
      ),
    );
    await pumpPicker(tester);

    await tester.tap(find.byKey(const Key('midiSettings_device_picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('None').last);
    await tester.pumpAndSettle();

    verify(() => cubit.select('')).called(1);
  });

  testWidgets('the activity indicator blinks on an activity tick and is '
      'labelled', (tester) async {
    final states = StreamController<MidiSetupState>.broadcast();
    addTearDown(states.close);
    const initial = MidiSetupState(devices: [dev1]);
    when(() => cubit.state).thenReturn(initial);
    whenListen(cubit, states.stream, initialState: initial);
    await pumpPicker(tester);

    // Idle until a message arrives (screen-reader labelled, not color-only).
    expect(find.text('Waiting for MIDI input'), findsOneWidget);

    // A bumped activity tick drives the blink (the cubit exposes no stream).
    const bumped = MidiSetupState(devices: [dev1], activityTick: 1);
    when(() => cubit.state).thenReturn(bumped);
    states.add(bumped);
    await tester.pump();
    expect(find.text('MIDI activity'), findsOneWidget);

    // It returns to idle after the blink window.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Waiting for MIDI input'), findsOneWidget);
  });

  testWidgets('the picker is keyboard/tap operable and emits a selection', (
    tester,
  ) async {
    seed(const MidiSetupState(devices: [dev1, dev2]));
    await pumpPicker(tester);

    await tester.tap(find.byKey(const Key('midiSettings_device_picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SoftStep').last);
    await tester.pumpAndSettle();

    verify(() => cubit.select('id-2')).called(1);
  });
}
