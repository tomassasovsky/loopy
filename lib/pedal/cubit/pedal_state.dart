part of 'pedal_cubit.dart';

/// Which behavior set the pedal's footswitches drive.
enum PedalMode {
  /// Recording / transport control (Rec/Play starts and finalizes loops).
  rec,

  /// Mixing control (track buttons toggle mute; Rec/Play toggles the set).
  play,
}

/// Sentinel for [PedalState.copyWith] so a `null` [PedalState.boundOutputId]
/// (unbound) can be set explicitly while omitting it preserves the current id.
const Object _unsetBoundOutputId = Object();

/// The pedal's behavior-machine state — everything loopy owns about the pedal
/// that is not already in the looper snapshot.
///
/// The looper transport / track phases live in `LooperState`; this carries only
/// the pedal-facing overlay: the [mode], the [armedTrack], the [activeBank],
/// the output link status, and the host's enumerated MIDI outputs + bound
/// destination (so the settings picker reads them from state, not via
/// read-through accessors).
class PedalState extends Equatable {
  /// Creates a [PedalState].
  const PedalState({
    this.mode = PedalMode.rec,
    this.armedTrack = 0,
    this.activeBank = 0,
    this.bindStatus = PedalBindStatus.none,
    this.availableOutputs = const [],
    this.boundOutputId,
  });

  /// The active behavior set.
  final PedalMode mode;

  /// The armed track as an absolute channel (`0..7`); recording and Undo target
  /// it. Defaults to track 1 (channel 0) on a clean pedal.
  final int armedTrack;

  /// The active bank: `0` = A (tracks 1–4 / channels 0–3), `1` = B (channels
  /// 4–7).
  final int activeBank;

  /// The pedal output link status, mirrored for the settings UI.
  final PedalBindStatus bindStatus;

  /// The host's currently enumerated MIDI output destinations, refreshed on
  /// hotplug so the settings picker stays current.
  final List<PedalOutput> availableOutputs;

  /// The id of the currently bound output destination, or `null` when unbound.
  final String? boundOutputId;

  /// Whether the pedal is in Play (mixing) mode.
  bool get isPlayMode => mode == PedalMode.play;

  /// The lowest channel of the active bank (`0` for A, `4` for B).
  int get bankBaseChannel => activeBank * tracksPerBank;

  /// The number of track footswitches / channels per bank.
  static const tracksPerBank = 4;

  /// Returns a copy with the given fields replaced.
  PedalState copyWith({
    PedalMode? mode,
    int? armedTrack,
    int? activeBank,
    PedalBindStatus? bindStatus,
    List<PedalOutput>? availableOutputs,
    Object? boundOutputId = _unsetBoundOutputId,
  }) {
    return PedalState(
      mode: mode ?? this.mode,
      armedTrack: armedTrack ?? this.armedTrack,
      activeBank: activeBank ?? this.activeBank,
      bindStatus: bindStatus ?? this.bindStatus,
      availableOutputs: availableOutputs ?? this.availableOutputs,
      boundOutputId: identical(boundOutputId, _unsetBoundOutputId)
          ? this.boundOutputId
          : boundOutputId as String?,
    );
  }

  @override
  List<Object?> get props => [
    mode,
    armedTrack,
    activeBank,
    bindStatus,
    availableOutputs,
    boundOutputId,
  ];
}
