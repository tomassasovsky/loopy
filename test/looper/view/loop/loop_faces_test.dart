import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/loop_tab.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/loop/loop_tray_panel.dart';
import 'package:segno/looper/view/loop/looper_mode_change.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

/// A rig with content on one track — what puts the mode change behind the D4
/// confirmation.
const _withContent = LooperState(
  tracks: [Track(state: TrackState.playing, lengthFrames: 4000)],
);

void main() {
  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late TempoCubit tempo;
  late RecordOptionsCubit options;
  late ControlCubit control;
  late SettingsTrayCubit tray;

  setUpAll(() {
    registerFallbackValue(const LooperRecordPressed(0));
    registerFallbackValue(GridDivision.off);
    registerFallbackValue(ClickMode.off);
    registerFallbackValue(LooperMode.multi);
  });

  setUp(() {
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    when(() => repository.state).thenReturn(const LooperState());
    when(() => repository.setTempo(any())).thenReturn(EngineResult.ok);
    when(() => repository.tapTempo()).thenReturn(EngineResult.ok);
    when(
      () => repository.setTimeSignature(any(), any()),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setSyncTempo(on: any(named: 'on')),
    ).thenReturn(EngineResult.ok);
    when(() => repository.setQuantizeDiv(any())).thenReturn(EngineResult.ok);
    when(() => repository.setClickMode(any())).thenReturn(EngineResult.ok);
    when(() => repository.setClickOutput(any())).thenReturn(EngineResult.ok);
    when(() => repository.setClickVolume(any())).thenReturn(EngineResult.ok);
    when(() => repository.setCountIn(any())).thenReturn(EngineResult.ok);
    when(
      () => repository.setDefaultMultiple(multiple: any(named: 'multiple')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setRecDub(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setAutoRecord(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.clear(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMute(
        muted: any(named: 'muted'),
        channel: any(named: 'channel'),
      ),
    ).thenReturn(EngineResult.ok);
    when(() => repository.setLooperMode(any())).thenReturn(EngineResult.ok);
  });

  /// Seeds the mock bloc's [LooperState] as both `.state` and the stream's
  /// initial value.
  void seed(LooperState state, {Stream<LooperState>? stream}) {
    when(() => bloc.state).thenReturn(state);
    whenListen(
      bloc,
      stream ?? const Stream<LooperState>.empty(),
      initialState: state,
    );
  }

  /// Mounts the Loop face with the providers the real tray inherits.
  ///
  /// 1920x1080, deliberately: this face is drawn for that surface, and the
  /// default 800x600 test view pushes the lower rows below the fold where a
  /// tap lands on nothing.
  Future<void> pump(WidgetTester tester, {LoopTab tab = LoopTab.tempo}) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = SettingsRepository(store: FakeKeyValueStore());
    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    tempo = TempoCubit(repository: repository, settings: settings);
    options = RecordOptionsCubit(repository: repository, settings: settings);
    control = ControlCubit(
      looper: repository,
      pedal: PedalRepository(const NoopPedalTransport()),
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
    );
    tray = SettingsTrayCubit(settings: settings)..showLoopTab(tab);
    // unawaited: awaiting a cubit close inside a testWidgets body deadlocks on
    // the binding's stream cancellation (flutter/flutter#139870).
    addTearDown(() => unawaited(tempo.close()));
    addTearDown(() => unawaited(options.close()));
    addTearDown(() => unawaited(control.close()));
    addTearDown(() => unawaited(tray.close()));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
          ],
        ),
        home: RepositoryProvider<LooperRepository>.value(
          value: repository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider.value(value: tempo),
              BlocProvider.value(value: options),
              BlocProvider.value(value: control),
              BlocProvider.value(value: tray),
            ],
            child: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(19),
                child: LoopTrayPanel(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(LoopTrayPanel)));

  group('Loop domain', () {
    testWidgets('the tab strip swaps the body', (tester) async {
      seed(const LooperState());
      await pump(tester);
      expect(find.byKey(const Key('loop_tempo_tab')), findsOneWidget);

      await tester.tap(find.text(l10nOf(tester).loopClickTab));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('loop_tempo_tab')), findsNothing);
      expect(find.byKey(const Key('loop_click_tab')), findsOneWidget);

      await tester.tap(find.text(l10nOf(tester).loopModeTab));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('loop_mode_tab')), findsOneWidget);
    });

    testWidgets('the domain names itself once, above the strip', (
      tester,
    ) async {
      seed(const LooperState());
      await pump(tester);
      expect(find.text(l10nOf(tester).trayLoopLabel), findsOneWidget);
    });

    testWidgets('the tab survives navigating away and back', (tester) async {
      seed(const LooperState());
      await pump(tester);
      await tester.tap(find.text(l10nOf(tester).loopModeTab));
      await tester.pumpAndSettle();

      tray.showHome();
      await tester.pumpAndSettle();
      tray.showDestination(SettingsTrayDestination.loop);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('loop_mode_tab')), findsOneWidget);
    });
  });

  group('Tempo face', () {
    testWidgets(
      'reads the LIVE engine tempo, not the persisted intent — a tapped or '
      'loop-derived tempo never reaches TempoCubit, so a face that read the '
      'cubit would look dead for every input the user cannot type',
      (tester) async {
        seed(const LooperState(transport: TransportState(tempoBpm: 132)));
        await pump(tester);

        // The cubit still holds its "never explicitly set" zero.
        expect(tempo.state.bpm, 0);
        expect(find.text(l10nOf(tester).loopTempoReadout('132.0')), findsOne);
      },
    );

    testWidgets('says a tempo is unset rather than drawing it as zero', (
      tester,
    ) async {
      seed(const LooperState());
      await pump(tester);
      expect(find.text(l10nOf(tester).loopTempoUnset), findsOne);
    });

    testWidgets(
      'the signature row opens IN PLACE and picking applies and closes',
      (tester) async {
        seed(const LooperState(transport: TransportState(tempoBpm: 120)));
        await pump(tester);

        expect(find.byKey(const Key('loop_signature_3_4')), findsNothing);
        await tester.tap(find.byKey(const Key('loop_signature_row')));
        await tester.pumpAndSettle();
        // The row it opened from is still on screen — that is what "in place"
        // buys over a modal.
        expect(find.byKey(const Key('loop_signature_row')), findsOneWidget);
        expect(find.byKey(const Key('loop_signature_3_4')), findsOneWidget);

        await tester.tap(find.byKey(const Key('loop_signature_3_4')));
        await tester.pumpAndSettle();

        verify(() => repository.setTimeSignature(3, 4)).called(1);
        expect(find.byKey(const Key('loop_signature_3_4')), findsNothing);
      },
    );

    testWidgets('a chooser grows open rather than appearing between frames', (
      tester,
    ) async {
      seed(const LooperState());
      await pump(tester);

      await tester.tap(find.byKey(const Key('loop_quantise_row')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));

      // Mid-flight: taller than nothing, shorter than settled. Goldens only
      // ever photograph the settled state, so the motion needs asserting here.
      final midway = tester
          .getSize(find.byKey(const Key('loop_quantise_slot')))
          .height;
      expect(midway, greaterThan(0));

      await tester.pumpAndSettle();
      final settled = tester
          .getSize(find.byKey(const Key('loop_quantise_slot')))
          .height;
      expect(midway, lessThan(settled));
    });

    testWidgets('only one chooser is open at a time', (tester) async {
      seed(const LooperState());
      await pump(tester);

      await tester.tap(find.byKey(const Key('loop_quantise_row')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('loop_quantise_off')), findsOneWidget);

      await tester.tap(find.byKey(const Key('loop_count_in_row')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('loop_quantise_off')), findsNothing);
      expect(find.byKey(const Key('loop_count_in_1')), findsOneWidget);
    });

    testWidgets(
      'seventeen time signatures lay out as a grid, not a column — a column '
      'is 1,190px of scroll inside an 830px sheet, each row spending its '
      'whole width on four characters',
      (tester) async {
        seed(const LooperState());
        await pump(tester);

        await tester.tap(find.byKey(const Key('loop_signature_row')));
        await tester.pumpAndSettle();

        for (final ts in kValidTimeSignatures) {
          expect(
            find.byKey(Key('loop_signature_${ts.$1}_${ts.$2}')),
            findsOneWidget,
            reason: '${ts.$1}/${ts.$2} has no cell',
          );
        }

        final chooser = tester.getSize(
          find.byKey(const Key('loop_signature_slot')),
        );
        // Comfortably under what even a quarter of them would cost as rows.
        expect(
          chooser.height,
          lessThan(kConsoleRowHeight * 4),
          reason: 'the chooser fell back to one row per option',
        );
        // And the cells share the width rather than each taking all of it.
        final cell = tester.getSize(
          find.byKey(const Key('loop_signature_3_4')),
        );
        expect(cell.height, ConsoleChipGrid.cellHeight);
        expect(cell.width, lessThan(chooser.width / 4));
      },
    );

    testWidgets(
      'quantise offers every division the engine has, not the four the '
      'mockup drew',
      (tester) async {
        seed(const LooperState());
        await pump(tester);
        await tester.tap(find.byKey(const Key('loop_quantise_row')));
        await tester.pumpAndSettle();

        for (final div in GridDivision.values) {
          expect(
            find.byKey(Key('loop_quantise_${div.name}')),
            findsOneWidget,
            reason: '$div has no row',
          );
        }
      },
    );

    testWidgets(
      'loop length is a multiple, and keeps "first take sets it" only while '
      'it reads Auto',
      (tester) async {
        seed(const LooperState());
        await pump(tester);
        final l10n = l10nOf(tester);

        expect(find.text(l10n.loopLengthHint), findsOne);
        expect(find.text(l10n.loopLengthAuto), findsOne);

        await tester.tap(find.byKey(const Key('loop_length_row')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('loop_length_2')));
        await tester.pumpAndSettle();

        verify(() => repository.setDefaultMultiple(multiple: 2)).called(1);
        expect(find.text(l10n.loopLengthHint), findsNothing);
        expect(find.text(l10n.loopLengthMultiple(2)), findsOne);
      },
    );

    testWidgets('the sync switch writes through the cubit', (tester) async {
      seed(const LooperState());
      await pump(tester);

      await tester.tap(find.byKey(const Key('loop_sync_switch')));
      await tester.pumpAndSettle();
      verify(() => repository.setSyncTempo(on: false)).called(1);
    });
  });

  group('Click face', () {
    /// The bar's own track, which is what a fill has to be measured against.
    /// The bar's own track. `.first` is the innermost ancestor — the card
    /// around the whole face clips too.
    Rect trackOf(WidgetTester tester) => tester.getRect(
      find
          .ancestor(
            of: find.byKey(ConsoleValueBar.fillKey),
            matching: find.byType(ClipRRect),
          )
          .first,
    );

    testWidgets('the click volume bar draws a fill with real geometry', (
      tester,
    ) async {
      seed(const LooperState(transport: TransportState(clickVolume: 1.4)));
      await pump(tester, tab: LoopTab.click);
      await tester.pumpAndSettle();

      final fill = tester.getRect(find.byKey(ConsoleValueBar.fillKey));
      final track = trackOf(tester);

      // Height first: a childless box in a loosely-constrained Align takes
      // zero of it, which draws the right width and nothing visible.
      expect(fill.height, moreOrLessEquals(track.height, epsilon: 1));
      // And the width is the value over the WHOLE gain stage, so unity sits
      // at half the bar and 1.4 at seven tenths of it.
      expect(
        fill.width,
        moreOrLessEquals(track.width * 1.4 / kMaxClickGain, epsilon: 2),
      );
    });

    testWidgets(
      'a tap at the right edge reaches the engine ceiling, not unity — the '
      'console must have the same range the Settings slider does',
      (tester) async {
        seed(const LooperState());
        await pump(tester, tab: LoopTab.click);
        await tester.pumpAndSettle();

        final track = trackOf(tester);
        await tester.tapAt(Offset(track.right - 1, track.center.dy));
        await tester.pump();

        final written =
            verify(
                  () => repository.setClickVolume(captureAny()),
                ).captured.last
                as double;
        expect(written, moreOrLessEquals(kMaxClickGain, epsilon: 0.02));

        // Let the double-tap window lapse rather than leaving a live timer.
        await tester.pump(kDoubleTapTimeout * 2);
      },
    );

    testWidgets(
      'a single tap applies on the frame it lands, without waiting out the '
      'double-tap window — a disambiguating recognizer would charge that '
      'latency to every tap on a control people drag',
      (tester) async {
        seed(const LooperState());
        await pump(tester, tab: LoopTab.click);
        await tester.pumpAndSettle();

        final track = trackOf(tester);
        await tester.tapAt(
          Offset(track.left + track.width / 4, track.center.dy),
        );
        await tester.pump();

        verify(() => repository.setClickVolume(any())).called(1);
        await tester.pump(kDoubleTapTimeout * 2);
      },
    );

    testWidgets('a double tap snaps the click back to unity', (tester) async {
      seed(const LooperState(transport: TransportState(clickVolume: 0.2)));
      await pump(tester, tab: LoopTab.click);
      await tester.pumpAndSettle();

      final track = trackOf(tester);
      final spot = Offset(track.right - 1, track.center.dy);
      await tester.tapAt(spot);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(spot);
      await tester.pump();

      final written =
          verify(
                () => repository.setClickVolume(captureAny()),
              ).captured.last
              as double;
      expect(written, moreOrLessEquals(1, epsilon: 0.001));
    });

    testWidgets('the click mode chooser applies and closes', (tester) async {
      seed(const LooperState());
      await pump(tester, tab: LoopTab.click);

      await tester.tap(find.byKey(const Key('loop_click_when_row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_click_when_playRec')));
      await tester.pumpAndSettle();

      verify(() => repository.setClickMode(ClickMode.playRec)).called(1);
      expect(find.byKey(const Key('loop_click_when_playRec')), findsNothing);
    });

    testWidgets(
      'the output chooser is multi-select: a tap toggles one bit and the '
      'list stays open, because no single pick answers the question',
      (tester) async {
        seed(
          const LooperState(
            transport: TransportState(clickMask: 1),
            status: EngineStatus(sampleRate: 48000, outputChannels: 4),
          ),
        );
        await pump(tester, tab: LoopTab.click);

        await tester.tap(find.byKey(const Key('loop_click_output_row')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('loop_click_output_3')), findsOneWidget);

        await tester.tap(find.byKey(const Key('loop_click_output_1')));
        await tester.pumpAndSettle();

        // Bit 1 added to bit 0, not replacing it.
        verify(() => repository.setClickOutput(0x3)).called(1);
        expect(find.byKey(const Key('loop_click_output_1')), findsOneWidget);
      },
    );

    testWidgets('an unrouted click says so instead of listing nothing', (
      tester,
    ) async {
      seed(const LooperState());
      await pump(tester, tab: LoopTab.click);
      expect(find.text(l10nOf(tester).loopClickOutputNone), findsOne);
    });

    testWidgets('eighteen outputs stay a grid too', (tester) async {
      seed(
        const LooperState(
          status: EngineStatus(sampleRate: 48000, outputChannels: 18),
        ),
      );
      await pump(tester, tab: LoopTab.click);

      await tester.tap(find.byKey(const Key('loop_click_output_row')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('loop_click_output_17')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('loop_click_output_slot'))).height,
        lessThan(kConsoleRowHeight * 4),
      );
    });

    testWidgets(
      'a wide interface counts its outputs rather than naming them all — a '
      'sentence in the readout column pushes the row marker off the card',
      (tester) async {
        seed(
          const LooperState(
            // Five of eighteen, so neither "nowhere" nor "all outputs".
            transport: TransportState(clickMask: 0x1F),
            status: EngineStatus(sampleRate: 48000, outputChannels: 18),
          ),
        );
        await pump(tester, tab: LoopTab.click);
        expect(find.text(l10nOf(tester).loopClickOutputCount(5)), findsOne);
      },
    );
  });

  group('Mode face', () {
    testWidgets(
      'every mode carries the one-liner that makes it choosable, and the row '
      'carries the current one',
      (tester) async {
        seed(const LooperState());
        await pump(tester, tab: LoopTab.mode);
        final l10n = l10nOf(tester);

        expect(find.text(l10n.looperModeMultiSub), findsOne);

        await tester.tap(find.byKey(const Key('loop_mode_row')));
        await tester.pumpAndSettle();
        for (final entry in looperModeLabels(l10n).entries) {
          expect(
            find.text(entry.value.sub),
            findsWidgets,
            reason: '${entry.key} has no one-liner',
          );
        }
      },
    );

    testWidgets('switching mode on an empty session dispatches immediately', (
      tester,
    ) async {
      seed(const LooperState());
      await pump(tester, tab: LoopTab.mode);

      await tester.tap(find.byKey(const Key('loop_mode_row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_mode_sync')));
      await tester.pumpAndSettle();

      verify(
        () => bloc.add(const LooperModeChanged(LooperMode.sync)),
      ).called(1);
      expect(find.byKey(const Key('console_confirm_confirm')), findsNothing);
    });

    testWidgets(
      'switching mode with content raises the D4 confirm and dispatches '
      'nothing until it is answered',
      (tester) async {
        seed(_withContent);
        await pump(tester, tab: LoopTab.mode);

        await tester.tap(find.byKey(const Key('loop_mode_row')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('loop_mode_song')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('console_confirm_confirm')),
          findsOneWidget,
        );
        verifyNever(() => bloc.add(any()));
        // The list is still open behind the dialog, as the mockup draws it.
        expect(find.byKey(const Key('loop_mode_free')), findsOneWidget);

        await tester.tap(find.byKey(const Key('console_confirm_cancel')));
        await tester.pumpAndSettle();
        verifyNever(() => bloc.add(any()));
        // And a declined confirm leaves the user still choosing.
        expect(find.byKey(const Key('loop_mode_free')), findsOneWidget);
      },
    );

    testWidgets(
      'the rig-wide one-shot switch reads OFF on an empty session — `every` '
      'on an empty list is vacuously true, which is never what the row means',
      (tester) async {
        seed(const LooperState());
        await pump(tester, tab: LoopTab.mode);

        final row = tester.widget<ConsoleSwitch>(
          find.byKey(const Key('loop_one_shot_switch')),
        );
        expect(row.value, isFalse);
        // And there is nothing to apply it to, so it does not offer.
        expect(row.onChanged, isNull);
      },
    );

    testWidgets('the one-shot switch reads the whole rig and writes it', (
      tester,
    ) async {
      seed(
        const LooperState(
          tracks: [
            Track(oneShot: true),
            Track(channel: 1, oneShot: true),
          ],
        ),
      );
      await pump(tester, tab: LoopTab.mode);

      final row = tester.widget<ConsoleSwitch>(
        find.byKey(const Key('loop_one_shot_switch')),
      );
      expect(row.value, isTrue);

      await tester.tap(find.byKey(const Key('loop_one_shot_switch')));
      await tester.pumpAndSettle();
      verify(
        () => bloc.add(const LooperOneShotToggled(0, oneShot: false)),
      ).called(1);
      verify(
        () => bloc.add(const LooperOneShotToggled(1, oneShot: false)),
      ).called(1);
    });

    testWidgets('one mixed track is not the whole rig', (tester) async {
      seed(
        const LooperState(
          tracks: [Track(oneShot: true), Track(channel: 1)],
        ),
      );
      await pump(tester, tab: LoopTab.mode);

      expect(
        tester
            .widget<ConsoleSwitch>(
              find.byKey(const Key('loop_one_shot_switch')),
            )
            .value,
        isFalse,
      );
    });

    testWidgets(
      'the boot default offers record and mute only — booting into FX with no '
      'chains configured is a dead surface (R12)',
      (tester) async {
        seed(const LooperState());
        await pump(tester, tab: LoopTab.mode);

        await tester.tap(find.byKey(const Key('loop_default_mode_row')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('loop_default_mode_record')), findsOne);
        expect(find.byKey(const Key('loop_default_mode_mute')), findsOne);
        expect(find.byKey(const Key('loop_default_mode_fx')), findsNothing);

        await tester.tap(find.byKey(const Key('loop_default_mode_mute')));
        await tester.pumpAndSettle();
        expect(control.state.defaultMode, InteractionMode.mute);
      },
    );
  });

  group('Tempo keypad sheet', () {
    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('loop_tempo_row')));
      await tester.pumpAndSettle();
    }

    testWidgets('opens showing the live tempo, and typing replaces it', (
      tester,
    ) async {
      seed(const LooperState(transport: TransportState(tempoBpm: 120)));
      await pump(tester);
      await openSheet(tester);

      expect(
        tester.widget<Text>(find.byKey(const Key('tempo_keypad_field'))).data,
        '120.0',
      );

      // The first keypress replaces the shown tempo rather than appending —
      // a buffer seeded with 120.0 would make this read 120.09.
      await tester.tap(find.byKey(const Key('tempo_keypad_9')));
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const Key('tempo_keypad_field'))).data,
        '9',
      );
    });

    testWidgets('Set submits what was typed and closes', (tester) async {
      seed(const LooperState(transport: TransportState(tempoBpm: 120)));
      await pump(tester);
      await openSheet(tester);

      for (final key in ['9', '4', 'dot', '5']) {
        await tester.tap(find.byKey(Key('tempo_keypad_$key')));
        await tester.pump();
      }
      await tester.tap(find.byKey(const Key('tempo_keypad_set')));
      await tester.pumpAndSettle();

      verify(() => repository.setTempo(94.5)).called(1);
      expect(find.byKey(const Key('tempo_keypad_sheet')), findsNothing);
    });

    testWidgets(
      'Tap goes straight to the engine and the field mirrors what the engine '
      'made of it — a tapped tempo is runtime state with nothing to submit',
      (tester) async {
        final states = StreamController<LooperState>.broadcast();
        addTearDown(states.close);
        seed(
          const LooperState(transport: TransportState(tempoBpm: 120)),
          stream: states.stream,
        );
        await pump(tester);
        await openSheet(tester);

        // Type something, so the field is NOT already mirroring.
        await tester.tap(find.byKey(const Key('tempo_keypad_7')));
        await tester.pump();

        await tester.tap(find.byKey(const Key('tempo_keypad_tap')));
        await tester.pump();
        verify(() => repository.tapTempo()).called(1);

        // The engine converges; the sheet shows its answer, not the 7.
        const converged = LooperState(
          transport: TransportState(tempoBpm: 143.2),
        );
        when(() => bloc.state).thenReturn(converged);
        states.add(converged);
        await tester.pump();
        await tester.pump();
        expect(
          tester.widget<Text>(find.byKey(const Key('tempo_keypad_field'))).data,
          '143.2',
        );
      },
    );

    testWidgets('Cancel writes nothing', (tester) async {
      seed(const LooperState(transport: TransportState(tempoBpm: 120)));
      await pump(tester);
      await openSheet(tester);

      await tester.tap(find.byKey(const Key('tempo_keypad_8')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tempo_keypad_cancel')));
      await tester.pumpAndSettle();

      verifyNever(() => repository.setTempo(any()));
      expect(find.byKey(const Key('tempo_keypad_sheet')), findsNothing);
    });
  });
}
