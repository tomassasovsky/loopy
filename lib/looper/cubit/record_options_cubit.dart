import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Global record-behavior options applied to the [LooperRepository] and
/// persisted via [SettingsRepository].
class RecordOptions extends Equatable {
  /// Creates a [RecordOptions].
  const RecordOptions({this.recDub = false, this.autoRecord = false});

  /// When `true`, a record press finalizing a recording continues into overdub
  /// instead of playback (the second-press "rec/dub" mode).
  final bool recDub;

  /// When `true`, recording is sound-activated: a record press on an empty
  /// track waits and starts when the input crosses the threshold.
  final bool autoRecord;

  /// Returns a copy with the given overrides.
  RecordOptions copyWith({bool? recDub, bool? autoRecord}) => RecordOptions(
    recDub: recDub ?? this.recDub,
    autoRecord: autoRecord ?? this.autoRecord,
  );

  @override
  List<Object?> get props => [recDub, autoRecord];
}

/// Owns the global record-behavior options: applies them to the repository and
/// persists them. Defaults to both off (the classic rec → play behavior).
class RecordOptionsCubit extends Cubit<RecordOptions> {
  /// Creates a [RecordOptionsCubit] driving [repository], persisted through
  /// [settings].
  RecordOptionsCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings,
       super(const RecordOptions());

  final LooperRepository _repository;
  final SettingsRepository _settings;
  Future<void>? _loadFuture;

  /// Restores the persisted options and applies them to the repository.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final recDub = await _settings.loadRecDub();
    final autoRecord = await _settings.loadAutoRecord();
    _repository
      ..setRecDub(enabled: recDub)
      ..setAutoRecord(enabled: autoRecord);
    if (!isClosed) emit(RecordOptions(recDub: recDub, autoRecord: autoRecord));
  }

  /// Sets and persists the rec/dub second-press mode, applying it now.
  Future<void> setRecDub({required bool value}) async {
    if (value != state.recDub) {
      emit(state.copyWith(recDub: value));
      _repository.setRecDub(enabled: value);
    }
    await _settings.saveRecDub(value: value);
  }

  /// Sets and persists sound-activated recording, applying it now.
  Future<void> setAutoRecord({required bool value}) async {
    if (value != state.autoRecord) {
      emit(state.copyWith(autoRecord: value));
      _repository.setAutoRecord(enabled: value);
    }
    await _settings.saveAutoRecord(value: value);
  }
}
