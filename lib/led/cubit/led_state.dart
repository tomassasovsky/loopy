part of 'led_cubit.dart';

/// App-facing state of the console LED channel: just the driver-link [health],
/// which drives the "LED driver missing" fault banner.
class LedState extends Equatable {
  /// Creates a [LedState].
  const LedState({this.health = LedHealth.unknown});

  /// The resolved health of the LED driver link.
  final LedHealth health;

  /// Returns a copy with [health] replaced.
  LedState copyWith({LedHealth? health}) =>
      LedState(health: health ?? this.health);

  @override
  List<Object?> get props => [health];
}
