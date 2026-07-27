import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

/// Which chain stage the FX page is editing.
enum FxStage {
  /// Prints into recorded PCM.
  pre,

  /// Live/FOH or playback colour only.
  post,
}

/// Selection + stage for the dedicated FX page.
class FxRacksState extends Equatable {
  /// Creates an [FxRacksState].
  const FxRacksState({
    this.selectedInput = 0,
    this.selectedTrack = 0,
    this.inputStage = FxStage.pre,
    this.trackStage = FxStage.post,
  });

  /// Hardware input under edit.
  final int selectedInput;

  /// Track channel under edit (also Live Signal focus).
  final int selectedTrack;

  /// Input Pre/Post stage.
  final FxStage inputStage;

  /// Track Pre/Post stage.
  final FxStage trackStage;

  /// Returns a copy with the given fields replaced.
  FxRacksState copyWith({
    int? selectedInput,
    int? selectedTrack,
    FxStage? inputStage,
    FxStage? trackStage,
  }) => FxRacksState(
    selectedInput: selectedInput ?? this.selectedInput,
    selectedTrack: selectedTrack ?? this.selectedTrack,
    inputStage: inputStage ?? this.inputStage,
    trackStage: trackStage ?? this.trackStage,
  );

  @override
  List<Object?> get props => [
    selectedInput,
    selectedTrack,
    inputStage,
    trackStage,
  ];
}

/// Presentation surface for Input/Track Pre+Post racks and Live Signal
/// (Live Signal is edited from Signal → Track columns).
///
/// Widgets talk only to this cubit (plus Bloc/Cubit scopes for docks);
/// never call [LooperRepository] FX setters from the view layer.
class FxRacksCubit extends Cubit<FxRacksState> {
  /// Creates an [FxRacksCubit] backed by [repository].
  FxRacksCubit({required LooperRepository repository})
    : _repository = repository,
      super(const FxRacksState());

  final LooperRepository _repository;

  /// Selects hardware [input] for the Input column.
  void selectInput(int input) => emit(state.copyWith(selectedInput: input));

  /// Selects track [channel] and pushes Live Signal focus.
  void selectTrack(int channel) {
    emit(state.copyWith(selectedTrack: channel));
    _repository.setLiveSignalFocus(channel: channel);
  }

  /// Sets the Input column Pre/Post stage.
  void setInputStage(FxStage stage) => emit(state.copyWith(inputStage: stage));

  /// Sets the Track column Pre/Post stage.
  void setTrackStage(FxStage stage) => emit(state.copyWith(trackStage: stage));

  /// Replaces the Input chain for the current selection + stage.
  void setInputEffects(List<TrackEffect> effects) {
    final input = state.selectedInput;
    if (state.inputStage == FxStage.pre) {
      _repository.setInputPreEffects(input: input, effects: effects);
    } else {
      _repository.setInputPostEffects(input: input, effects: effects);
    }
  }

  /// Replaces the Track chain for the current selection + stage.
  void setTrackEffects(List<TrackEffect> effects) {
    final channel = state.selectedTrack;
    if (state.trackStage == FxStage.pre) {
      _repository.setTrackPreEffects(channel: channel, effects: effects);
    } else {
      _repository.setTrackPostEffects(channel: channel, effects: effects);
    }
  }

  /// Sets Live Signal [mode] for the selected track.
  void setLiveSignal(LiveSignalMode mode) {
    setLiveSignalForTrack(state.selectedTrack, mode);
  }

  /// Sets Live Signal [mode] for [channel] (Signal → Track columns).
  void setLiveSignalForTrack(int channel, LiveSignalMode mode) {
    _repository.setTrackLiveSignal(channel: channel, mode: mode);
  }

  /// Cycles Live Signal Off → Auto → On for [channel].
  void cycleLiveSignal(int channel) {
    final current = _repository.trackLiveSignal(channel);
    setLiveSignalForTrack(channel, nextLiveSignalMode(current));
  }

  /// Pushes Live Signal focus for Auto without changing FX page selection.
  void focusLiveSignal(int channel) {
    _repository.setLiveSignalFocus(channel: channel);
  }

  /// Current Input chain for the selected input + stage.
  List<TrackEffect> inputEffects() {
    final input = state.selectedInput;
    return state.inputStage == FxStage.pre
        ? _repository.inputPreEffects(input)
        : _repository.monitorEffects(input);
  }

  /// Current Track chain for the selected track + stage.
  List<TrackEffect> trackEffects() {
    final channel = state.selectedTrack;
    return state.trackStage == FxStage.pre
        ? _repository.trackPreEffects(channel)
        : _repository.trackPostEffects(channel);
  }
}
