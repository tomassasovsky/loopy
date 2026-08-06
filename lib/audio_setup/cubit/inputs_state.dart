part of 'inputs_cubit.dart';

/// State for [InputsCubit]: one given name per hardware input, empty when the
/// input has never been named.
class InputsState extends Equatable {
  /// Creates an [InputsState].
  const InputsState({required this.names});

  /// How many inputs names are kept for.
  ///
  /// The engine's own ceiling (`LE_MAX_INPUTS`), not the current device's
  /// count: an interface swap must not drop the names of sockets that come
  /// back later.
  static const int maxInputs = 8;

  /// Given names by input index; `''` where the input has never been named.
  final List<String> names;

  /// The given name for [input], or `''` when it has none.
  String nameOf(int input) =>
      input >= 0 && input < names.length ? names[input] : '';

  /// How many inputs have been given a name — the Device tab's summary.
  int get namedCount => names.where((name) => name.isNotEmpty).length;

  /// Returns a copy with the given overrides.
  InputsState copyWith({List<String>? names}) =>
      InputsState(names: names ?? this.names);

  @override
  List<Object?> get props => [names];
}
