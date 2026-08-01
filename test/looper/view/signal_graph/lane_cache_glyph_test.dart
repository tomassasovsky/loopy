import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/signal_graph/lane_cache_glyph.dart';
import 'package:loopy/theme/surface_theme.dart';

import '../../../helpers/helpers.dart';

void main() {
  group('LaneCacheGlyph', () {
    testWidgets('renders nothing when the state was never observed', (
      tester,
    ) async {
      await tester.pumpApp(const LaneCacheGlyph(state: null));

      // Telemetry off is not "live" — there is simply nothing to report, so
      // the calm default view carries no glyph at all.
      expect(find.byType(Text), findsNothing);
    });

    for (final (state, glyph, label) in const [
      (LaneCacheState.live, '–', 'Wet cache: live'),
      (LaneCacheState.rendering, '⟳', 'Wet cache: rendering'),
      (LaneCacheState.cached, '●', 'Wet cache: cached'),
      (
        LaneCacheState.failedRetrying,
        '!',
        'Wet cache: render failed, retrying',
      ),
      (LaneCacheState.gaveUp, '✕', 'Wet cache: off, playing live'),
    ]) {
      testWidgets('renders ${state.name} with its own glyph and label', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await tester.pumpApp(LaneCacheGlyph(state: state));

        expect(find.text(glyph), findsOneWidget);
        // A bare glyph means nothing to a screen reader, so the state has to
        // be spelled out — read the node directly rather than matching on the
        // glyph's own text.
        expect(
          tester.getSemantics(find.byType(LaneCacheGlyph)).label,
          label,
        );
        handle.dispose();
      });
    }

    testWidgets('every state gets a distinct glyph', (tester) async {
      final glyphs = <String>{};
      for (final state in LaneCacheState.values) {
        await tester.pumpApp(LaneCacheGlyph(state: state));
        glyphs.add(tester.widget<Text>(find.byType(Text)).data!);
      }
      // Five states that look alike would be worse than no glyph: the whole
      // point is telling "rendering" from "gave up" at a glance.
      expect(glyphs, hasLength(LaneCacheState.values.length));
    });

    testWidgets('colours come from the theme, never a hard-coded constant', (
      tester,
    ) async {
      // Resolve the theme from the element live at each pump — reusing an
      // element captured before a later pumpApp reads a defunct tree.
      SurfaceTheme surfaceNow() => Theme.of(
        tester.element(find.byType(LaneCacheGlyph)),
      ).extension<SurfaceTheme>()!;

      await tester.pumpApp(const LaneCacheGlyph(state: LaneCacheState.cached));
      final cached = tester.widget<Text>(find.byType(Text)).style!.color;
      expect(cached, surfaceNow().accent);

      await tester.pumpApp(const LaneCacheGlyph(state: LaneCacheState.live));
      final live = tester.widget<Text>(find.byType(Text)).style!.color;
      expect(live, surfaceNow().textTertiary);
    });
  });
}
