import 'package:controller_repository/controller_repository.dart';
import 'package:equatable/equatable.dart';

/// A MIDI-learn capture in progress: what it will bind, and — once a control
/// has been moved — what it caught.
///
/// Stored intent while it lasts, so the settings row can render "listening…",
/// its cancel action, and the replace confirmation from one watched state
/// rather than from widget-local bookkeeping that a rebuild would drop.
class ControllerLearn extends Equatable {
  /// Creates a [ControllerLearn].
  const ControllerLearn({
    required this.target,
    required this.continuous,
    this.replacingKey,
    this.captured,
  });

  /// The canonical-JSON target string the capture will bind.
  final String target;

  /// Whether the binding being learned is continuous (LO/HI sweep) rather than
  /// discrete (threshold stomp).
  final bool continuous;

  /// The IDENTITY of the mapping being re-learned — its `(control, target)`
  /// key — or `null` for a new mapping.
  ///
  /// A key, never the binding itself: the row stays editable while its capture
  /// listens, so a value snapshot would stop matching the moment a knob moved.
  /// Everything that has to find that row again — the listening indicator, the
  /// already-mapped check, and the apply — resolves this key against the LIVE
  /// set, which is also what carries the row's current ranges into the rebind.
  final (MappingTrigger, String)? replacingKey;

  /// The control that was caught, once one has been — non-null only while the
  /// capture is waiting for the user to confirm replacing an existing mapping
  /// on that same control (R28). A capture with nothing to replace applies
  /// immediately and never reaches this state.
  final MappingTrigger? captured;

  /// Whether this capture is waiting on the replace confirmation.
  bool get awaitingConfirm => captured != null;

  /// Returns a copy with [captured] set.
  ControllerLearn withCaptured(MappingTrigger trigger) => ControllerLearn(
    target: target,
    continuous: continuous,
    replacingKey: replacingKey,
    captured: trigger,
  );

  @override
  List<Object?> get props => [target, continuous, replacingKey, captured];
}
