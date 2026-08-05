import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/setup/setup_surface.dart';
import 'package:segno/theme/app_theme.dart';
import 'package:segno/theme/surface_theme.dart';

/// Pumps [child] under [theme] and returns its build context.
Future<BuildContext> _pump(
  WidgetTester tester,
  ThemeData theme,
  Widget child,
) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Builder(
          builder: (context) {
            captured = context;
            return child;
          },
        ),
      ),
    ),
  );
  return captured;
}

void main() {
  group('setup typography', () {
    // These styles were `const` with baked-in dark hexes, so every settings
    // and tray surface using them ignored the high-contrast variant entirely.
    testWidgets('resolves text colours from the default variant', (
      tester,
    ) async {
      final dark = await _pump(
        tester,
        AppTheme.neon,
        const SizedBox.shrink(),
      );
      expect(dark.setupBody.color, SurfaceTheme.dark.textSecondary);
      expect(dark.setupTitle.color, SurfaceTheme.dark.textPrimary);
      expect(dark.setupKicker.color, SurfaceTheme.dark.textTertiary);
      expect(dark.setupSliderTheme.activeTrackColor, SurfaceTheme.dark.accent);
    });

    testWidgets('follows the high-contrast variant', (tester) async {
      final hc = await _pump(
        tester,
        AppTheme.highContrast,
        const SizedBox.shrink(),
      );
      expect(hc.setupBody.color, SurfaceTheme.highContrast.textSecondary);
      expect(hc.setupTitle.color, SurfaceTheme.highContrast.textPrimary);
      expect(hc.setupKicker.color, SurfaceTheme.highContrast.textTertiary);
      expect(
        hc.setupSliderTheme.activeTrackColor,
        SurfaceTheme.highContrast.accent,
      );
    });

    testWidgets('the kicker clears AA against the card it sits on', (
      tester,
    ) async {
      // Regression: the kicker used to hold the pre-WCAG-lift tertiary
      // (0xFF5B5D67, ~2.6:1) long after the token itself was raised.
      final context = await _pump(
        tester,
        AppTheme.neon,
        const SizedBox.shrink(),
      );
      final fg = context.setupKicker.color!.computeLuminance();
      final bg = SurfaceTheme.dark.card.computeLuminance();
      final hi = fg > bg ? fg : bg;
      final lo = fg > bg ? bg : fg;
      expect((hi + 0.05) / (lo + 0.05), greaterThanOrEqualTo(4.5));
    });
  });

  group('SetupOptionRow interaction states', () {
    Widget rowOf({int selected = 0}) => SetupOptionRow<int>(
      options: const [
        SetupOption(value: 0, label: 'One', optionKey: Key('opt0')),
        SetupOption(value: 1, label: 'Two', optionKey: Key('opt1')),
      ],
      selected: selected,
      onSelected: (_) {},
    );

    Color fillOf(WidgetTester tester, Key key) {
      final container = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(key),
          matching: find.byType(AnimatedContainer),
        ),
      );
      return (container.decoration! as BoxDecoration).color!;
    }

    testWidgets('an unselected card lifts on hover and again on press', (
      tester,
    ) async {
      await _pump(tester, AppTheme.neon, rowOf());
      final rest = fillOf(tester, const Key('opt1'));
      expect(rest, SurfaceTheme.dark.card);

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      final centre = tester.getCenter(find.byKey(const Key('opt1')));
      await tester.sendEventToBinding(pointer.hover(centre));
      await tester.pumpAndSettle();
      final hovered = fillOf(tester, const Key('opt1'));
      expect(
        hovered,
        isNot(rest),
        reason: 'hover must be visible — this is a desktop app',
      );

      await tester.sendEventToBinding(pointer.down(centre));
      await tester.pumpAndSettle();
      expect(
        fillOf(tester, const Key('opt1')),
        isNot(hovered),
        reason: 'pressed is a deeper tier than hover',
      );

      await tester.sendEventToBinding(pointer.up());
      await tester.pumpAndSettle();
    });

    testWidgets('hover never borrows the accent that means selected', (
      tester,
    ) async {
      await _pump(tester, AppTheme.neon, rowOf());
      final pointer = TestPointer(2, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.byKey(const Key('opt1')))),
      );
      await tester.pumpAndSettle();

      final border =
          (tester
                      .widget<AnimatedContainer>(
                        find.descendant(
                          of: find.byKey(const Key('opt1')),
                          matching: find.byType(AnimatedContainer),
                        ),
                      )
                      .decoration!
                  as BoxDecoration)
              .border!
              .top
              .color;
      expect(border, isNot(SurfaceTheme.dark.accent));
      expect(border, SurfaceTheme.dark.borderStrong);
    });
  });

  group('ink defaults', () {
    test('stock InkWells inherit the DS hover/pressed tiers', () {
      expect(AppTheme.neon.hoverColor, SurfaceTheme.dark.borderHairline);
      expect(AppTheme.neon.highlightColor, SurfaceTheme.dark.borderSubtle);
      expect(
        AppTheme.highContrast.hoverColor,
        SurfaceTheme.highContrast.borderHairline,
      );
      expect(
        AppTheme.highContrast.highlightColor,
        SurfaceTheme.highContrast.borderSubtle,
      );
    });
  });
}
