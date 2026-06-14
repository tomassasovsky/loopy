part of 'bank_cubit.dart';

/// State for [BankCubit]: which of the two banks of four tracks is active.
///
/// Banking is always on — there are two banks of four (channels 0–3 and 4–7),
/// selected one at a time.
class BankState extends Equatable {
  /// Creates a [BankState].
  const BankState({this.activeBank = 0});

  /// Tracks per bank.
  static const int tracksPerBank = 4;

  /// The number of banks.
  static const int bankCountMax = 2;

  /// The active bank index (0 or 1).
  final int activeBank;

  /// How many banks are selectable.
  int get bankCount => bankCountMax;

  /// The first track channel of the visible bank.
  int get baseChannel => activeBank * tracksPerBank;

  /// Whether [channel] falls within the visible bank.
  bool contains(int channel) =>
      channel >= baseChannel && channel < baseChannel + tracksPerBank;

  /// Returns a copy with the given fields replaced.
  BankState copyWith({int? activeBank}) =>
      BankState(activeBank: activeBank ?? this.activeBank);

  @override
  List<Object?> get props => [activeBank];
}
