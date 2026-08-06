import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// The neutral "setup surface" design tokens (onboarding, settings, and the
/// routing graphs) plus the routing-graph role colours, layered onto
/// [ThemeData] via a [ThemeExtension] so widgets resolve them from
/// `Theme.of(context)` instead of reading module-level constants.
///
/// Values are sourced from the Segno design system (issue #499): the design
/// file's token set is authoritative and this class mirrors it.
///
/// Read it ergonomically with the [SurfaceThemeX.surface] extension:
/// `context.surface.card`, `context.surface.wetRoute`, etc.
@immutable
class SurfaceTheme extends ThemeExtension<SurfaceTheme> {
  /// Creates a [SurfaceTheme].
  const SurfaceTheme({
    required this.background,
    required this.surface,
    required this.card,
    required this.cardHigh,
    required this.line,
    required this.control,
    required this.controlStrong,
    required this.scrim,
    required this.dropShadow,
    required this.borderHairline,
    required this.borderSubtle,
    required this.borderStrong,
    required this.accent,
    required this.onAccent,
    required this.accentSurface,
    required this.accentAlt,
    required this.warning,
    required this.success,
    required this.rec,
    required this.recSurface,
    required this.recTint,
    required this.recLine,
    required this.recDeep,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.textMuted,
    required this.wetRoute,
    required this.dryRoute,
    required this.lanePalette,
    required this.ledOff,
    required this.ledGreen,
    required this.ledRed,
    required this.ledAmber,
    required this.ledBlue,
    required this.ringGlow,
    required this.chromeGradientTop,
    required this.chromeGradientBottom,
    required this.chromeBar,
    required this.meterTrack,
    required this.pageGlow,
    required this.knobFaceTop,
    required this.knobFaceBottom,
    required this.disabledOpacity,
    required this.traceDimOpacity,
  });

  /// The neutral surface palette (DS `bg-base`, `bg-surface`, `bg-raised`,
  /// `bg-elevated`, `border-default`).
  final Color background;
  final Color surface;
  final Color card;
  final Color cardHigh;
  final Color line;

  /// Control-surface fills (DS `bg-control`, `bg-control-strong`): the
  /// resting fill of an interactive chip/segment, and its strong sibling for
  /// emphasised or active control surfaces.
  final Color control;
  final Color controlStrong;

  /// Overlay scrim behind dialogs and trays (DS `bg-scrim`).
  final Color scrim;

  /// The drop shadow a floating surface casts on the stage — the tray sheet
  /// and the console's dialogs (mockups: `#00000099`, offset y+19, blur 48).
  final Color dropShadow;

  /// The white-alpha border tiers below [line] (DS `border-hairline`,
  /// `border-subtle`): hairline is the resting card edge, subtle is the
  /// hover-tier lift; both are also the interaction-state overlay fills.
  final Color borderHairline;
  final Color borderSubtle;

  /// The strong border tier above [line] (DS `border-strong`).
  final Color borderStrong;

  final Color accent;
  final Color onAccent;

  /// Accent-family surfaces (DS `accent-surface`, `accent-alt`): the tinted
  /// fill behind selected/accented content, and the lighter accent used for
  /// secondary accents on dark fills.
  final Color accentSurface;
  final Color accentAlt;

  /// The caution colour for non-blocking notices (e.g. "no active outputs"),
  /// brightened in the high-contrast variant so it stays legible (WCAG 1.4.3).
  final Color warning;

  /// Positive/confirmation colour (DS `success`).
  final Color success;

  /// The UI-chrome record red family (DS `rec`, `rec-surface`, `rec-tint`,
  /// `rec-line`, `rec-deep`): REC pills, armed banners, and armed-row tints.
  /// Distinct from the stage record hue (`LooperTheme.recordColor`,
  /// DS `signal-rec`) by design — chrome red is softer than stage red.
  final Color rec;
  final Color recSurface;
  final Color recTint;
  final Color recLine;
  final Color recDeep;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  /// The dimmest text tier (DS `text-muted`, ~3.4:1 on [card]): large text
  /// and non-essential ornament only — never body copy (WCAG 1.4.3 applies
  /// to the three tiers above).
  final Color textMuted;

  /// Routing-graph send-role colours: wet (effected) and dry (clean).
  final Color wetRoute;
  final Color dryRoute;

  /// Eight distinct hues, one per lane (cycled), so a lane's node, cards, and
  /// wires share one traceable colour.
  final List<Color> lanePalette;

  /// The palette hue for [lane] (cycled past the palette length).
  Color laneColor(int lane) => lanePalette[lane % lanePalette.length];

  /// Pedal LED palette — the on-screen pedal faceplate renders the firmware's
  /// LED colors from these so they honor the high-contrast variant instead of
  /// hardcoding hues. [ledGreen]/[ledRed]/[ledAmber]/[ledBlue] map the pedal's
  /// `PedalTrackLed` / `GlobalColor` semantics and are not restylable;
  /// [ledOff] (an unlit dot) and [ringGlow] (the encoder ring's ambient rim
  /// when idle) are panel neutrals that follow the ramp's hue.
  final Color ledOff;
  final Color ledGreen;
  final Color ledRed;
  final Color ledAmber;
  final Color ledBlue;
  final Color ringGlow;

  /// Signal-surface recessed/gradient fills — the deep "instrument panel"
  /// backdrops that sit below the cards. Sourced from tokens (rather than raw
  /// literals) so the whole Signal surface deepens under the high-contrast
  /// variant instead of staying fixed while the rest of the palette shifts.
  ///
  /// [chromeGradientTop]/[chromeGradientBottom] paint the top chrome bar's
  /// vertical gradient; [chromeBar] is the flat hint-strip / legend fill;
  /// [meterTrack] is the recessed input level-meter groove; [pageGlow] is the
  /// inner stop of the page's radial backdrop; [knobFaceTop]/[knobFaceBottom]
  /// are the rotary knob's radial-gradient cap.
  final Color chromeGradientTop;
  final Color chromeGradientBottom;
  final Color chromeBar;
  final Color meterTrack;
  final Color pageGlow;
  final Color knobFaceTop;
  final Color knobFaceBottom;

  /// The opacity a **disabled** control renders at (R26): a bypassed FX card's
  /// body, a disabled effect's summary chip, a chain-disabled summary row. The
  /// single source for disabled dimming, so no widget hardcodes an opacity —
  /// and so the high-contrast variant can dim less aggressively and keep the
  /// dimmed text legible (WCAG 1.4.3).
  final double disabledOpacity;

  /// The opacity a row renders at when a tap-to-trace is active and the row is
  /// not lit. Separate from [disabledOpacity] and deliberately deeper: this
  /// wraps whole rows whose contents may ALREADY carry the disabled dim, and
  /// the two multiply — so the pair is chosen to keep a dimmed control inside
  /// an untraced row legible rather than to be reused for disabled state.
  final double traceDimOpacity;

  /// The UI typeface (DS `font-ui`, bundled under `assets/fonts/`).
  static const String displayFont = 'Inter';

  /// Bold Helvetica legend face from the Segno printed overlay — pedal silk
  /// labels and the main looper screen.
  static const String legendFont = 'Helvetica';

  /// Fallbacks when [legendFont] is unavailable on the host.
  static const List<String> legendFontFallback = ['Arial', 'sans-serif'];

  /// The monospace typeface used for numerics, gate/section labels, and any
  /// "machine" readout (channel ids, dB values, FX names) — DS `font-mono`,
  /// bundled under `assets/fonts/`.
  static const String monoFont = 'JetBrains Mono';

  @override
  SurfaceTheme copyWith({
    Color? background,
    Color? surface,
    Color? card,
    Color? cardHigh,
    Color? line,
    Color? control,
    Color? controlStrong,
    Color? scrim,
    Color? dropShadow,
    Color? borderHairline,
    Color? borderSubtle,
    Color? borderStrong,
    Color? accent,
    Color? onAccent,
    Color? accentSurface,
    Color? accentAlt,
    Color? warning,
    Color? success,
    Color? rec,
    Color? recSurface,
    Color? recTint,
    Color? recLine,
    Color? recDeep,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? textMuted,
    Color? wetRoute,
    Color? dryRoute,
    List<Color>? lanePalette,
    Color? ledOff,
    Color? ledGreen,
    Color? ledRed,
    Color? ledAmber,
    Color? ledBlue,
    Color? ringGlow,
    Color? chromeGradientTop,
    Color? chromeGradientBottom,
    Color? chromeBar,
    Color? meterTrack,
    Color? pageGlow,
    Color? knobFaceTop,
    Color? knobFaceBottom,
    double? disabledOpacity,
    double? traceDimOpacity,
  }) => SurfaceTheme(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    card: card ?? this.card,
    cardHigh: cardHigh ?? this.cardHigh,
    line: line ?? this.line,
    control: control ?? this.control,
    controlStrong: controlStrong ?? this.controlStrong,
    scrim: scrim ?? this.scrim,
    dropShadow: dropShadow ?? this.dropShadow,
    borderHairline: borderHairline ?? this.borderHairline,
    borderSubtle: borderSubtle ?? this.borderSubtle,
    borderStrong: borderStrong ?? this.borderStrong,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    accentSurface: accentSurface ?? this.accentSurface,
    accentAlt: accentAlt ?? this.accentAlt,
    warning: warning ?? this.warning,
    success: success ?? this.success,
    rec: rec ?? this.rec,
    recSurface: recSurface ?? this.recSurface,
    recTint: recTint ?? this.recTint,
    recLine: recLine ?? this.recLine,
    recDeep: recDeep ?? this.recDeep,
    textPrimary: textPrimary ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    textTertiary: textTertiary ?? this.textTertiary,
    textMuted: textMuted ?? this.textMuted,
    wetRoute: wetRoute ?? this.wetRoute,
    dryRoute: dryRoute ?? this.dryRoute,
    lanePalette: lanePalette ?? this.lanePalette,
    ledOff: ledOff ?? this.ledOff,
    ledGreen: ledGreen ?? this.ledGreen,
    ledRed: ledRed ?? this.ledRed,
    ledAmber: ledAmber ?? this.ledAmber,
    ledBlue: ledBlue ?? this.ledBlue,
    ringGlow: ringGlow ?? this.ringGlow,
    chromeGradientTop: chromeGradientTop ?? this.chromeGradientTop,
    chromeGradientBottom: chromeGradientBottom ?? this.chromeGradientBottom,
    chromeBar: chromeBar ?? this.chromeBar,
    meterTrack: meterTrack ?? this.meterTrack,
    pageGlow: pageGlow ?? this.pageGlow,
    knobFaceTop: knobFaceTop ?? this.knobFaceTop,
    knobFaceBottom: knobFaceBottom ?? this.knobFaceBottom,
    disabledOpacity: disabledOpacity ?? this.disabledOpacity,
    traceDimOpacity: traceDimOpacity ?? this.traceDimOpacity,
  );

  @override
  SurfaceTheme lerp(ThemeExtension<SurfaceTheme>? other, double t) {
    if (other is! SurfaceTheme) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return SurfaceTheme(
      background: c(background, other.background),
      surface: c(surface, other.surface),
      card: c(card, other.card),
      cardHigh: c(cardHigh, other.cardHigh),
      line: c(line, other.line),
      control: c(control, other.control),
      controlStrong: c(controlStrong, other.controlStrong),
      scrim: c(scrim, other.scrim),
      dropShadow: c(dropShadow, other.dropShadow),
      borderHairline: c(borderHairline, other.borderHairline),
      borderSubtle: c(borderSubtle, other.borderSubtle),
      borderStrong: c(borderStrong, other.borderStrong),
      accent: c(accent, other.accent),
      onAccent: c(onAccent, other.onAccent),
      accentSurface: c(accentSurface, other.accentSurface),
      accentAlt: c(accentAlt, other.accentAlt),
      warning: c(warning, other.warning),
      success: c(success, other.success),
      rec: c(rec, other.rec),
      recSurface: c(recSurface, other.recSurface),
      recTint: c(recTint, other.recTint),
      recLine: c(recLine, other.recLine),
      recDeep: c(recDeep, other.recDeep),
      textPrimary: c(textPrimary, other.textPrimary),
      textSecondary: c(textSecondary, other.textSecondary),
      textTertiary: c(textTertiary, other.textTertiary),
      textMuted: c(textMuted, other.textMuted),
      wetRoute: c(wetRoute, other.wetRoute),
      dryRoute: c(dryRoute, other.dryRoute),
      ledOff: c(ledOff, other.ledOff),
      ledGreen: c(ledGreen, other.ledGreen),
      ledRed: c(ledRed, other.ledRed),
      ledAmber: c(ledAmber, other.ledAmber),
      ledBlue: c(ledBlue, other.ledBlue),
      ringGlow: c(ringGlow, other.ringGlow),
      chromeGradientTop: c(chromeGradientTop, other.chromeGradientTop),
      chromeGradientBottom: c(
        chromeGradientBottom,
        other.chromeGradientBottom,
      ),
      chromeBar: c(chromeBar, other.chromeBar),
      meterTrack: c(meterTrack, other.meterTrack),
      pageGlow: c(pageGlow, other.pageGlow),
      knobFaceTop: c(knobFaceTop, other.knobFaceTop),
      knobFaceBottom: c(knobFaceBottom, other.knobFaceBottom),
      disabledOpacity:
          lerpDouble(disabledOpacity, other.disabledOpacity, t) ??
          disabledOpacity,
      traceDimOpacity:
          lerpDouble(traceDimOpacity, other.traceDimOpacity, t) ??
          traceDimOpacity,
      lanePalette: [
        for (var i = 0; i < lanePalette.length; i++)
          c(
            lanePalette[i],
            i < other.lanePalette.length
                ? other.lanePalette[i]
                : lanePalette[i],
          ),
      ],
    );
  }

  /// The shared dark "setup surface" tokens used by onboarding, settings, and
  /// the routing graphs. The same values in every [ThemeData] variant — these
  /// surfaces read identically regardless of the active app theme.
  ///
  /// The neutral ramp is the DS's neutral grey (the pre-#499 ramp was
  /// blue-tinted). Text tokens meet WCAG 2.2 AA contrast (1.4.3) against
  /// [card]: `textSecondary` ~6.5:1, `textTertiary` ~5.3:1; [textMuted] is
  /// below the body-copy floor by design (see its doc).
  static const SurfaceTheme dark = SurfaceTheme(
    background: Color(0xFF0B0B0C),
    surface: Color(0xFF141417),
    card: Color(0xFF161618),
    cardHigh: Color(0xFF1E1E21),
    line: Color(0xFF2A2A2E),
    control: Color(0xFF26262A),
    controlStrong: Color(0xFF3A3A40),
    scrim: Color(0x6B08080A),
    dropShadow: Color(0x99000000),
    borderHairline: Color(0x0BFFFFFF),
    borderSubtle: Color(0x1FFFFFFF),
    borderStrong: Color(0xFF3A3A40),
    accent: Color(0xFF3B82F6),
    onAccent: Color(0xFFFFFFFF),
    accentSurface: Color(0xFF16233D),
    accentAlt: Color(0xFF738CF2),
    warning: Color(0xFFE0A94A),
    success: Color(0xFF30A46C),
    rec: Color(0xFFE5484D),
    recSurface: Color(0x24E5484D),
    recTint: Color(0x21E5484D),
    recLine: Color(0x66E5484D),
    recDeep: Color(0xFF2A1214),
    textPrimary: Color(0xFFF3F4F7),
    textSecondary: Color(0xFF9A9AA2),
    textTertiary: Color(0xFF8A8A92),
    textMuted: Color(0xFF6B6B73),
    wetRoute: Color(0xFF3B82F6),
    dryRoute: Color(0xFFF59E0B),
    lanePalette: [
      Color(0xFF3B82F6), // blue
      Color(0xFFF59E0B), // amber
      Color(0xFF2DD4BF), // teal
      Color(0xFFA78BFA), // violet
      Color(0xFFF472B6), // pink
      Color(0xFF34D399), // green
      Color(0xFFFB923C), // orange
      Color(0xFF38BDF8), // sky
    ],
    ledOff: Color(0xFF232325),
    ledGreen: Color(0xFF34D399),
    ledRed: Color(0xFFEF4444),
    ledAmber: Color(0xFFF59E0B),
    ledBlue: Color(0xFF3B82F6),
    ringGlow: Color(0xFF3A3A3D),
    chromeGradientTop: Color(0xFF111113),
    chromeGradientBottom: Color(0xFF0C0C0D),
    chromeBar: Color(0xFF0B0B0C),
    meterTrack: Color(0xFF0E0E0F),
    pageGlow: Color(0xFF121214),
    knobFaceTop: Color(0xFF232325),
    knobFaceBottom: Color(0xFF121214),
    disabledOpacity: 0.4,
    traceDimOpacity: 0.28,
  );

  /// High-contrast variant of [dark], selected automatically when the OS
  /// reports a high-contrast preference (macOS "Increase Contrast" / Windows
  /// High Contrast, surfaced via `MediaQuery.highContrast`). Text rises toward
  /// pure white, lines clear the 3:1 non-text threshold (1.4.11), and the
  /// route/lane hues brighten so wiring stays distinguishable.
  ///
  /// Re-derived from the pre-#499 HC palette by the rule "preserve lightness,
  /// drop the blue tint" so it matches the DS's neutral ramp; the measured
  /// contrast floors are asserted relationally in `test/theme/`.
  static const SurfaceTheme highContrast = SurfaceTheme(
    background: Color(0xFF000000),
    surface: Color(0xFF000000),
    card: Color(0xFF0A0A0B),
    cardHigh: Color(0xFF171719),
    line: Color(0xFF6E6E6E),
    control: Color(0xFF2E2E30),
    controlStrong: Color(0xFF4A4A4C),
    scrim: Color(0xA0000000),
    // Opaque black: the sheet's edge must read against a pure-black stage.
    dropShadow: Color(0xCC000000),
    borderHairline: Color(0x1FFFFFFF),
    borderSubtle: Color(0x3DFFFFFF),
    borderStrong: Color(0xFF8A8A8A),
    accent: Color(0xFF6BA8FF),
    onAccent: Color(0xFF000000),
    accentSurface: Color(0xFF234069),
    accentAlt: Color(0xFF9AB4FF),
    warning: Color(0xFFFFD27A),
    success: Color(0xFF6EE7B7),
    rec: Color(0xFFFF6B6B),
    recSurface: Color(0x33FF6B6B),
    recTint: Color(0x2EFF6B6B),
    recLine: Color(0x99FF6B6B),
    recDeep: Color(0xFF361619),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xFFD8D8D8),
    textTertiary: Color(0xFFB4B4B4),
    textMuted: Color(0xFF9A9A9A),
    wetRoute: Color(0xFF6BA8FF),
    dryRoute: Color(0xFFFFC04D),
    lanePalette: [
      Color(0xFF6BA8FF), // blue
      Color(0xFFFFC04D), // amber
      Color(0xFF5EEAD4), // teal
      Color(0xFFC4B5FD), // violet
      Color(0xFFF9A8D4), // pink
      Color(0xFF6EE7B7), // green
      Color(0xFFFDBA74), // orange
      Color(0xFF7DD3FC), // sky
    ],
    ledOff: Color(0xFF3A3A3C),
    ledGreen: Color(0xFF6EE7B7),
    ledRed: Color(0xFFFF6B6B),
    ledAmber: Color(0xFFFFC04D),
    ledBlue: Color(0xFF6BA8FF),
    ringGlow: Color(0xFF6E6E6E),
    chromeGradientTop: Color(0xFF0B0B0C),
    chromeGradientBottom: Color(0xFF050506),
    chromeBar: Color(0xFF060607),
    meterTrack: Color(0xFF040405),
    pageGlow: Color(0xFF0B0B0C),
    knobFaceTop: Color(0xFF2E2E30),
    knobFaceBottom: Color(0xFF171719),
    // Dim less than [dark]: a disabled control must still clear the contrast
    // floor under the high-contrast preference.
    disabledOpacity: 0.62,
    // Lifted alongside [disabledOpacity]: an untraced row holding a disabled
    // control multiplies the two, and high contrast must stay readable.
    traceDimOpacity: 0.5,
  );
}

/// Ergonomic access to the [SurfaceTheme] from a [BuildContext].
extension SurfaceThemeX on BuildContext {
  /// The [SurfaceTheme] for this context.
  SurfaceTheme get surface => Theme.of(this).extension<SurfaceTheme>()!;
}
