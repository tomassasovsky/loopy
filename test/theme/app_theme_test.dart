import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/theme/app_theme.dart';
import 'package:segno/theme/looper_theme.dart';
import 'package:segno/theme/surface_theme.dart';

void main() {
  group('AppTheme', () {
    /// WCAG relative contrast of [fg] against the [bg] it sits on.
    double ratio(Color fg, Color bg) {
      final a = fg.computeLuminance();
      final b = bg.computeLuminance();
      final hi = math.max(a, b);
      final lo = math.min(a, b);
      return (hi + 0.05) / (lo + 0.05);
    }

    void expectRoutingGraphMatchesSurface(
      RoutingGraphTheme? rg,
      SurfaceTheme surface,
    ) {
      expect(rg, isNotNull, reason: 'RoutingGraphTheme must be registered');
      // Anti-drift: every neutral routing-graph token is mapped straight from
      // the app's SurfaceTheme, so the two can never diverge silently.
      expect(rg!.background, surface.background);
      expect(rg.surface, surface.surface);
      expect(rg.card, surface.card);
      expect(rg.cardHigh, surface.cardHigh);
      expect(rg.line, surface.line);
      expect(rg.textPrimary, surface.textPrimary);
      expect(rg.textSecondary, surface.textSecondary);
      expect(rg.textTertiary, surface.textTertiary);
    }

    test(
      'tracks registers RoutingGraphTheme mapped from SurfaceTheme.dark',
      () {
        expectRoutingGraphMatchesSurface(
          AppTheme.neon.extension<RoutingGraphTheme>(),
          SurfaceTheme.dark,
        );
      },
    );

    test(
      'highContrast maps tokens from SurfaceTheme.highContrast',
      () {
        final theme = AppTheme.highContrast;
        expect(
          theme.extension<SurfaceTheme>(),
          same(SurfaceTheme.highContrast),
        );
        expectRoutingGraphMatchesSurface(
          theme.extension<RoutingGraphTheme>(),
          SurfaceTheme.highContrast,
        );
      },
    );

    // WCAG 1.4.3 / 1.4.11: the high-contrast palette must be strictly brighter
    // than the default so the OS "increase contrast" preference helps.
    test('high-contrast text/line tokens out-contrast the default theme', () {
      const dark = SurfaceTheme.dark;
      const hc = SurfaceTheme.highContrast;
      // Dimmed-label text clears AA (>= 4.5:1) on the default card already...
      expect(ratio(dark.textTertiary, dark.card), greaterThanOrEqualTo(4.5));
      // ...and high contrast lifts it further.
      expect(
        ratio(hc.textTertiary, hc.card),
        greaterThan(ratio(dark.textTertiary, dark.card)),
      );
      // Non-text line/border clears the 3:1 component threshold in HC.
      expect(ratio(hc.line, hc.card), greaterThanOrEqualTo(3));
      // Secondary text clears AA in both variants.
      expect(ratio(dark.textSecondary, dark.card), greaterThanOrEqualTo(4.5));
      expect(ratio(hc.textSecondary, hc.card), greaterThanOrEqualTo(4.5));
      // The caution colour stays legible as text in both variants (1.4.3).
      expect(ratio(dark.warning, dark.card), greaterThanOrEqualTo(4.5));
      expect(ratio(hc.warning, hc.card), greaterThanOrEqualTo(4.5));
    });

    test('HC meter/indicator idle tones clear 3:1 on the track tile', () {
      final looper = AppTheme.highContrast.extension<LooperTheme>()!;
      // WCAG 1.4.11: the empty-meter groove and the idle indicator are the
      // dimmest non-text components on the tile; both must clear 3:1 in HC.
      expect(
        ratio(
          looper.meterColor(
            LooperMeterState.empty,
            mode: InteractionMode.record,
          ),
          looper.tileBackground,
        ),
        greaterThanOrEqualTo(3),
      );
      expect(
        ratio(
          looper.indicatorColor(TrackIndicator.idle),
          looper.tileBackground,
        ),
        greaterThanOrEqualTo(3),
      );
    });

    // #499 stage 3b. The waveform stopped/muted tones carry alpha, so their
    // legibility is a property of what they sit on: composite before measuring
    // or the numbers are fiction.
    Color onWaveformBackground(LooperTheme looper, LooperMeterState state) =>
        Color.alphaBlend(
          looper.waveformColor(state),
          looper.waveformBackground,
        );

    test('every waveform state clears 3:1 on its background', () {
      // WCAG 1.4.11: the waveform is a non-text component, so every state it
      // can be drawn in has to clear the 3:1 non-text threshold against its
      // own background — including the alpha-dimmed "not sounding" set.
      //
      // No state is exempt, and `empty` least of all: this surface paints the
      // mixed output, so it has a full waveform to show even when the cursor
      // track is empty. A dim empty here blacks out the mix.
      for (final data in [AppTheme.neon, AppTheme.highContrast]) {
        final looper = data.extension<LooperTheme>()!;
        for (final state in LooperMeterState.values) {
          expect(
            ratio(
              onWaveformBackground(looper, state),
              looper.waveformBackground,
            ),
            greaterThanOrEqualTo(3),
            reason: 'waveform state $state is illegible on its background',
          );
        }
      }
    });

    test('a silenced track reads visibly quieter than a merely idle one', () {
      // muted and stopped/empty are separated by brightness alone — no hue does
      // the work — so the step has to be a visible one. Exact inequality would
      // not do: two dimmed whites can differ numerically and still render as
      // the same grey. 1.5:1 is comfortably inside what reads as a step.
      for (final data in [AppTheme.neon, AppTheme.highContrast]) {
        final looper = data.extension<LooperTheme>()!;
        final muted = onWaveformBackground(looper, LooperMeterState.muted);
        final stopped = onWaveformBackground(looper, LooperMeterState.stopped);
        expect(
          muted.computeLuminance(),
          lessThan(stopped.computeLuminance()),
          reason: 'a muted track must not read louder than a stopped one',
        );
        expect(
          ratio(stopped, muted),
          greaterThanOrEqualTo(1.5),
          reason: 'muted and stopped render as the same grey',
        );
      }
    });

    test('high contrast lifts every waveform state above the default', () {
      // The HC set encodes a legibility decision, not a hue preference: a
      // state that only passes in the default variant is not done.
      final dark = AppTheme.neon.extension<LooperTheme>()!;
      final hc = AppTheme.highContrast.extension<LooperTheme>()!;
      for (final state in LooperMeterState.values) {
        expect(
          ratio(onWaveformBackground(hc, state), hc.waveformBackground),
          greaterThan(
            ratio(onWaveformBackground(dark, state), dark.waveformBackground),
          ),
          reason: 'high contrast must out-contrast the default for $state',
        );
      }
    });

    test('the disabled dim is a token, and high contrast dims less', () {
      // R26: disabled rendering resolves from the theme, never from an ad-hoc
      // opacity constant in a widget — and it must stay legible under the
      // high-contrast preference, so that variant dims less.
      expect(SurfaceTheme.dark.disabledOpacity, greaterThan(0));
      expect(SurfaceTheme.dark.disabledOpacity, lessThan(1));
      expect(
        SurfaceTheme.highContrast.disabledOpacity,
        greaterThan(SurfaceTheme.dark.disabledOpacity),
      );
    });

    test('the disabled dim survives copyWith and lerps between variants', () {
      expect(
        SurfaceTheme.dark.copyWith(disabledOpacity: 0.5).disabledOpacity,
        0.5,
      );
      expect(
        SurfaceTheme.dark.copyWith().disabledOpacity,
        SurfaceTheme.dark.disabledOpacity,
      );
      final mid = SurfaceTheme.dark.lerp(SurfaceTheme.highContrast, 0.5);
      expect(
        mid.disabledOpacity,
        closeTo(
          (SurfaceTheme.dark.disabledOpacity +
                  SurfaceTheme.highContrast.disabledOpacity) /
              2,
          1e-9,
        ),
      );
    });

    test('highContrast registers a LooperTheme', () {
      expect(
        AppTheme.highContrast.extension<LooperTheme>(),
        isNotNull,
      );
    });

    // The ColorScheme carries hand-written copies of SurfaceTheme tokens
    // (Material widgets resolve from the scheme, not the extension). Pin them
    // so a palette change that misses a mirror fails here instead of drifting
    // silently — three of these had to be hand-synced in the #499 migration.
    test('the ColorScheme mirrors of SurfaceTheme tokens stay in sync', () {
      expect(AppTheme.neon.colorScheme.primary, SurfaceTheme.dark.textPrimary);
      expect(AppTheme.neon.colorScheme.secondary, SurfaceTheme.dark.accent);
      expect(AppTheme.neon.colorScheme.surface, SurfaceTheme.dark.surface);
      expect(
        AppTheme.highContrast.colorScheme.primary,
        SurfaceTheme.highContrast.textPrimary,
      );
      expect(
        AppTheme.highContrast.colorScheme.secondary,
        SurfaceTheme.highContrast.accent,
      );
      expect(
        AppTheme.highContrast.colorScheme.surface,
        SurfaceTheme.highContrast.surface,
      );
    });

    // SurfaceTheme carries 40+ colour fields; `lerp` and `copyWith` list every
    // one by hand, so a field that is dropped (or crossed with its neighbour)
    // is invisible to the per-token tests above. Lerping to the endpoints
    // catches both without naming a single field.
    test('lerp reaches both endpoints for every colour field', () {
      const dark = SurfaceTheme.dark;
      const hc = SurfaceTheme.highContrast;
      expect(_colors(dark.lerp(hc, 0)), _colors(dark));
      expect(_colors(dark.lerp(hc, 1)), _colors(hc));
      // A no-op copyWith must likewise preserve every field.
      expect(_colors(dark.copyWith()), _colors(dark));
    });
  });
}

/// Every colour field of [s], in declaration order.
///
/// `lerp`/`copyWith` list all 40+ fields by hand, so a dropped or crossed
/// field is invisible to per-token assertions. Comparing this projection at
/// the lerp endpoints catches both — keep it in sync when a token is added.
List<Color> _colors(SurfaceTheme s) => [
  s.background,
  s.surface,
  s.card,
  s.cardHigh,
  s.line,
  s.control,
  s.controlStrong,
  s.scrim,
  s.borderHairline,
  s.borderSubtle,
  s.borderStrong,
  s.accent,
  s.onAccent,
  s.accentSurface,
  s.accentAlt,
  s.warning,
  s.success,
  s.rec,
  s.recSurface,
  s.recTint,
  s.recLine,
  s.recDeep,
  s.textPrimary,
  s.textSecondary,
  s.textTertiary,
  s.textMuted,
  s.wetRoute,
  s.dryRoute,
  ...s.lanePalette,
  s.ledOff,
  s.ledGreen,
  s.ledRed,
  s.ledAmber,
  s.ledBlue,
  s.ringGlow,
  s.chromeGradientTop,
  s.chromeGradientBottom,
  s.chromeBar,
  s.meterTrack,
  s.pageGlow,
  s.knobFaceTop,
  s.knobFaceBottom,
];
