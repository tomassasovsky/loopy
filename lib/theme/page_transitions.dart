import 'package:flutter/material.dart';

/// Fade + subtle scale-up (96% → 100%) transition math shared by
/// [FadeScalePageTransitionsBuilder] (the app-wide theme default) and
/// [desktopPageRoute] (Segno's own asymmetric desktop timing).
Widget buildFadeScaleTransition(Animation<double> animation, Widget child) {
  final curved = CurvedAnimation(parent: animation, curve: Curves.easeInOut);
  return FadeTransition(
    opacity: curved,
    child: ScaleTransition(
      scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
      child: child,
    ),
  );
}

/// A plain fade + subtle scale-up route transition, wired into
/// `AppTheme`'s `pageTransitionsTheme` as the default for every
/// `MaterialPageRoute` push app-wide. Tried Material's "container transform"
/// (`OpenContainer`, from `package:animations`) for the Settings-tray Signal
/// tile first, which morphs the *tapped tile itself* into the destination,
/// but a small unrelated icon visibly stretching into a full page doesn't
/// read as sensible motion the way it does for e.g. a photo thumbnail
/// growing into its detail view. This gives every route the "page opens and
/// fills the screen" feel without that, via plain `Tween`/`CurvedAnimation`
/// — no extra package.
class FadeScalePageTransitionsBuilder extends PageTransitionsBuilder {
  /// Creates a [FadeScalePageTransitionsBuilder].
  const FadeScalePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => buildFadeScaleTransition(animation, child);
}

/// Pushes [builder] with the same fade + scale-up transition as
/// [FadeScalePageTransitionsBuilder], but at Segno's own desktop timing
/// (200ms open / 150ms close) rather than `MaterialPageRoute`'s fixed
/// 300ms — `pageTransitionsTheme` can swap a route's transition *look*
/// app-wide, but it can't touch a route's duration, so matching the
/// desktop-tuned timing exactly needs its own route class.
PageRouteBuilder<T> desktopPageRoute<T>(
  WidgetBuilder builder, {
  RouteSettings? settings,
}) => PageRouteBuilder<T>(
  settings: settings,
  transitionDuration: const Duration(milliseconds: 200),
  reverseTransitionDuration: const Duration(milliseconds: 150),
  pageBuilder: (context, animation, secondaryAnimation) => builder(context),
  transitionsBuilder: (context, animation, secondaryAnimation, child) =>
      buildFadeScaleTransition(animation, child),
);
