import 'package:controller_repository/src/binding_behavior.dart';
import 'package:controller_repository/src/controller_binding.dart';
import 'package:equatable/equatable.dart';

/// What a resolved [ControllerBinding] asks the app to do, with the target
/// still opaque (a canonical-JSON string the app decodes).
///
/// `ControlCubit` is the only subscriber: the single dispatch point where a
/// discrete CC means exactly what the same binding on a footswitch means.
sealed class ControllerBindingEvent extends Equatable {
  /// Const base constructor for the sealed subtypes.
  const ControllerBindingEvent({required this.target});

  /// The bound target as its canonical-JSON string.
  final String target;
}

/// A continuous binding's next value for [target], already mapped onto the
/// binding's LO/HI range and smoothed.
///
/// Values are in the target's own normalized `0..1` domain. Several of these
/// arrive per CC step (the smoothing ramp); the last one for a given move is
/// exactly the mapped endpoint, so a sweep always lands where the range says.
final class ControllerValueEvent extends ControllerBindingEvent {
  /// Creates a [ControllerValueEvent].
  const ControllerValueEvent({required super.target, required this.value});

  /// The value to write, in the target's normalized domain.
  final double value;

  @override
  List<Object?> get props => [target, value];

  @override
  String toString() =>
      'ControllerValueEvent($target = ${value.toStringAsFixed(4)})';
}

/// A discrete binding's on/off EDGE for [target] — the CC equivalent of a
/// footswitch press ([pressed] true) and release ([pressed] false).
///
/// Only edges are emitted: a controller that keeps sending the same side of
/// its threshold produces one event, not a stream of them.
final class ControllerSwitchEvent extends ControllerBindingEvent {
  /// Creates a [ControllerSwitchEvent].
  const ControllerSwitchEvent({
    required super.target,
    required this.behavior,
    required this.pressed,
  });

  /// Whether the press latches ([BindingBehavior.toggle]) or is held
  /// ([BindingBehavior.momentary]).
  final BindingBehavior behavior;

  /// Whether this is the ON edge (a press) or the OFF edge (a release).
  final bool pressed;

  @override
  List<Object?> get props => [target, behavior, pressed];

  @override
  String toString() =>
      'ControllerSwitchEvent($target, ${behavior.name}, '
      '${pressed ? 'press' : 'release'})';
}
