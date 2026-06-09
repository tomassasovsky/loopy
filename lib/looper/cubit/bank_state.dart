part of 'bank_cubit.dart';

/// State for [BankCubit]: whether the second bank is enabled and which bank is
/// active.
class BankState extends Equatable {
  /// Creates a [BankState].
  const BankState({this.enabled = false, this.activeBank = 0});

  /// Tracks per bank.
  static const int tracksPerBank = 4;

  /// The number of banks when enabled.
  static const int bankCountMax = 2;

  /// Whether the second bank of four tracks is enabled.
  final bool enabled;

  /// The active bank index (0 or 1).
  final int activeBank;

  /// How many banks are currently selectable.
  int get bankCount => enabled ? bankCountMax : 1;

  /// The first track channel of the visible bank.
  int get baseChannel => enabled ? activeBank * tracksPerBank : 0;

  /// Whether [channel] falls within the visible bank.
  bool contains(int channel) =>
      channel >= baseChannel && channel < baseChannel + tracksPerBank;

  /// Returns a copy with the given fields replaced.
  BankState copyWith({bool? enabled, int? activeBank}) => BankState(
    enabled: enabled ?? this.enabled,
    activeBank: activeBank ?? this.activeBank,
  );

  @override
  List<Object?> get props => [enabled, activeBank];
}
