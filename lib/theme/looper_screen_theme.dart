import 'package:flutter/material.dart';
import 'package:loopy/theme/surface_theme.dart';

/// Applies the VAMP overlay legend face to the main looper screen.
class LooperScreenTheme extends StatelessWidget {
  /// Creates a [LooperScreenTheme].
  const LooperScreenTheme({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const family = SurfaceTheme.legendFont;
    const fallback = SurfaceTheme.legendFontFallback;
    return Theme(
      data: theme.copyWith(
        textTheme: theme.textTheme.apply(
          fontFamily: family,
          fontFamilyFallback: fallback,
        ),
        primaryTextTheme: theme.primaryTextTheme.apply(
          fontFamily: family,
          fontFamilyFallback: fallback,
        ),
      ),
      child: child,
    );
  }
}
