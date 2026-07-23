import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// The 17 Sheeran-verified time signatures (index plan D1): denominator `4`
/// with numerator `2..7`, denominator `8` with numerator `5..15`. Shared by
/// [TempoCubit] callers and the settings picker so both agree on the valid
/// set without duplicating it.
const List<(int num, int den)> kValidTimeSignatures = [
  (2, 4),
  (3, 4),
  (4, 4),
  (5, 4),
  (6, 4),
  (7, 4),
  (5, 8),
  (6, 8),
  (7, 8),
  (8, 8),
  (9, 8),
  (10, 8),
  (11, 8),
  (12, 8),
  (13, 8),
  (14, 8),
  (15, 8),
];

/// The persisted tempo/click/count-in intent [TempoCubit] loads at startup and
/// re-applies to the [LooperRepository] on every setter — the same shape
/// [LooperRepository]'s own re-apply-on-restart fields mirror, but owned here
/// (the presentation layer) since persistence is a cubit concern, not the
/// repository's (pattern: `RecordOptions` / `record_options_cubit.dart`).
///
/// This is the cubit's own record of what was explicitly configured; the
/// *live* effective values (which may additionally reflect a tap or a
/// loop-derived tempo) are read from [TransportState] instead — see
/// `TempoSettingsSection`'s class doc.
class TempoSettings extends Equatable {
  /// Creates a [TempoSettings].
  const TempoSettings({
    this.bpm = 0,
    this.tsNum = 4,
    this.tsDen = 4,
    this.syncTempo = true,
    this.quantizeDiv = GridDivision.off,
    this.clickMode = ClickMode.off,
    this.clickOutputMask = 0,
    this.clickVolume = 1,
    this.countInBars = 0,
  });

  /// The explicitly-set tempo in BPM; `0` means never explicitly set (mirrors
  /// [LooperRepository]'s own `_tempoBpm` semantics — a tapped or
  /// loop-derived tempo is never written here).
  final double bpm;

  /// Time-signature numerator.
  final int tsNum;

  /// Time-signature denominator (`4` or `8`).
  final int tsDen;

  /// Whether loop↔grid sync is on.
  final bool syncTempo;

  /// Musical quantization granularity.
  final GridDivision quantizeDiv;

  /// Click audibility mode.
  final ClickMode clickMode;

  /// Click output routing bitmask.
  final int clickOutputMask;

  /// Click volume (`0..LE_MAX_GAIN`).
  final double clickVolume;

  /// Count-in length in measures (`0` = off).
  final int countInBars;

  /// Returns a copy with the given overrides.
  TempoSettings copyWith({
    double? bpm,
    int? tsNum,
    int? tsDen,
    bool? syncTempo,
    GridDivision? quantizeDiv,
    ClickMode? clickMode,
    int? clickOutputMask,
    double? clickVolume,
    int? countInBars,
  }) => TempoSettings(
    bpm: bpm ?? this.bpm,
    tsNum: tsNum ?? this.tsNum,
    tsDen: tsDen ?? this.tsDen,
    syncTempo: syncTempo ?? this.syncTempo,
    quantizeDiv: quantizeDiv ?? this.quantizeDiv,
    clickMode: clickMode ?? this.clickMode,
    clickOutputMask: clickOutputMask ?? this.clickOutputMask,
    clickVolume: clickVolume ?? this.clickVolume,
    countInBars: countInBars ?? this.countInBars,
  );

  @override
  List<Object?> get props => [
    bpm,
    tsNum,
    tsDen,
    syncTempo,
    quantizeDiv,
    clickMode,
    clickOutputMask,
    clickVolume,
    countInBars,
  ];
}

/// Owns the tempo grid, click, and count-in settings (plan A5): loads the
/// persisted intent on [load], applies each setter to the [LooperRepository]
/// (the live engine) AND persists it via [SettingsRepository] — mirroring
/// `QuantizeCubit`'s single-writer shape (`quantize_cubit.dart`), extended to
/// the full A1/A2 field set (pattern for the multi-field shape:
/// `RecordOptionsCubit`).
///
/// [tapTempo] is the one exception: a momentary action forwarded straight to
/// the repository, never persisted (see [LooperRepository.tapTempo]'s doc —
/// there is nothing meaningful to remember; the resulting tempo, if any, is
/// the engine's own runtime state).
class TempoCubit extends Cubit<TempoSettings> {
  /// Creates a [TempoCubit] driving [repository], persisted through
  /// [settings]. Starts at the tempo-free defaults until [load] restores the
  /// saved values.
  TempoCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings,
       super(const TempoSettings());

  final LooperRepository _repository;
  final SettingsRepository _settings;
  Future<void>? _loadFuture;

  /// Restores the persisted tempo/click/count-in settings and applies them to
  /// the repository.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final bpm = await _settings.loadTempoBpm();
    final (tsNum, tsDen) = await _settings.loadTimeSignature();
    final syncTempo = await _settings.loadSyncTempo();
    final quantizeDiv = GridDivision.fromCode(
      await _settings.loadQuantizeDiv(),
    );
    final clickMode = ClickMode.fromCode(await _settings.loadClickMode());
    final clickOutputMask = await _settings.loadClickOutputMask();
    final clickVolume = await _settings.loadClickVolume();
    final countInBars = await _settings.loadCountInBars();

    // Only an explicitly-set tempo is restored — pushing the unset `0` would
    // clamp up to 30 BPM and falsely turn the grid on (mirrors
    // LooperRepository.startEngine's own re-apply guard).
    if (bpm > 0) _repository.setTempo(bpm);
    _repository
      ..setTimeSignature(tsNum, tsDen)
      ..setSyncTempo(on: syncTempo)
      ..setQuantizeDiv(quantizeDiv)
      ..setClickMode(clickMode)
      ..setClickOutput(clickOutputMask)
      ..setClickVolume(clickVolume)
      ..setCountIn(countInBars);

    if (!isClosed) {
      emit(
        TempoSettings(
          bpm: bpm,
          tsNum: tsNum,
          tsDen: tsDen,
          syncTempo: syncTempo,
          quantizeDiv: quantizeDiv,
          clickMode: clickMode,
          clickOutputMask: clickOutputMask,
          clickVolume: clickVolume,
          countInBars: countInBars,
        ),
      );
    }
  }

  /// Sets and persists the tempo in BPM, applying it now.
  ///
  /// Unconditionally calls the repository — this is a "set to this value"
  /// command triggered by an explicit user action, not a delta against the
  /// cubit's own cache. The cache can go stale relative to the live engine
  /// (e.g. a pedal-driven [LooperRepository.setClickMode] bypasses this
  /// cubit entirely — see `LooperBloc._toggleMetronome`), so gating the
  /// repository call on `newValue != state.field` risks silently no-op'ing a
  /// user's tap whose target value happens to match the stale cache while
  /// the live engine holds something else. `emit` stays cheap to call
  /// unconditionally too: [Cubit] already no-ops a no-change emit
  /// internally.
  Future<void> setTempo(double bpm) async {
    emit(state.copyWith(bpm: bpm));
    _repository.setTempo(bpm);
    await _settings.saveTempoBpm(bpm);
  }

  /// Sets and persists the time signature, applying it now. [num]/[den] must
  /// be one of [kValidTimeSignatures] — the picker only offers valid choices,
  /// and the engine itself rejects anything else without applying it.
  /// Unconditional repository call — see [setTempo]'s doc.
  Future<void> setTimeSignature(int num, int den) async {
    emit(state.copyWith(tsNum: num, tsDen: den));
    _repository.setTimeSignature(num, den);
    await _settings.saveTimeSignature(num, den);
  }

  /// Sets and persists loop↔grid sync, applying it now. Unconditional
  /// repository call — see [setTempo]'s doc.
  Future<void> setSyncTempo({required bool value}) async {
    emit(state.copyWith(syncTempo: value));
    _repository.setSyncTempo(on: value);
    await _settings.saveSyncTempo(value: value);
  }

  /// Sets and persists the musical quantization granularity, applying it
  /// now. Unconditional repository call — see [setTempo]'s doc.
  Future<void> setQuantizeDiv(GridDivision div) async {
    emit(state.copyWith(quantizeDiv: div));
    _repository.setQuantizeDiv(div);
    await _settings.saveQuantizeDiv(div.code);
  }

  /// Sets and persists the click audibility mode, applying it now.
  /// Unconditional repository call — see [setTempo]'s doc; this is the exact
  /// setter the pedal-toggle staleness bug hit (a pedal press moves the live
  /// engine's click mode without this cubit ever knowing).
  Future<void> setClickMode(ClickMode mode) async {
    emit(state.copyWith(clickMode: mode));
    _repository.setClickMode(mode);
    await _settings.saveClickMode(mode.code);
  }

  /// Sets and persists the click output routing bitmask, applying it now.
  /// Unconditional repository call — see [setTempo]'s doc.
  Future<void> setClickOutput(int mask) async {
    emit(state.copyWith(clickOutputMask: mask));
    _repository.setClickOutput(mask);
    await _settings.saveClickOutputMask(mask);
  }

  /// Sets and persists the click volume, applying it now. Unconditional
  /// repository call — see [setTempo]'s doc.
  Future<void> setClickVolume(double volume) async {
    emit(state.copyWith(clickVolume: volume));
    _repository.setClickVolume(volume);
    await _settings.saveClickVolume(volume);
  }

  /// Sets and persists the count-in length in measures (`0` = off), applying
  /// it now. Unconditional repository call — see [setTempo]'s doc.
  Future<void> setCountInBars(int bars) async {
    final clamped = bars < 0 ? 0 : bars;
    emit(state.copyWith(countInBars: clamped));
    _repository.setCountIn(clamped);
    await _settings.saveCountInBars(clamped);
  }

  /// Registers a tempo tap; two taps within the engine's window set the
  /// tempo from their interval. A momentary action forwarded straight to the
  /// repository — never persisted (see the class doc).
  EngineResult tapTempo() => _repository.tapTempo();
}
