import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:led_client/src/led_repository.dart';
import 'package:led_client/src/uart_led_transport.dart';

/// Builds the [LedRepository] backed by the real UART driver link on a
/// Raspberry Pi, or `null` on every other host (desktop, CI).
///
/// Mirrors `createNativeGpioSource` / `createNativeMidiSource`: off-target
/// detection is **explicit** (a missing serial device) so it returns a clean
/// `null` instead of opening a serial fd that isn't there. Any failure is
/// reported via [FlutterError.reportError] and downgraded to `null`, so the app
/// falls back to a no-op LED channel and still launches.
///
/// [hasSerialDevice] and [factory] are injectable for tests.
LedRepository? createNativeLedChannel({
  LedRepository Function()? factory,
  bool Function()? hasSerialDevice,
}) {
  final detect = hasSerialDevice ?? _defaultHasSerialDevice;
  if (!detect()) return null;
  try {
    return (factory ?? _defaultLedRepository)();
  } on Object catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'led_client',
        context: ErrorDescription('creating the native LED channel'),
      ),
    );
    return null;
  }
}

// coverage:ignore-start
// On-device only: the real serial probe and UART-backed repository can't run in
// CI.
bool _defaultHasSerialDevice() => File('/dev/serial0').existsSync();

LedRepository _defaultLedRepository() => LedRepository(UartLedTransport());
// coverage:ignore-end
