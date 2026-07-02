import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:settings_repository/settings_repository.dart';

part 'tracks_state.dart';

/// Tracks-view presentation state: the on-screen track cursor (selected track
/// + active bank, transient) and the persisted view preferences (per-track
/// names, indicator visibility) via [SettingsRepository].
class TracksCubit extends Cubit<TracksState> {
  /// Creates a [TracksCubit] for [trackCount] tracks.
  TracksCubit({
    required SettingsRepository settings,
    int trackCount = TracksState.tracksPerBank * TracksState.bankCountMax,
  }) : _settings = settings,
       super(
         TracksState(
           names: List.generate(trackCount, (i) => 'TRACK ${i + 1}'),
         ),
       );

  final SettingsRepository _settings;
  Future<void>? _loadFuture;
  int _loadGeneration = 0;

  /// Restores the persisted view state: track names and whether the per-track
  /// indicators show.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final generation = ++_loadGeneration;
    final names = [...state.names];
    for (var i = 0; i < names.length; i++) {
      final saved = await _settings.loadTrackName(i);
      if (saved != null && saved.isNotEmpty) names[i] = saved;
    }
    final showIndicators = await _settings.loadShowTrackIndicators();
    if (!isClosed && generation == _loadGeneration) {
      emit(state.copyWith(names: names, showIndicators: showIndicators));
    }
  }

  /// Selects track [channel] and reveals its bank, so the highlighted tile is
  /// always in the visible bank (the two can never drift apart).
  void select(int channel) => emit(
    state.copyWith(
      selectedChannel: channel,
      activeBank: channel ~/ TracksState.tracksPerBank,
    ),
  );

  /// Selects the active [bank] (0 or 1) without moving the track cursor — used
  /// to browse the other bank (e.g. arming its tracks in play mode).
  void selectBank(int bank) => emit(
    state.copyWith(
      activeBank: bank.clamp(0, TracksState.bankCountMax - 1),
    ),
  );

  /// Toggles between bank A and bank B (cursor unchanged).
  void toggleBank() => selectBank(state.activeBank == 0 ? 1 : 0);

  /// Sets and persists whether per-track status indicators are shown.
  Future<void> setShowIndicators({required bool value}) async {
    if (value != state.showIndicators) {
      emit(state.copyWith(showIndicators: value));
    }
    await _settings.saveShowTrackIndicators(value: value);
  }

  /// Renames track [channel] and persists the new [name].
  Future<void> rename(int channel, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || channel < 0 || channel >= state.names.length) return;
    _loadGeneration++;
    final names = [...state.names]..[channel] = trimmed;
    emit(state.copyWith(names: names));
    await _settings.saveTrackName(channel, trimmed);
  }
}
