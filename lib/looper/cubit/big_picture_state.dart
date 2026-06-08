part of 'big_picture_cubit.dart';

/// State for [BigPictureCubit]: the selected track and per-track display names.
class BigPictureState extends Equatable {
  /// Creates a [BigPictureState].
  const BigPictureState({required this.names, this.selectedChannel = 0});

  /// The currently selected (highlighted) track channel.
  final int selectedChannel;

  /// Per-track display names, indexed by channel.
  final List<String> names;

  /// The display name for [channel], or a fallback.
  String nameOf(int channel) => channel >= 0 && channel < names.length
      ? names[channel]
      : 'TRACK ${channel + 1}';

  /// Returns a copy with the given overrides.
  BigPictureState copyWith({int? selectedChannel, List<String>? names}) =>
      BigPictureState(
        selectedChannel: selectedChannel ?? this.selectedChannel,
        names: names ?? this.names,
      );

  @override
  List<Object?> get props => [selectedChannel, names];
}
