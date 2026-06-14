import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:loopy_engine/src/generated/loopy_engine_bindings.dart';
import 'package:meta/meta.dart';

/// Classification of a cable-free loopback path used to auto-measure latency.
///
/// Mirrors the native `le_loopback_kind` enum. All kinds capture the
/// **digital** round-trip (output → OS mixer → capture) and therefore
/// under-report the true analog round-trip, which additionally includes
/// converter latency.
enum LoopbackKind {
  /// No loopback path detected.
  none,

  /// The device backend's built-in output loopback (detected, not auto-routed).
  backendLoopback,

  /// PulseAudio "Monitor of …" source (Linux).
  monitor,

  /// A named virtual audio driver (BlackHole, VB-Cable, …).
  virtualDevice;

  /// Maps a native `le_loopback_kind` integer to a [LoopbackKind].
  static LoopbackKind fromCode(int code) => switch (code) {
    0 => LoopbackKind.none,
    1 => LoopbackKind.backendLoopback,
    2 => LoopbackKind.monitor,
    3 => LoopbackKind.virtualDevice,
    _ => LoopbackKind.none,
  };
}

/// The result of loopback detection.
@immutable
class LoopbackInfo {
  /// Creates a [LoopbackInfo].
  const LoopbackInfo({
    required this.available,
    required this.kind,
    required this.deviceName,
  });

  /// A result indicating no loopback path is available.
  const LoopbackInfo.none()
    : available = false,
      kind = LoopbackKind.none,
      deviceName = '';

  /// Projects a native `le_loopback_info` (via its pointer) into a Dart value.
  factory LoopbackInfo.fromNative(Pointer<le_loopback_info> ptr) {
    final ref = ptr.ref;
    // device_name is the trailing fixed 256-byte field; read it as a C string.
    const nameBytes = 256;
    final namePtr = Pointer<Utf8>.fromAddress(
      ptr.address + sizeOf<le_loopback_info>() - nameBytes,
    );
    return LoopbackInfo(
      available: ref.available != 0,
      kind: LoopbackKind.fromCode(ref.kind),
      deviceName: ref.available != 0 ? namePtr.toDartString() : '',
    );
  }

  /// Whether a cable-free loopback path was found.
  final bool available;

  /// The kind of loopback detected.
  final LoopbackKind kind;

  /// The capture device to open for an auto-measurement, or empty when the
  /// loopback is the backend's built-in path that is not auto-routed.
  final String deviceName;

  /// Whether the engine can auto-route capture from this loopback (i.e. there
  /// is a concrete capture device to open).
  bool get isAutoRoutable => available && deviceName.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LoopbackInfo &&
          runtimeType == other.runtimeType &&
          available == other.available &&
          kind == other.kind &&
          deviceName == other.deviceName;

  @override
  int get hashCode => Object.hash(available, kind, deviceName);

  @override
  String toString() =>
      'LoopbackInfo(available: $available, kind: ${kind.name}, '
      'deviceName: $deviceName)';
}
