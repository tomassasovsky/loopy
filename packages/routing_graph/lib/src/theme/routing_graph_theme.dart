import 'package:flutter/material.dart';

/// The neutral structural design tokens for a routing graph — backgrounds,
/// card fills, lines, and text shades — layered onto [ThemeData] via a
/// [ThemeExtension] so the package's widgets resolve them from
/// `Theme.of(context)` instead of reading caller constants.
///
/// Only **neutral** colours live here; caller-specific semantic colours (a
/// lane hue, a wet/dry send role, an accent) stay constructor parameters on the
/// individual widgets. The host app registers a [RoutingGraphTheme] on its
/// [ThemeData] and maps these tokens from its own palette.
///
/// Read it ergonomically with the [RoutingGraphThemeX.routingGraph] extension:
/// `context.routingGraph.card`, `context.routingGraph.textPrimary`, etc.
@immutable
class RoutingGraphTheme extends ThemeExtension<RoutingGraphTheme> {
  /// Creates a [RoutingGraphTheme].
  const RoutingGraphTheme({
    required this.background,
    required this.surface,
    required this.card,
    required this.cardHigh,
    required this.line,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
  });

  /// The graph's outermost backdrop.
  final Color background;

  /// The canvas fill behind the positioned graph content.
  final Color surface;

  /// The resting fill for a node/port chip.
  final Color card;

  /// The raised fill for an effect card (and its drag ghost).
  final Color cardHigh;

  /// Hairline borders and dividers.
  final Color line;

  /// Primary (high-emphasis) text.
  final Color textPrimary;

  /// Secondary (medium-emphasis) text and icons.
  final Color textSecondary;

  /// Tertiary (low-emphasis) text, disabled labels, and drag handles.
  final Color textTertiary;

  @override
  RoutingGraphTheme copyWith({
    Color? background,
    Color? surface,
    Color? card,
    Color? cardHigh,
    Color? line,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
  }) => RoutingGraphTheme(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    card: card ?? this.card,
    cardHigh: cardHigh ?? this.cardHigh,
    line: line ?? this.line,
    textPrimary: textPrimary ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    textTertiary: textTertiary ?? this.textTertiary,
  );

  @override
  RoutingGraphTheme lerp(ThemeExtension<RoutingGraphTheme>? other, double t) {
    if (other is! RoutingGraphTheme) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return RoutingGraphTheme(
      background: c(background, other.background),
      surface: c(surface, other.surface),
      card: c(card, other.card),
      cardHigh: c(cardHigh, other.cardHigh),
      line: c(line, other.line),
      textPrimary: c(textPrimary, other.textPrimary),
      textSecondary: c(textSecondary, other.textSecondary),
      textTertiary: c(textTertiary, other.textTertiary),
    );
  }
}

/// Ergonomic access to the [RoutingGraphTheme] from a [BuildContext].
extension RoutingGraphThemeX on BuildContext {
  /// The [RoutingGraphTheme] registered on the ambient [ThemeData].
  RoutingGraphTheme get routingGraph =>
      Theme.of(this).extension<RoutingGraphTheme>()!;
}
