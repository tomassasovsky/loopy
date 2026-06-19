import 'package:equatable/equatable.dart';

/// A MIDI output destination the pedal's LED state frames can be bound to.
///
/// The repository-owned domain model for an output device, so the presentation
/// layer never names the `midi_client` data type. The repository maps the raw
/// enumerated device to this at `PedalRepository.availableOutputs`.
class PedalOutput extends Equatable {
  /// Creates a [PedalOutput].
  const PedalOutput({required this.id, required this.name});

  /// The backend-specific output id, used to bind via `PedalRepository.bind`.
  final String id;

  /// The human-readable device label.
  final String name;

  @override
  List<Object?> get props => [id, name];
}
