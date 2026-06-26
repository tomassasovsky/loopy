import 'dart:io';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:gpio_client/src/gpio_controller_source.dart';

/// Builds the long-lived [GpioControllerSource] for the controller pipeline, or
/// `null` when the host has no GPIO (every desktop, and CI).
///
/// Mirrors `createNativeMidiSource`: off-target detection is **explicit** (a
/// missing `/dev/gpiochip0`) so the function returns a clean `null` on desktop
/// and CI runners instead of constructing the FFI backend and risking a load
/// crash. On a Pi it requests the [ControllerMapping.gpioDefaults] footswitch
/// pins; any failure is reported via [FlutterError.reportError] and downgraded
/// to `null` so the looper still launches.
///
/// [hasGpioChip] and [factory] are injectable for tests.
GpioControllerSource? createNativeGpioSource({
  GpioControllerSource Function()? factory,
  bool Function()? hasGpioChip,
}) {
  final detect = hasGpioChip ?? _defaultHasGpioChip;
  if (!detect()) return null;
  try {
    return (factory ?? _defaultGpioSource)();
  } on Object catch (error, stackTrace) {
    // A missing/unsupported GPIO backend is non-fatal: log and run on.
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'gpio_client',
        context: ErrorDescription('creating the native GPIO source'),
      ),
    );
    return null;
  }
}

/// The BCM pin offsets the default console footswitches occupy, taken from the
/// GPIO entries of [ControllerMapping.gpioDefaults] so the requested lines and
/// the active mapping can never drift apart.
List<int> gpioDefaultLines() => [
  for (final entry in ControllerMapping.gpioDefaults().entries)
    if (entry.trigger.kind == ControllerSourceKind.gpio) entry.trigger.id,
];

// coverage:ignore-start
// On-device only: the real chip probe and FFI-backed source can't run in CI.
bool _defaultHasGpioChip() => File('/dev/gpiochip0').existsSync();

GpioControllerSource _defaultGpioSource() =>
    GpioControllerSource(lines: gpioDefaultLines());
// coverage:ignore-end
