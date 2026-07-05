import 'package:flutter/material.dart';

/// The neutral "setup surface" design tokens (onboarding, settings, and the
/// routing graphs) plus the routing-graph role colours, layered onto
/// [ThemeData] via a [ThemeExtension] so widgets resolve them from
/// `Theme.of(context)` instead of reading module-level constants.
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
    required this.accent,
    required this.onAccent,
    required this.warning,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
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
  });

  /// The neutral surface palette.
  final Color background;
  final Color surface;
  final Color card;
  final Color cardHigh;
  final Color line;
  final Color accent;
  final Color onAccent;

  /// The caution colour for non-blocking notices (e.g. "no active outputs"),
  /// brightened in the high-contrast variant so it stays legible (WCAG 1.4.3).
  final Color warning;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

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
  /// hardcoding hues. [ledOff] is an unlit dot; the rest map the pedal's
  /// `PedalTrackLed` / `GlobalColor` semantics; [ringGlow] is the encoder ring's
  /// ambient rim when idle.
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

  /// The display/body typeface — a geometric grotesque that gives the surfaces
  /// their instrument-panel character (bundled under `assets/fonts/`).
  static const String displayFont = 'Space Grotesk';

  /// Bold Helvetica legend face from the VAMP printed overlay — pedal silk
  /// labels and the main looper screen.
  static const String legendFont = 'Helvetica';

  /// Fallbacks when [legendFont] is unavailable on the host.
  static const List<String> legendFontFallback = ['Arial', 'sans-serif'];

  /// The monospace typeface used for numerics, gate/section labels, and any
  /// "machine" readout (channel ids, dB values, FX names).
  static const String monoFont = 'IBM Plex Mono';

  @override
  SurfaceTheme copyWith({
    Color? background,
    Color? surface,
    Color? card,
    Color? cardHigh,
    Color? line,
    Color? accent,
    Color? onAccent,
    Color? warning,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
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
  }) => SurfaceTheme(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    card: card ?? this.card,
    cardHigh: cardHigh ?? this.cardHigh,
    line: line ?? this.line,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    warning: warning ?? this.warning,
    textPrimary: textPrimary ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    textTertiary: textTertiary ?? this.textTertiary,
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
      accent: c(accent, other.accent),
      onAccent: c(onAccent, other.onAccent),
      warning: c(warning, other.warning),
      textPrimary: c(textPrimary, other.textPrimary),
      textSecondary: c(textSecondary, other.textSecondary),
      textTertiary: c(textTertiary, other.textTertiary),
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
  /// Text tokens meet WCAG 2.2 AA contrast (1.4.3) against [card]:
  /// `textTertiary` was lifted from `0xFF5B5D67` (~2.6:1) to `0xFF82848E`
  /// (~4.6:1) so dimmed labels stay legible.
  static const SurfaceTheme dark = SurfaceTheme(
    background: Color(0xFF08080A),
    surface: Color(0xFF0D0D11),
    card: Color(0xFF16161B),
    cardHigh: Color(0xFF1C1C22),
    line: Color(0xFF272730),
    accent: Color(0xFF3B82F6),
    onAccent: Color(0xFFFFFFFF),
    warning: Color(0xFFF0C97A),
    textPrimary: Color(0xFFF3F4F7),
    textSecondary: Color(0xFF989AA4),
    textTertiary: Color(0xFF82848E),
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
    ledOff: Color(0xFF23232B),
    ledGreen: Color(0xFF34D399),
    ledRed: Color(0xFFEF4444),
    ledAmber: Color(0xFFF59E0B),
    ledBlue: Color(0xFF3B82F6),
    ringGlow: Color(0xFF3A3A44),
    chromeGradientTop: Color(0xFF101016),
    chromeGradientBottom: Color(0xFF0C0C10),
    chromeBar: Color(0xFF0B0B0F),
    meterTrack: Color(0xFF0E0E12),
    pageGlow: Color(0xFF11111B),
    knobFaceTop: Color(0xFF23232B),
    knobFaceBottom: Color(0xFF121217),
  );

  /// High-contrast variant of [dark], selected automatically when the OS
  /// reports a high-contrast preference (macOS "Increase Contrast" / Windows
  /// High Contrast, surfaced via `MediaQuery.highContrast`). Text rises toward
  /// pure white, lines clear the 3:1 non-text threshold (1.4.11), and the
  /// route/lane hues brighten so wiring stays distinguishable.
  static const SurfaceTheme highContrast = SurfaceTheme(
    background: Color(0xFF000000),
    surface: Color(0xFF000000),
    card: Color(0xFF0A0A0D),
    cardHigh: Color(0xFF17171D),
    line: Color(0xFF6B6D78),
    accent: Color(0xFF6BA8FF),
    onAccent: Color(0xFF000000),
    warning: Color(0xFFFFD27A),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xFFD6D8E0),
    textTertiary: Color(0xFFB2B4BE),
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
    ledOff: Color(0xFF3A3A44),
    ledGreen: Color(0xFF6EE7B7),
    ledRed: Color(0xFFFF6B6B),
    ledAmber: Color(0xFFFFC04D),
    ledBlue: Color(0xFF6BA8FF),
    ringGlow: Color(0xFF6B6D78),
    chromeGradientTop: Color(0xFF0B0B10),
    chromeGradientBottom: Color(0xFF050508),
    chromeBar: Color(0xFF060609),
    meterTrack: Color(0xFF040406),
    pageGlow: Color(0xFF0B0B18),
    knobFaceTop: Color(0xFF2E2E3A),
    knobFaceBottom: Color(0xFF17171D),
  );
}

/// Ergonomic access to the [SurfaceTheme] from a [BuildContext].
extension SurfaceThemeX on BuildContext {
  /// The [SurfaceTheme] for this context.
  SurfaceTheme get surface => Theme.of(this).extension<SurfaceTheme>()!;
}
