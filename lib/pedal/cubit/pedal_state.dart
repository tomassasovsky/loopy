part of 'pedal_cubit.dart';

/// Which behavior set the pedal's footswitches drive.
enum PedalMode {
  /// Recording / transport control (Rec/Play starts and finalizes loops).
  rec,

  /// Mixing control (track buttons toggle mute; Rec/Play toggles the set).
  play,
}

/// The pedal's behavior-machine state — everything loopy owns about the pedal
/// that is not already in the looper snapshot.
///
/// The looper transport / track phases live in `LooperState`; this carries only
/// the pedal-facing overlay: the [mode], the [armedTrack], the [activeBank],
/// and whether a clear fade is currently counting down.
class PedalState extends Equatable {
  /// Creates a [PedalState].
  const PedalState({
    this.mode = PedalMode.rec,
    this.armedTrack = 0,
    this.activeBank = 0,
    this.clearFadeActive = false,
    this.bindStatus = PedalBindStatus.none,
  });

  /// The active behavior set.
  final PedalMode mode;

  /// The armed track as an absolute channel (`0..7`); recording and Undo target
  /// it. Defaults to track 1 (channel 0) on a clean pedal.
  final int armedTrack;

  /// The active bank: `0` = A (tracks 1–4 / channels 0–3), `1` = B (channels
  /// 4–7).
  final int activeBank;

  /// Whether a clear-all fade is currently counting down (the abort window).
  final bool clearFadeActive;

  /// The pedal output link status, mirrored for the settings UI.
  final PedalBindStatus bindStatus;

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
    bool? clearFadeActive,
    PedalBindStatus? bindStatus,
  }) {
    return PedalState(
      mode: mode ?? this.mode,
      armedTrack: armedTrack ?? this.armedTrack,
      activeBank: activeBank ?? this.activeBank,
      clearFadeActive: clearFadeActive ?? this.clearFadeActive,
      bindStatus: bindStatus ?? this.bindStatus,
    );
  }

  @override
  List<Object?> get props => [
    mode,
    armedTrack,
    activeBank,
    clearFadeActive,
    bindStatus,
  ];
}
