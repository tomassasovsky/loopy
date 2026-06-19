part of 'midi_setup_cubit.dart';

/// State for the MIDI setup feature: the repository's [MidiConnection] domain
/// model plus an opaque activity tick. The cubit composes these so the picker
/// can show the connection and blink the input indicator from one state.
class MidiSetupState extends Equatable {
  /// Creates a [MidiSetupState].
  const MidiSetupState({
    this.connection = const MidiConnection(),
    this.activityTick = 0,
  });

  /// The MIDI input connection (devices, selection, status, connectivity).
  final MidiConnection connection;

  /// A monotonically increasing counter bumped on every raw (pre-mapping) MIDI
  /// message, so the activity indicator can blink. The value itself is
  /// meaningless; only its changes matter.
  final int activityTick;

  /// Returns a copy with the given fields replaced.
  MidiSetupState copyWith({
    MidiConnection? connection,
    int? activityTick,
  }) {
    return MidiSetupState(
      connection: connection ?? this.connection,
      activityTick: activityTick ?? this.activityTick,
    );
  }

  @override
  List<Object?> get props => [connection, activityTick];
}
