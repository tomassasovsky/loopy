import 'package:flutter/foundation.dart';

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
    this.inputChannels = 0,
    this.outputChannels = 0,
    this.bufferSizes = const [],
    this.sampleRates = const [],
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

  /// The device's hardware capture channel count, or `0` when unknown (the
  /// miniaudio enumeration path reports `0`; an ASIO probe fills it in).
  final int inputChannels;

  /// The device's hardware playback channel count, or `0` when unknown.
  final int outputChannels;

  /// The driver's selectable buffer sizes (ASIO drivers only; empty otherwise).
  /// Ascending; always includes the driver's preferred size. The UI offers
  /// these under ASIO instead of the generic list.
  final List<int> bufferSizes;

  /// The driver's supported sample rates in Hz (ASIO drivers only; empty
  /// otherwise). The UI offers these under ASIO instead of the generic list.
  final List<int> sampleRates;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioDevice &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          isDefault == other.isDefault &&
          isInput == other.isInput &&
          inputChannels == other.inputChannels &&
          outputChannels == other.outputChannels &&
          listEquals(bufferSizes, other.bufferSizes) &&
          listEquals(sampleRates, other.sampleRates);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    isDefault,
    isInput,
    inputChannels,
    outputChannels,
    Object.hashAll(bufferSizes),
    Object.hashAll(sampleRates),
  );

  @override
  String toString() =>
      'AudioDevice(id: $id, name: $name, isDefault: $isDefault, '
      'isInput: $isInput, inputChannels: $inputChannels, '
      'outputChannels: $outputChannels, bufferSizes: $bufferSizes, '
      'sampleRates: $sampleRates)';
}
