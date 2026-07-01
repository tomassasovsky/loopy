part of 'pedal_cubit.dart';

/// Sentinel for [PedalState.copyWith] so a `null` [PedalState.boundOutputId]
/// (unbound) can be set explicitly while omitting it preserves the current id.
const Object _unsetBoundOutputId = Object();

/// The pedal's behavior-machine state — everything loopy owns about the pedal
/// that is not already in the looper snapshot.
///
/// The looper transport / track phases live in `LooperState`; this carries only
/// the pedal-facing overlay. Arming is modeled as **two distinct concepts**,
/// one per [mode]:
///
/// * Rec mode — [selectedTrack]: a single cursor (what Rec/Play, Stop, Undo and
///   Redo act on).
/// * Play mode — [playArmed]: a *set* of channels selected to play (what sounds
///   when the transport starts, and what the green LEDs show).
///
/// [PedalMode] itself lives in `pedal_repository` so the wire frame can carry
/// it; loopy re-exports it through this cubit.
class PedalState extends Equatable {
  /// Creates a [PedalState].
  const PedalState({
    this.mode = PedalMode.rec,
    this.selectedTrack = 0,
    this.playArmed = const {},
    this.activeBank = 0,
    this.bindStatus = PedalBindStatus.none,
    this.availableOutputs = const [],
    this.boundOutputId,
  });

  /// The active behavior set (Rec vs Play).
  final PedalMode mode;

  /// Rec-mode cursor: the single selected track as an absolute channel
  /// (`0..7`). Rec/Play, Stop, Undo and Redo target it. Defaults to track 1
  /// (channel 0) on a clean pedal.
  final int selectedTrack;

  /// Play-mode arming: the channels selected to play. This is *membership* —
  /// what sounds when the transport is (re)started, what persists across a
  /// stop, and what the green track LEDs show. Empty until tracks are armed.
  final Set<int> playArmed;

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

  /// The lowest channel of the active bank (`0` for A, `4` for B).
  int get bankBaseChannel => activeBank * tracksPerBank;

  /// The number of track footswitches / channels per bank.
  static const tracksPerBank = 4;

  /// Returns a copy with the given fields replaced.
  PedalState copyWith({
    PedalMode? mode,
    int? selectedTrack,
    Set<int>? playArmed,
    int? activeBank,
    PedalBindStatus? bindStatus,
    List<PedalOutput>? availableOutputs,
    Object? boundOutputId = _unsetBoundOutputId,
  }) {
    return PedalState(
      mode: mode ?? this.mode,
      selectedTrack: selectedTrack ?? this.selectedTrack,
      playArmed: playArmed ?? this.playArmed,
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
    selectedTrack,
    playArmed,
    activeBank,
    bindStatus,
    availableOutputs,
    boundOutputId,
  ];
}
