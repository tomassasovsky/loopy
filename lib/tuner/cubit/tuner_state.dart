part of 'tuner_cubit.dart';

/// State for [TunerCubit]: what the tuner is listening to, and what it heard.
class TunerState extends Equatable {
  /// Creates a [TunerState].
  const TunerState({
    this.input = 0,
    this.isOpen = false,
    this.hz = 0,
    this.pitch,
    this.isStale = false,
  });

  /// The hardware input being listened to. Defaults to the first socket, which
  /// is where a single-instrument rig is plugged in.
  final int input;

  /// Whether the face is on screen and the engine is armed. Detection is gated
  /// on this, so it is a cost switch as much as a UI one.
  final bool isOpen;

  /// The last accepted fundamental in Hz, or `0` when there is nothing to show.
  final double hz;

  /// [hz] resolved to a note, or `null` when there is nothing to show.
  final TunedPitch? pitch;

  /// Whether [pitch] is being held past its frame — the note is still shown,
  /// but nothing fresh has arrived. Lets the face soften rather than snap.
  final bool isStale;

  /// Whether there is a reading worth drawing a needle for.
  bool get hasReading => pitch != null;

  /// Returns a copy with the given overrides. [clearPitch] exists because
  /// `null` cannot distinguish "leave it" from "clear it" in a copyWith.
  TunerState copyWith({
    int? input,
    bool? isOpen,
    double? hz,
    TunedPitch? pitch,
    bool? isStale,
    bool clearPitch = false,
  }) => TunerState(
    input: input ?? this.input,
    isOpen: isOpen ?? this.isOpen,
    hz: hz ?? this.hz,
    pitch: clearPitch ? null : (pitch ?? this.pitch),
    isStale: isStale ?? this.isStale,
  );

  @override
  List<Object?> get props => [
    input,
    isOpen,
    hz,
    pitch?.note,
    pitch?.octave,
    pitch?.cents,
    isStale,
  ];
}
