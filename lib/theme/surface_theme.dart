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
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.wetRoute,
    required this.dryRoute,
    required this.lanePalette,
  });

  /// The neutral surface palette.
  final Color background;
  final Color surface;
  final Color card;
  final Color cardHigh;
  final Color line;
  final Color accent;
  final Color onAccent;
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

  @override
  SurfaceTheme copyWith({
    Color? background,
    Color? surface,
    Color? card,
    Color? cardHigh,
    Color? line,
    Color? accent,
    Color? onAccent,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? wetRoute,
    Color? dryRoute,
    List<Color>? lanePalette,
  }) => SurfaceTheme(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    card: card ?? this.card,
    cardHigh: cardHigh ?? this.cardHigh,
    line: line ?? this.line,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    textPrimary: textPrimary ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    textTertiary: textTertiary ?? this.textTertiary,
    wetRoute: wetRoute ?? this.wetRoute,
    dryRoute: dryRoute ?? this.dryRoute,
    lanePalette: lanePalette ?? this.lanePalette,
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
      textPrimary: c(textPrimary, other.textPrimary),
      textSecondary: c(textSecondary, other.textSecondary),
      textTertiary: c(textTertiary, other.textTertiary),
      wetRoute: c(wetRoute, other.wetRoute),
      dryRoute: c(dryRoute, other.dryRoute),
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
  /// Text tokens meet WCAG 2.2 AA contrast (1.4.3) against [card]: `textTertiary`
  /// was lifted from `0xFF5B5D67` (~2.6:1) to `0xFF82848E` (~4.6:1) so dimmed
  /// labels stay legible.
  static const SurfaceTheme dark = SurfaceTheme(
    background: Color(0xFF08080A),
    surface: Color(0xFF0D0D11),
    card: Color(0xFF16161B),
    cardHigh: Color(0xFF1C1C22),
    line: Color(0xFF272730),
    accent: Color(0xFF3B82F6),
    onAccent: Color(0xFFFFFFFF),
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
  );
}

/// Ergonomic access to the [SurfaceTheme] from a [BuildContext].
extension SurfaceThemeX on BuildContext {
  /// The [SurfaceTheme] for this context.
  SurfaceTheme get surface => Theme.of(this).extension<SurfaceTheme>()!;
}
