part of 'tracks_cubit.dart';

/// State for [TracksCubit]: the persisted tracks-view preferences (per-track
/// names, indicator visibility).
///
/// The track cursor, active bank, and record/play mode are control state
/// owned by `ControlOverlayCubit` — one cursor for every surface, so the
/// keyboard, the tiles, and the pedal can never target different tracks.
class TracksState extends Equatable {
  /// Creates a [TracksState].
  const TracksState({
    required this.names,
    // Off by default in console/kiosk builds (see [kConsoleMode]); the loaded
    // preference can still turn it on.
    this.showIndicators = !kConsoleMode,
  });

  /// Tracks per bank.
  static const int tracksPerBank = 4;

  /// The number of banks.
  static const int bankCountMax = 2;

  /// Per-track display names, indexed by channel.
  final List<String> names;

  /// Whether per-track status indicators show on the tiles (persisted view
  /// preference; the indicator value itself is a pure function of track data).
  final bool showIndicators;

  /// The display name for [channel], or a fallback.
  String nameOf(int channel) => channel >= 0 && channel < names.length
      ? names[channel]
      : 'TRACK ${channel + 1}';

  /// Returns a copy with the given overrides.
  TracksState copyWith({
    List<String>? names,
    bool? showIndicators,
  }) => TracksState(
    names: names ?? this.names,
    showIndicators: showIndicators ?? this.showIndicators,
  );

  @override
  List<Object?> get props => [names, showIndicators];
}
