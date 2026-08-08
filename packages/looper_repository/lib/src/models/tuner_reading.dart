import 'package:equatable/equatable.dart';

/// What the chromatic tuner is hearing on the armed input, as published by the
/// engine each snapshot.
///
/// Three facts rather than one number, because the face has three things to
/// say and cannot derive them from each other: whether anyone is listening
/// ([input]), whether there is a pitch to report ([hz]), and how much to trust
/// it ([confidence]).
///
/// **Armed and silent is not the same as not armed.** A player who has opened
/// the tuner and not yet played a note needs different words from one who has
/// not opened it at all, which is why [input] rides along rather than being
/// inferred from a zero [hz].
class TunerReading extends Equatable {
  /// Creates a [TunerReading].
  const TunerReading({this.hz = 0, this.confidence = 0, this.input = -1});

  /// The detected fundamental in Hz, or `0` when the armed input carries no
  /// pitch this frame. Always `0` while disarmed.
  final double hz;

  /// How periodic the analysed frame was, in `0..1`. A reader can hold the
  /// last good note through the gaps between picks rather than flickering.
  final double confidence;

  /// The hardware input the tuner is armed on, or `-1` when disarmed.
  final int input;

  /// Whether anything is listening at all.
  bool get isArmed => input >= 0;

  /// Whether this frame carries a usable pitch.
  bool get hasPitch => hz > 0;

  @override
  List<Object?> get props => [hz, confidence, input];
}
