import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/software_brightness.dart';

void main() {
  group('SoftwareBrightness', () {
    testWidgets('skips ColorFiltered at full brightness', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SoftwareBrightness(
            brightness: 1,
            child: Text('hi'),
          ),
        ),
      );
      expect(find.byType(ColorFiltered), findsNothing);
      expect(find.text('hi'), findsOneWidget);
    });

    testWidgets('wraps with ColorFiltered when dimmed', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SoftwareBrightness(
            brightness: 0.5,
            child: Text('hi'),
          ),
        ),
      );
      expect(find.byType(ColorFiltered), findsOneWidget);
      expect(find.text('hi'), findsOneWidget);
    });
  });

  group('softwareBrightnessFilter', () {
    test('scales RGB by brightness', () {
      final filter = softwareBrightnessFilter(0.5);
      expect(filter, isA<ColorFilter>());
    });
  });

  group('clampDisplayBrightness', () {
    test('floors at kMinDisplayBrightness so 0 is not fully black', () {
      expect(clampDisplayBrightness(0), kMinDisplayBrightness);
      expect(clampDisplayBrightness(0.05), kMinDisplayBrightness);
      expect(clampDisplayBrightness(0.5), 0.5);
      expect(clampDisplayBrightness(1.2), 1.0);
    });
  });
}
