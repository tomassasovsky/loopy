import 'package:flutter/material.dart';

/// Floor for display brightness (`0..1`).
///
/// Software dim multiplies RGB — `0` is a black screen and the user could not
/// see the Control Center slider to recover. Keep a visible minimum.
const double kMinDisplayBrightness = 0.1;

/// Clamps [brightness] into `[kMinDisplayBrightness, 1.0]`.
double clampDisplayBrightness(double brightness) =>
    brightness.clamp(kMinDisplayBrightness, 1.0);

/// Multiplies RGB by [brightness] (`kMinDisplayBrightness..1`). Identity at
/// `1.0`.
ColorFilter softwareBrightnessFilter(double brightness) {
  final b = clampDisplayBrightness(brightness);
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

  /// Dim level in `kMinDisplayBrightness..1` (`1` = no filter).
  final double brightness;

  /// Subtree to dim.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final b = clampDisplayBrightness(brightness);
    if (b >= 1.0) return child;
    return ColorFiltered(
      colorFilter: softwareBrightnessFilter(b),
      child: child,
    );
  }
}
