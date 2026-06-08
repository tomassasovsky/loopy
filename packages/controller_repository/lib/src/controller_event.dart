import 'package:controller_repository/src/looper_action.dart';
import 'package:equatable/equatable.dart';

/// A resolved, hardware-agnostic controller event.
///
/// Produced by the repository after applying the active mapping to a raw input.
/// The bloc layer turns these into looper commands.
class ControllerEvent extends Equatable {
  /// Creates a [ControllerEvent].
  const ControllerEvent({required this.action, this.channel = 0});

  /// The looper action to perform.
  final LooperAction action;

  /// The target channel for channel-scoped actions; ignored for global ones.
  final int channel;

  @override
  List<Object?> get props => [action, channel];

  @override
  String toString() => 'ControllerEvent(${action.name}, channel: $channel)';
}
