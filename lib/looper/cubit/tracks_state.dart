part of 'tracks_cubit.dart';

/// State for [TracksCubit]: the on-screen track cursor — the active bank and
/// the selected track — plus the persisted view preferences (per-track names,
/// indicator visibility).
///
/// The record/play mode is *not* here: it is the system-wide `LooperMode`
/// owned by `PedalCubit`, which every control surface shares.
///
/// Banking is always on: two banks of [tracksPerBank] channels (0–3 and 4–7),
/// one active at a time. The selected track and the active bank are a single
/// cursor here (they used to be split across a separate `BankCubit`, which let
/// them drift): [TracksCubit.select] moves both, so a selected track can
/// never hide behind the other bank.
class TracksState extends Equatable {
  /// Creates a [TracksState].
  const TracksState({
    required this.names,
    this.selectedChannel = 0,
    this.activeBank = 0,
    this.showIndicators = true,
  });

  /// Tracks per bank.
  static const int tracksPerBank = 4;

  /// The number of banks.
  static const int bankCountMax = 2;

  /// The currently selected (highlighted) track channel.
  final int selectedChannel;

  /// The active bank index (0 or 1) — which group of [tracksPerBank] shows.
  final int activeBank;

  /// Per-track display names, indexed by channel.
  final List<String> names;

  /// Whether per-track status indicators show on the tiles (persisted view
  /// preference; the indicator value itself is a pure function of track data).
  final bool showIndicators;

  /// The first track channel of the visible bank.
  int get baseChannel => activeBank * tracksPerBank;

  /// Whether [channel] falls within the visible bank.
  bool bankContains(int channel) =>
      channel >= baseChannel && channel < baseChannel + tracksPerBank;

  /// The display name for [channel], or a fallback.
  String nameOf(int channel) => channel >= 0 && channel < names.length
      ? names[channel]
      : 'TRACK ${channel + 1}';

  /// Returns a copy with the given overrides.
  TracksState copyWith({
    int? selectedChannel,
    int? activeBank,
    List<String>? names,
    bool? showIndicators,
  }) => TracksState(
    selectedChannel: selectedChannel ?? this.selectedChannel,
    activeBank: activeBank ?? this.activeBank,
    names: names ?? this.names,
    showIndicators: showIndicators ?? this.showIndicators,
  );

  @override
  List<Object?> get props => [
    selectedChannel,
    activeBank,
    names,
    showIndicators,
  ];
}
