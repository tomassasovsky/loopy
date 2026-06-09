import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:loopy/looper/cubit/bank_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

part 'big_picture_state.dart';

/// Big-picture presentation state: which track is selected (a UI cursor, not
/// persisted) and the per-track display names (persisted via
/// [SettingsRepository]).
class BigPictureCubit extends Cubit<BigPictureState> {
  /// Creates a [BigPictureCubit] for [trackCount] tracks.
  BigPictureCubit({
    required SettingsRepository settings,
    int trackCount = BankState.tracksPerBank * BankState.bankCountMax,
  }) : _settings = settings,
       super(
         BigPictureState(
           names: List.generate(trackCount, (i) => 'TRACK ${i + 1}'),
         ),
       );

  final SettingsRepository _settings;

  /// Restores any persisted track names.
  Future<void> load() async {
    final names = [...state.names];
    for (var i = 0; i < names.length; i++) {
      final saved = await _settings.loadTrackName(i);
      if (saved != null && saved.isNotEmpty) names[i] = saved;
    }
    emit(state.copyWith(names: names));
  }

  /// Selects track [channel] (the highlighted tile).
  void select(int channel) => emit(state.copyWith(selectedChannel: channel));

  /// Toggles between record and play performance modes.
  void toggleMode() => emit(
    state.copyWith(
      mode: state.mode == PerformanceMode.record
          ? PerformanceMode.play
          : PerformanceMode.record,
    ),
  );

  /// Renames track [channel] and persists the new [name].
  Future<void> rename(int channel, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || channel < 0 || channel >= state.names.length) return;
    final names = [...state.names]..[channel] = trimmed;
    emit(state.copyWith(names: names));
    await _settings.saveTrackName(channel, trimmed);
  }
}
