part of 'inputs_cubit.dart';

/// State for [InputsCubit]: the given name of each hardware input socket.
class InputsState extends Equatable {
  /// Creates an [InputsState] — every socket unnamed unless [names] says
  /// otherwise.
  InputsState({List<String>? names})
    : names = names ?? List<String>.filled(maxInputs, '');

  /// How many sockets carry a name: the engine's own input ceiling
  /// (`LE_MAX_INPUTS`), not the current device's count.
  ///
  /// A name belongs to the SOCKET. Sizing this list to whatever is plugged in
  /// would drop a name the moment a smaller interface was opened, and the
  /// player would find it gone when the big one came back.
  static const int maxInputs = kMaxInputs;

  /// The given name per input, `''` where the socket has none.
  ///
  /// Empty rather than a pre-filled ordinal, so "has a name" is a fact this
  /// list carries rather than one every reader has to re-derive by comparing
  /// against a default. `l10n.inputName` turns an empty entry into the ordinal.
  final List<String> names;

  /// Whether hardware [input] has been given a name.
  bool isNamed(int input) =>
      input >= 0 && input < names.length && names[input].isNotEmpty;

  /// How many sockets carry a given name — the Device row's `2 named`.
  int get namedCount => names.where((name) => name.isNotEmpty).length;

  /// Returns a copy with the given overrides.
  InputsState copyWith({List<String>? names}) =>
      InputsState(names: names ?? this.names);

  @override
  List<Object?> get props => [names];
}
