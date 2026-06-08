import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/visualizer/visualizer.dart';

void main() {
  testWidgets('WaveformView paints with the active theme', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.bigPicture,
        home: Scaffold(
          body: WaveformView(
            samples: Float32List.fromList([0, 0.5, 1, 0.5, 0]),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('waveform_view_paint')), findsOneWidget);
  });

  testWidgets('WaveformWindowApp renders the pushed waveform', (tester) async {
    final samples = ValueNotifier<Float32List>(
      Float32List.fromList([0, 1, 0]),
    );
    addTearDown(samples.dispose);

    await tester.pumpWidget(WaveformWindowApp(samples: samples));
    await tester.pump();

    expect(find.byType(WaveformView), findsOneWidget);

    samples.value = Float32List.fromList([1, 0, 1, 0]);
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
  });
}
