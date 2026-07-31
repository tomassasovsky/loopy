import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/model/interaction_mode.dart';
import 'package:loopy/pedal/pedal.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:pedal_repository/pedal_repository.dart';

const _recPlayKey = Key('pedalFaceplate_footswitch_recPlay');
const _mainScreenKey = Key('mainScreen');
const _waveformScreenKey = Key('waveformScreen');

PedalStateFrame _frame({
  int activeBank = 0,
  Map<int, PedalTrackLed> leds = const {},
}) => PedalStateFrame.blank().copyWith(
  trackLeds: [
    for (var i = 0; i < PedalStateFrame.trackCount; i++)
      leds[i] ?? PedalTrackLed.off,
  ],
  activeBank: activeBank,
  selectedTrack: activeBank * 4,
);

void main() {
  /// Pumps [PedalPlate] with no transport, cubit, or bloc providers — only the
  /// theme/localization scaffolding every widget under test needs.
  Future<
    (
      List<({PedalButton button, bool down})>,
      List<int>,
      bool Function(),
    )
  >
  pumpPlate(
    WidgetTester tester, {
    PedalStateFrame? frame,
    Set<PedalButton> selected = const {},
  }) async {
    final presses = <({PedalButton button, bool down})>[];
    final turns = <int>[];
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(extensions: const [SurfaceTheme.dark]),
        home: Builder(
          builder: (context) => Scaffold(
            body: PedalPlate(
              frame: frame ?? _frame(),
              onPress: (button, {required down}) =>
                  presses.add((button: button, down: down)),
              onTurn: turns.add,
              mode: InteractionMode.record,
              l10n: AppLocalizations.of(context),
              mainScreen: const SizedBox(key: _mainScreenKey),
              waveformScreen: const SizedBox(key: _waveformScreenKey),
              onClose: () => closed = true,
              selected: selected,
            ),
          ),
        ),
      ),
    );
    return (presses, turns, () => closed);
  }

  testWidgets('pumps standalone with no transport/cubit/bloc providers', (
    tester,
  ) async {
    await pumpPlate(tester);
    expect(find.byKey(_mainScreenKey), findsOneWidget);
    expect(find.byKey(_waveformScreenKey), findsOneWidget);
    expect(find.byKey(_recPlayKey), findsOneWidget);
  });

  testWidgets('the frame drives LED rendering', (tester) async {
    await pumpPlate(
      tester,
      frame: _frame(leds: {0: PedalTrackLed.red, 1: PedalTrackLed.green}),
    );

    Color ledColor(int channel) =>
        (tester
                    .widget<Container>(
                      find.byKey(Key('pedalFaceplate_led_track$channel')),
                    )
                    .decoration!
                as BoxDecoration)
            .color!;
    expect(ledColor(0), SurfaceTheme.dark.ledRed);
    expect(ledColor(1), SurfaceTheme.dark.ledGreen);
    expect(ledColor(2), SurfaceTheme.dark.ledOff);
  });

  testWidgets('onPress fires with the pressed button on down and up', (
    tester,
  ) async {
    final (presses, _, _) = await pumpPlate(tester);
    await tester.tap(find.byKey(_recPlayKey));
    await tester.pump();

    expect(presses, [
      (button: PedalButton.recPlay, down: true),
      (button: PedalButton.recPlay, down: false),
    ]);
  });

  testWidgets('onTurn fires with the drag-derived detent delta', (
    tester,
  ) async {
    final (_, turns, _) = await pumpPlate(tester);
    await tester.drag(
      find.byKey(const Key('pedalFaceplate_encoder')),
      const Offset(30, 0),
    );
    await tester.pump();

    // A rightward drag turns the encoder forward (positive detents); the
    // exact detent math is the widget's own business, so this only asserts
    // the direction and that something reached onTurn.
    expect(turns, isNotEmpty);
    expect(turns, everyElement(1));
  });

  testWidgets('onClose fires from the close button', (tester) async {
    final (_, _, isClosed) = await pumpPlate(tester);
    await tester.tap(find.byType(CloseButton));
    expect(isClosed(), isTrue);
  });

  testWidgets('the ring animates to off once the loop is cleared', (
    tester,
  ) async {
    Color ringBorderColor(WidgetTester tester) =>
        ((tester
                            .widget<Container>(
                              find.byKey(const Key('pedalFaceplate_encoder')),
                            )
                            .decoration!
                        as BoxDecoration)
                    .border!
                as Border)
            .top
            .color;

    await pumpPlate(
      tester,
      frame: _frame().copyWith(
        globalColor: GlobalColor.green,
        loopLengthMicros: 1000000,
      ),
    );
    expect(ringBorderColor(tester), SurfaceTheme.dark.ledGreen);

    // Rebuild cleared (activity off, no loop left): the ring goes dark.
    await pumpPlate(tester, frame: _frame());
    expect(ringBorderColor(tester), SurfaceTheme.dark.ledOff);
  });

  testWidgets('the MODE LED reflects the frame mode color', (tester) async {
    await pumpPlate(tester, frame: _frame().copyWith(mode: PedalMode.fx));
    final led = tester.widget<Container>(
      find.byKey(const Key('pedalFaceplate_led_mode')),
    );
    expect(
      (led.decoration! as BoxDecoration).color,
      SurfaceTheme.dark.ledBlue,
    );
  });

  group('selection state', () {
    Border footswitchBorder(WidgetTester tester, Key key) =>
        (tester.widget<Container>(find.byKey(key)).decoration! as BoxDecoration)
                .border!
            as Border;

    testWidgets('empty selection renders identically to no selection', (
      tester,
    ) async {
      await pumpPlate(tester);
      final border = footswitchBorder(tester, _recPlayKey);
      expect(border.top.color, SurfaceTheme.dark.line);
      expect(border.top.width, 1);
    });

    testWidgets('a selected button renders highlighted', (tester) async {
      await pumpPlate(tester, selected: {PedalButton.recPlay});
      final border = footswitchBorder(tester, _recPlayKey);
      expect(border.top.color, SurfaceTheme.dark.accent);

      // Only the selected button is highlighted — a sibling switch is
      // unaffected.
      final undoBorder = footswitchBorder(
        tester,
        const Key('pedalFaceplate_footswitch_undo'),
      );
      expect(undoBorder.top.color, SurfaceTheme.dark.line);
    });
  });
}
