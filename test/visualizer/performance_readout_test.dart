import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/visualizer/performance_readout.dart';
import 'package:loopy/visualizer/performance_readout_view.dart';
import 'package:loopy_engine/loopy_engine.dart' show TrackState;

void main() {
  const readout = PerformanceReadout(
    tracks: [
      ReadoutTrack(name: 'Drums', state: 'playing'),
      ReadoutTrack(name: 'Bass', state: 'recording', selected: true),
      ReadoutTrack(name: 'Keys', state: 'playing', muted: true),
      ReadoutTrack(name: 'Gtr', state: 'empty', pending: true),
    ],
    tempoBpm: 128,
    loopBars: 8,
    isRunning: true,
    mode: 'fx',
  );

  group('PerformanceReadout wire format', () {
    test('survives a round trip through the channel payload', () {
      // The payload crosses a method channel between two Flutter engines, so
      // the map is the contract — not the Dart type.
      expect(PerformanceReadout.fromMap(readout.toMap()), readout);
    });

    test('a decoded empty payload is the default readout', () {
      expect(PerformanceReadout.fromMap(const {}), const PerformanceReadout());
    });

    test('equality is by value, which is what makes the push diff work', () {
      expect(
        const PerformanceReadout(tempoBpm: 120),
        const PerformanceReadout(tempoBpm: 120),
      );
      expect(
        const PerformanceReadout(tempoBpm: 120),
        isNot(const PerformanceReadout(tempoBpm: 121)),
      );
    });
  });

  group('PerformanceReadoutView', () {
    Future<void> pump(WidgetTester tester, PerformanceReadout data) =>
        tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.neon,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: PerformanceReadoutView(
                readout: data,
                waveform: const SizedBox(key: Key('waveform_region')),
              ),
            ),
          ),
        );

    testWidgets('shows tempo, bars, mode and every track', (tester) async {
      await pump(tester, readout);

      expect(find.byKey(const Key('readout_tempo')), findsOneWidget);
      expect(find.byKey(const Key('readout_bars')), findsOneWidget);
      expect(find.byKey(const Key('readout_mode')), findsOneWidget);
      expect(find.text('128  4/4'), findsOneWidget);

      for (final name in ['Drums', 'Bass', 'Keys', 'Gtr']) {
        expect(find.text(name), findsOneWidget, reason: '$name is missing');
      }
    });

    testWidgets('keeps the waveform as one region, not the whole surface', (
      tester,
    ) async {
      await pump(tester, readout);
      expect(find.byKey(const Key('waveform_region')), findsOneWidget);
    });

    testWidgets('an armed track reads ARMED, outranking its own state', (
      tester,
    ) async {
      await pump(tester, readout);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      // Gtr is empty AND pending; pending is the thing worth seeing.
      expect(find.text(l10n.readoutStatePending), findsOneWidget);
      // Keys is playing AND muted; muted wins for the same reason.
      expect(find.text(l10n.readoutStateMuted), findsOneWidget);
    });

    testWidgets('hides the bar count when nothing defines a loop yet', (
      tester,
    ) async {
      await pump(tester, const PerformanceReadout(tempoBpm: 120));
      expect(find.byKey(const Key('readout_bars')), findsNothing);
      expect(find.byKey(const Key('readout_tempo')), findsOneWidget);
    });

    testWidgets('renders an unknown mode token verbatim rather than guessing', (
      tester,
    ) async {
      // A newer main window paired with an older sub-window must degrade to
      // showing the raw mode, never to showing the wrong one.
      await pump(tester, const PerformanceReadout(mode: 'custom'));
      expect(find.text('CUSTOM'), findsOneWidget);
    });

    testWidgets('gives every engine TrackState its own label — only empty '
        'may read EMPTY', (tester) async {
      // Driven by TrackState.values, NOT by a hand-listed set: the states I
      // remembered were four of five, and `stopped` (which retains its loop
      // buffer) silently rendered as EMPTY. Anything added to the engine enum
      // fails here until the readout has a word for it.
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      for (final state in TrackState.values) {
        await pump(
          tester,
          PerformanceReadout(
            tracks: [ReadoutTrack(name: 'Drums', state: state.name)],
          ),
        );

        final readsEmpty = find
            .text(l10n.readoutStateEmpty)
            .evaluate()
            .isNotEmpty;
        expect(
          readsEmpty,
          state == TrackState.empty,
          reason: state == TrackState.empty
              ? 'empty must read EMPTY'
              : '${state.name} renders as EMPTY — a track holding audio is '
                    'being reported as having none',
        );
      }
    });

    testWidgets('shows a dash for tempo before the engine reports one', (
      tester,
    ) async {
      await pump(tester, const PerformanceReadout());
      expect(find.text('--  4/4'), findsOneWidget);
    });
  });
}
