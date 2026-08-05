import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
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
      expect(dark.setupKicker.color, SurfaceTheme.dark.textSecondary);
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
      expect(hc.setupKicker.color, SurfaceTheme.highContrast.textSecondary);
      expect(
        hc.setupSliderTheme.activeTrackColor,
        SurfaceTheme.highContrast.accent,
      );
    });

    testWidgets('the kicker clears AA against the card it sits on', (
      tester,
    ) async {
      // The kicker is the smallest, widest-tracked text on these surfaces, so
      // it is the first thing that stops being readable if the token it
      // resolves ever drops a tier.
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

    BoxDecoration decorationOf(WidgetTester tester, Key key) =>
        tester
                .widget<AnimatedContainer>(
                  find.descendant(
                    of: find.byKey(key),
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration!
            as BoxDecoration;

    Color fillOf(WidgetTester tester, Key key) =>
        decorationOf(tester, key).color!;

    Color borderOf(WidgetTester tester, Key key) =>
        decorationOf(tester, key).border!.top.color;

    // The exact tiers, not merely "something changed": an earlier version of
    // this test used isNot() and stayed green when the two were swapped.
    final restFill = SurfaceTheme.dark.card;
    final hoverFill = Color.alphaBlend(
      SurfaceTheme.dark.borderHairline,
      SurfaceTheme.dark.card,
    );
    final pressFill = Color.alphaBlend(
      SurfaceTheme.dark.borderSubtle,
      SurfaceTheme.dark.card,
    );

    testWidgets('an unselected card lifts one tier on hover, two on press', (
      tester,
    ) async {
      await _pump(tester, AppTheme.neon, rowOf());
      expect(fillOf(tester, const Key('opt1')), restFill);

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      final centre = tester.getCenter(find.byKey(const Key('opt1')));
      await tester.sendEventToBinding(pointer.hover(centre));
      await tester.pumpAndSettle();
      expect(
        fillOf(tester, const Key('opt1')),
        hoverFill,
        reason: 'hover must be visible — this is a desktop app',
      );

      await tester.sendEventToBinding(pointer.down(centre));
      await tester.pumpAndSettle();
      expect(
        fillOf(tester, const Key('opt1')),
        pressFill,
        reason: 'pressed is the deeper tier',
      );
    });

    testWidgets('the pressed and hover tiers both release', (tester) async {
      // Deleting onExit/onPointerUp entirely once left every card permanently
      // lit and still passed: a state that never clears is the real failure
      // mode here, so assert the way back down, not just the way up.
      await _pump(tester, AppTheme.neon, rowOf());
      final pointer = TestPointer(4, PointerDeviceKind.mouse);
      final centre = tester.getCenter(find.byKey(const Key('opt1')));

      await tester.sendEventToBinding(pointer.hover(centre));
      await tester.sendEventToBinding(pointer.down(centre));
      await tester.pumpAndSettle();
      expect(fillOf(tester, const Key('opt1')), pressFill);

      // Releasing drops back to hover — the pointer is still over the card.
      await tester.sendEventToBinding(pointer.up());
      await tester.pumpAndSettle();
      expect(fillOf(tester, const Key('opt1')), hoverFill);

      // Leaving drops back to rest.
      await tester.sendEventToBinding(pointer.hover(const Offset(5, 5)));
      await tester.pumpAndSettle();
      expect(fillOf(tester, const Key('opt1')), restFill);
    });

    testWidgets('a cancelled press clears the pressed tier', (tester) async {
      await _pump(tester, AppTheme.neon, rowOf());
      final pointer = TestPointer(5, PointerDeviceKind.mouse);
      final centre = tester.getCenter(find.byKey(const Key('opt1')));

      await tester.sendEventToBinding(pointer.hover(centre));
      await tester.sendEventToBinding(pointer.down(centre));
      await tester.pumpAndSettle();
      expect(fillOf(tester, const Key('opt1')), pressFill);

      await tester.sendEventToBinding(pointer.cancel());
      await tester.pumpAndSettle();
      expect(fillOf(tester, const Key('opt1')), hoverFill);
    });

    testWidgets('a non-primary press does not reach the pressed tier', (
      tester,
    ) async {
      await _pump(tester, AppTheme.neon, rowOf());
      final pointer = TestPointer(6, PointerDeviceKind.mouse);
      final centre = tester.getCenter(find.byKey(const Key('opt1')));

      await tester.sendEventToBinding(
        pointer.down(centre, buttons: kSecondaryButton),
      );
      await tester.pumpAndSettle();
      // A mouse positioned to right-click is genuinely hovering, so the hover
      // tier is correct here — what must not happen is the pressed tier, which
      // would promise an activation that a secondary click never delivers.
      expect(
        fillOf(tester, const Key('opt1')),
        hoverFill,
        reason: 'a right-click must not light the card as pressed',
      );
      await tester.sendEventToBinding(pointer.up());
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

      final border = borderOf(tester, const Key('opt1'));
      expect(border, isNot(SurfaceTheme.dark.accent));
      expect(border, SurfaceTheme.dark.borderStrong);
    });

    testWidgets(
      'a selected card keeps its accent edge through hover and press',
      (
        tester,
      ) async {
        // The state layer must never outrank selection: hovering the selected
        // card may deepen its fill, but the accent edge is what says "this one
        // is chosen" and a pointer passing over must not take it away.
        await _pump(tester, AppTheme.neon, rowOf(selected: 1));
        expect(borderOf(tester, const Key('opt1')), SurfaceTheme.dark.accent);

        final pointer = TestPointer(3, PointerDeviceKind.mouse);
        final centre = tester.getCenter(find.byKey(const Key('opt1')));
        await tester.sendEventToBinding(pointer.hover(centre));
        await tester.pumpAndSettle();
        expect(borderOf(tester, const Key('opt1')), SurfaceTheme.dark.accent);

        await tester.sendEventToBinding(pointer.down(centre));
        await tester.pumpAndSettle();
        expect(borderOf(tester, const Key('opt1')), SurfaceTheme.dark.accent);

        await tester.sendEventToBinding(pointer.up());
        await tester.pumpAndSettle();
      },
    );
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

    test('the focus tint is the accent, not a Material default', () {
      // Keyboard focus is the only state a pointer never reveals, so it is the
      // easiest to leave on Material's stock purple without anyone noticing.
      expect(
        AppTheme.neon.focusColor,
        SurfaceTheme.dark.accent.withValues(alpha: 0.24),
      );
      expect(
        AppTheme.highContrast.focusColor,
        SurfaceTheme.highContrast.accent.withValues(alpha: 0.24),
      );
    });
  });
}
