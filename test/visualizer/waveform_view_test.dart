import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart' show TrackState;
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/visualizer.dart';

void main() {
  /// The stroke colour [WaveformView] actually handed to its painter.
  Color paintedColor(WidgetTester tester) {
    final paint = tester.widget<CustomPaint>(
      find.byKey(const Key('waveform_view_paint')),
    );
    return (paint.painter! as WaveformPainter).color;
  }

  Future<void> pumpWaveform(
    WidgetTester tester,
    LooperMeterState state, {
    ThemeData? theme,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: theme ?? AppTheme.neon,
      home: Scaffold(
        body: WaveformView(
          samples: Float32List.fromList([0, 0.5, 1, 0.5, 0]),
          state: state,
        ),
      ),
    ),
  );

  testWidgets('WaveformView paints with the active theme', (tester) async {
    await pumpWaveform(tester, LooperMeterState.playing);
    expect(find.byKey(const Key('waveform_view_paint')), findsOneWidget);
  });

  testWidgets('the stroke resolves from the theme table, per state', (
    tester,
  ) async {
    // #499 stage 3b: the waveform is state-coloured, so the same widget in two
    // transport states must paint two different colours — both of them the
    // theme's, never a constant baked into the widget.
    final looper = AppTheme.neon.extension<LooperTheme>()!;
    for (final state in LooperMeterState.values) {
      await pumpWaveform(tester, state);
      expect(
        paintedColor(tester),
        looper.waveformColor(state),
        reason: '$state must paint its own table entry',
      );
    }
    // And the states genuinely differ on screen, rather than all resolving to
    // one colour that happens to satisfy the lookup.
    await pumpWaveform(tester, LooperMeterState.recording);
    final recording = paintedColor(tester);
    await pumpWaveform(tester, LooperMeterState.playing);
    expect(paintedColor(tester), isNot(recording));
  });

  testWidgets('the stroke follows the high-contrast palette too', (
    tester,
  ) async {
    final hc = AppTheme.highContrast.extension<LooperTheme>()!;
    await pumpWaveform(
      tester,
      LooperMeterState.playing,
      theme: AppTheme.highContrast,
    );
    expect(paintedColor(tester), hc.waveformColor(LooperMeterState.playing));
    expect(
      paintedColor(tester),
      isNot(
        AppTheme.neon.extension<LooperTheme>()!.waveformColor(
          LooperMeterState.playing,
        ),
      ),
    );
  });

  testWidgets('exposes a semantic label + playhead value when named (1.1.1)', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        home: Scaffold(
          body: WaveformView(
            samples: Float32List.fromList([0, 0.5, 1]),
            progress: 0.42,
            state: LooperMeterState.playing,
            semanticLabel: 'Output loop waveform',
          ),
        ),
      ),
    );
    expect(
      tester.getSemantics(find.byType(WaveformView)),
      isSemantics(label: 'Output loop waveform', value: '42%'),
    );
    handle.dispose();
  });

  testWidgets('WaveformWindowApp renders the pushed frame', (tester) async {
    final frame = ValueNotifier<WaveformFrame>(
      (
        samples: Float32List.fromList([0, 1, 0]),
        progress: 0.2,
        selectedTrack: '',
      ),
    );
    addTearDown(frame.dispose);

    final readout = ValueNotifier(const PerformanceReadout());
    addTearDown(readout.dispose);

    await tester.pumpWidget(
      WaveformWindowApp(frame: frame, readout: readout, title: 'Output'),
    );
    await tester.pump();

    expect(find.byType(WaveformView), findsOneWidget);

    frame.value = (
      samples: Float32List.fromList([1, 0, 1, 0]),
      progress: 0.6,
      selectedTrack: '',
    );
    await tester.pump();
    expect(find.byType(WaveformView), findsOneWidget);
  });

  group('waveformStateOf', () {
    ReadoutTrack track(
      String state, {
      bool selected = false,
      bool muted = false,
    }) => ReadoutTrack(
      name: 'T',
      state: state,
      muted: muted,
      selected: selected,
    );

    test('reads the cursor track, not whichever track is loudest', () {
      // A track recording somewhere else on the stage must not recolour the
      // waveform: the colour speaks for the same track the name label does.
      expect(
        waveformStateOf(
          PerformanceReadout(
            tracks: [
              track('recording'),
              track('playing', selected: true),
            ],
          ),
        ),
        LooperMeterState.playing,
      );
    });

    test('muted overlays the cursor track state', () {
      expect(
        waveformStateOf(
          PerformanceReadout(
            tracks: [track('playing', selected: true, muted: true)],
          ),
        ),
        LooperMeterState.muted,
      );
    });

    test('maps every track state token the main window can send', () {
      for (final state in TrackState.values) {
        expect(
          waveformStateOf(
            PerformanceReadout(tracks: [track(state.name, selected: true)]),
          ),
          LooperMeterState.of(state, muted: false),
          reason: '${state.name} must survive the trip across the channel',
        );
      }
    });

    test(
      'degrades to empty rather than throwing on a readout it cannot use',
      () {
        // An empty readout is the window's own initial state, and an unknown
        // token is what a version-skewed main window would send. Neither may
        // take down a render.
        expect(
          waveformStateOf(const PerformanceReadout()),
          LooperMeterState.empty,
        );
        expect(
          waveformStateOf(PerformanceReadout(tracks: [track('playing')])),
          LooperMeterState.empty,
          reason: 'no cursor track means nothing to speak for',
        );
        expect(
          waveformStateOf(
            PerformanceReadout(
              tracks: [track('transmogrifying', selected: true)],
            ),
          ),
          LooperMeterState.empty,
        );
      },
    );
  });

  testWidgets('the window colours its waveform from the pushed readout', (
    tester,
  ) async {
    final frame = ValueNotifier<WaveformFrame>(
      (
        samples: Float32List.fromList([0, 1, 0]),
        progress: 0,
        selectedTrack: '',
      ),
    );
    addTearDown(frame.dispose);
    final readout = ValueNotifier(
      const PerformanceReadout(
        tracks: [ReadoutTrack(name: 'T', state: 'recording', selected: true)],
      ),
    );
    addTearDown(readout.dispose);

    await tester.pumpWidget(
      WaveformWindowApp(frame: frame, readout: readout, title: 'Output'),
    );
    await tester.pump();

    final looper = AppTheme.neon.extension<LooperTheme>()!;
    expect(
      paintedColor(tester),
      looper.waveformColor(LooperMeterState.recording),
    );

    // The colour is live, not a one-shot at first build: a state change pushed
    // over the channel has to reach the stroke.
    readout.value = const PerformanceReadout(
      tracks: [ReadoutTrack(name: 'T', state: 'playing', selected: true)],
    );
    await tester.pump();
    expect(
      paintedColor(tester),
      looper.waveformColor(LooperMeterState.playing),
    );
  });

  group('WaveformPainter.shouldRepaint', () {
    final samples = Float32List.fromList([0, 1]);
    const cyan = Color(0xFF00E5FF);

    test('does not repaint for the same list and color', () {
      final painter = WaveformPainter(samples: samples, color: cyan);
      expect(
        painter.shouldRepaint(WaveformPainter(samples: samples, color: cyan)),
        isFalse,
      );
    });

    test('repaints on a new sample list', () {
      final painter = WaveformPainter(samples: samples, color: cyan);
      expect(
        painter.shouldRepaint(
          WaveformPainter(samples: Float32List.fromList([0, 1]), color: cyan),
        ),
        isTrue,
      );
    });

    test('repaints on a color change', () {
      final painter = WaveformPainter(samples: samples, color: cyan);
      expect(
        painter.shouldRepaint(
          WaveformPainter(samples: samples, color: const Color(0xFFFF2D95)),
        ),
        isTrue,
      );
    });

    test('repaints on a playhead change', () {
      final painter = WaveformPainter(
        samples: samples,
        color: cyan,
        progress: 0.2,
      );
      expect(
        painter.shouldRepaint(
          WaveformPainter(samples: samples, color: cyan, progress: 0.5),
        ),
        isTrue,
      );
    });
  });
}
