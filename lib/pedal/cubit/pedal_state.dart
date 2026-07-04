part of 'pedal_cubit.dart';

/// Sentinel for [PedalState.copyWith] so a `null` [PedalState.boundOutputId]
/// (unbound) can be set explicitly while omitting it preserves the current id.
const Object _unsetBoundOutputId = Object();

/// The pedal LINK state: everything about the physical (or simulated) pedal's
/// transport binding, and nothing else.
///
/// The control overlay (mode, cursor, bank, play intent) lives in
/// `ControlOverlayCubit`; the looper transport/track truth in `LooperState`;
/// the LEDs are a pure projection of the two (`control_projection.dart`).
/// This cubit's state is only the output-device plumbing the settings picker
/// renders.
class PedalState extends Equatable {
  /// Creates a [PedalState].
  const PedalState({
    this.bindStatus = PedalBindStatus.none,
    this.availableOutputs = const [],
    this.boundOutputId,
  });

  /// The pedal output link status, mirrored for the settings UI.
  final PedalBindStatus bindStatus;

  /// The host's currently enumerated MIDI output destinations, refreshed on
  /// hotplug so the settings picker stays current.
  final List<PedalOutput> availableOutputs;

  /// The id of the currently bound output destination, or `null` when unbound.
  final String? boundOutputId;

  /// Returns a copy with the given fields replaced.
  PedalState copyWith({
    PedalBindStatus? bindStatus,
    List<PedalOutput>? availableOutputs,
    Object? boundOutputId = _unsetBoundOutputId,
  }) {
    return PedalState(
      bindStatus: bindStatus ?? this.bindStatus,
      availableOutputs: availableOutputs ?? this.availableOutputs,
      boundOutputId: identical(boundOutputId, _unsetBoundOutputId)
          ? this.boundOutputId
          : boundOutputId as String?,
    );
  }

  @override
  List<Object?> get props => [bindStatus, availableOutputs, boundOutputId];
}
