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
  Future<void>? _loadFuture;
  int _loadGeneration = 0;

  /// Restores any persisted track names and the default performance mode.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final generation = ++_loadGeneration;
    final names = [...state.names];
    for (var i = 0; i < names.length; i++) {
      final saved = await _settings.loadTrackName(i);
      if (saved != null && saved.isNotEmpty) names[i] = saved;
    }
    final defaultMode = PerformanceMode.fromToken(
      await _settings.loadDefaultPerformanceMode(),
    );
    if (!isClosed && generation == _loadGeneration) {
      // Boot the live mode into the restored default.
      emit(
        state.copyWith(
          names: names,
          mode: defaultMode,
          defaultMode: defaultMode,
        ),
      );
    }
  }

  /// Selects track [channel] (the highlighted tile).
  void select(int channel) => emit(state.copyWith(selectedChannel: channel));

  /// Toggles between record and play performance modes. Transient — does not
  /// change the persisted [BigPictureState.defaultMode].
  void toggleMode() => emit(
    state.copyWith(
      mode: state.mode == PerformanceMode.record
          ? PerformanceMode.play
          : PerformanceMode.record,
    ),
  );

  /// Sets and persists the default performance [mode] the view boots into, and
  /// applies it to the live mode now.
  Future<void> setDefaultPerformanceMode(PerformanceMode mode) async {
    emit(state.copyWith(mode: mode, defaultMode: mode));
    await _settings.saveDefaultPerformanceMode(mode.token);
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
