import 'package:flutter/material.dart';

/// Multiplies RGB by [brightness] (`0..1`). Identity at `1.0`.
ColorFilter softwareBrightnessFilter(double brightness) {
  final b = brightness.clamp(0.0, 1.0);
  return ColorFilter.matrix(<double>[
    b,
    0,
    0,
    0,
    0,
    0,
    b,
    0,
    0,
    0,
    0,
    0,
    b,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]);
}

/// Applies [softwareBrightnessFilter] when [brightness] is below full.
class SoftwareBrightness extends StatelessWidget {
  /// Creates a [SoftwareBrightness] wrapper.
  const SoftwareBrightness({
    required this.brightness,
    required this.child,
    super.key,
  });

  /// Dim level in `0..1` (`1` = no filter).
  final double brightness;

  /// Subtree to dim.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final b = brightness.clamp(0.0, 1.0);
    if (b >= 1.0) return child;
    return ColorFiltered(
      colorFilter: softwareBrightnessFilter(b),
      child: child,
    );
  }
}
