part of 'inputs_cubit.dart';

/// State for [InputsCubit]: what each hardware input of the open device is
/// called.
class InputsState extends Equatable {
  /// Creates an [InputsState].
  const InputsState({this.device = '', this.names = const {}});

  /// How many sockets a device change probes for stored names.
  ///
  /// A read bound, **not** a naming ceiling: it exists because restoring means
  /// asking the key-value store one socket at a time, and the store cannot be
  /// asked "every key under this device". Set well past any interface this rig
  /// will meet — a 32-in console is the widest thing the engine's own output
  /// mask can address.
  static const int probeCeiling = 32;

  /// The device these names belong to — the engine's reported name, the same
  /// key `latency_offset` uses. Empty before the engine has opened anything.
  final String device;

  /// The given name per input, keyed by socket index. A socket with no name is
  /// **absent** rather than empty, so "has a name" is a fact this map carries
  /// rather than one every reader re-derives.
  final Map<int, String> names;

  /// Whether hardware [input] has been given a name.
  bool isNamed(int input) => (names[input] ?? '').isNotEmpty;

  /// The given name for [input], or empty when it has none.
  String nameOf(int input) => names[input] ?? '';

  /// How many of the first [count] sockets carry a given name — the Inputs
  /// row's `2 named`.
  ///
  /// Counted over the sockets the face SHOWS, not over every name on disk: a
  /// name kept for a socket this device has not got would make the row
  /// disagree with the list under it.
  int namedCount(int count) => [
    for (var input = 0; input < count; input++)
      if (isNamed(input)) input,
  ].length;

  /// Returns a copy with the given overrides.
  InputsState copyWith({String? device, Map<int, String>? names}) =>
      InputsState(device: device ?? this.device, names: names ?? this.names);

  @override
  List<Object?> get props => [device, names];
}
