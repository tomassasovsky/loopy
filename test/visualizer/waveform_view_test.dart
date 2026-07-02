import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/visualizer/visualizer.dart';

void main() {
  testWidgets('WaveformView paints with the active theme', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        home: Scaffold(
          body: WaveformView(
            samples: Float32List.fromList([0, 0.5, 1, 0.5, 0]),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('waveform_view_paint')), findsOneWidget);
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

    await tester.pumpWidget(WaveformWindowApp(frame: frame, title: 'Output'));
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
