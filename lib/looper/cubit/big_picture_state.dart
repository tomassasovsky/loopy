part of 'big_picture_cubit.dart';

/// The keyboard-driven performance mode.
enum PerformanceMode {
  /// Number keys select a track; R/P record and play the selection.
  record,

  /// Number keys select and mute/unmute a track.
  play;

  /// The persisted token for this mode (stable across renames).
  String get token => name;

  /// Parses a persisted [token] back to a mode, defaulting to [record].
  static PerformanceMode fromToken(String? token) =>
      PerformanceMode.values.firstWhere(
        (m) => m.name == token,
        orElse: () => PerformanceMode.record,
      );
}

/// State for [BigPictureCubit]: the performance mode, the selected track, and
/// per-track display names.
class BigPictureState extends Equatable {
  /// Creates a [BigPictureState].
  const BigPictureState({
    required this.names,
    this.selectedChannel = 0,
    this.mode = PerformanceMode.record,
    this.defaultMode = PerformanceMode.record,
  });

  /// The currently selected (highlighted) track channel.
  final int selectedChannel;

  /// The active performance mode (transient; toggled live with `M`).
  final PerformanceMode mode;

  /// The persisted mode the view boots into. Setting it also updates [mode].
  final PerformanceMode defaultMode;

  /// Per-track display names, indexed by channel.
  final List<String> names;

  /// The display name for [channel], or a fallback.
  String nameOf(int channel) => channel >= 0 && channel < names.length
      ? names[channel]
      : 'TRACK ${channel + 1}';

  /// Returns a copy with the given overrides.
  BigPictureState copyWith({
    int? selectedChannel,
    PerformanceMode? mode,
    PerformanceMode? defaultMode,
    List<String>? names,
  }) => BigPictureState(
    selectedChannel: selectedChannel ?? this.selectedChannel,
    mode: mode ?? this.mode,
    defaultMode: defaultMode ?? this.defaultMode,
    names: names ?? this.names,
  );

  @override
  List<Object?> get props => [selectedChannel, mode, defaultMode, names];
}
