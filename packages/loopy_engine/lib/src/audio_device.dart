import 'package:meta/meta.dart';

/// A hardware audio device discovered by `AudioEngine.enumerateDevices`.
///
/// The pure-Dart projection of the native `le_device_info` struct, paired with
/// the [isInput] discriminator the enumeration call tags onto each result.
@immutable
class AudioDevice {
  /// Creates an [AudioDevice].
  const AudioDevice({
    required this.id,
    required this.name,
    required this.isDefault,
    required this.isInput,
  });

  /// The backend-specific device id, suitable for pinning via
  /// `EngineConfig.playbackDeviceId` / `EngineConfig.captureDeviceId`.
  final String id;

  /// The human-readable device label.
  final String name;

  /// Whether this is the system default device for its direction.
  final bool isDefault;

  /// Whether this is a capture (input) device; `false` for a playback (output)
  /// device.
  final bool isInput;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioDevice &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          isDefault == other.isDefault &&
          isInput == other.isInput;

  @override
  int get hashCode => Object.hash(id, name, isDefault, isInput);

  @override
  String toString() =>
      'AudioDevice(id: $id, name: $name, isDefault: $isDefault, '
      'isInput: $isInput)';
}
