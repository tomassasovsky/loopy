import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart' show TrackState;

/// Loopy-specific design tokens layered on top of [ThemeData] via a
/// [ThemeExtension], so the looper grid and visualizer pick up per-mode colors
/// (per-track accents, waveform stroke, tile surfaces) without hard-coding them
/// in widgets.
@immutable
class LooperTheme extends ThemeExtension<LooperTheme> {
  /// Creates a [LooperTheme].
  const LooperTheme({
    required this.trackColors,
    required this.tileBackground,
    required this.tileBorder,
    required this.waveformColor,
    required this.waveformBackground,
    required this.recordColor,
    required this.armedColor,
    required this.trackStateColors,
    required this.mutedColor,
  });

  /// Per-track accent colors, indexed by channel (cycled if more tracks).
  final List<Color> trackColors;

  /// Background of a track tile.
  final Color tileBackground;

  /// Border/divider color on a track tile.
  final Color tileBorder;

  /// Waveform stroke/fill color.
  final Color waveformColor;

  /// Background behind the waveform.
  final Color waveformBackground;

  /// Accent for the record/recording state.
  final Color recordColor;

  /// Accent for the armed (quantized-start pending) state.
  final Color armedColor;

  /// The track meter (peak bar) color for each track state.
  final Map<TrackState, Color> trackStateColors;

  /// Meter color override for a muted track (muted is orthogonal to
  /// [TrackState], so it is not a key in [trackStateColors]).
  final Color mutedColor;

  /// The accent color for [channel] (cycles through [trackColors]).
  Color trackColor(int channel) => trackColors[channel % trackColors.length];

  /// The meter color for a track: [mutedColor] when [muted], otherwise the
  /// [state] color, falling back to the track accent for [channel].
  Color barColor(TrackState state, int channel, {required bool muted}) =>
      muted ? mutedColor : (trackStateColors[state] ?? trackColor(channel));

  @override
  LooperTheme copyWith({
    List<Color>? trackColors,
    Color? tileBackground,
    Color? tileBorder,
    Color? waveformColor,
    Color? waveformBackground,
    Color? recordColor,
    Color? armedColor,
    Map<TrackState, Color>? trackStateColors,
    Color? mutedColor,
  }) => LooperTheme(
    trackColors: trackColors ?? this.trackColors,
    tileBackground: tileBackground ?? this.tileBackground,
    tileBorder: tileBorder ?? this.tileBorder,
    waveformColor: waveformColor ?? this.waveformColor,
    waveformBackground: waveformBackground ?? this.waveformBackground,
    recordColor: recordColor ?? this.recordColor,
    armedColor: armedColor ?? this.armedColor,
    trackStateColors: trackStateColors ?? this.trackStateColors,
    mutedColor: mutedColor ?? this.mutedColor,
  );

  @override
  LooperTheme lerp(ThemeExtension<LooperTheme>? other, double t) {
    if (other is! LooperTheme) return this;
    return LooperTheme(
      trackColors: [
        for (var i = 0; i < trackColors.length; i++)
          Color.lerp(
                trackColors[i],
                other.trackColors[i % other.trackColors.length],
                t,
              ) ??
              trackColors[i],
      ],
      tileBackground:
          Color.lerp(tileBackground, other.tileBackground, t) ?? tileBackground,
      tileBorder: Color.lerp(tileBorder, other.tileBorder, t) ?? tileBorder,
      waveformColor:
          Color.lerp(waveformColor, other.waveformColor, t) ?? waveformColor,
      waveformBackground:
          Color.lerp(waveformBackground, other.waveformBackground, t) ??
          waveformBackground,
      recordColor: Color.lerp(recordColor, other.recordColor, t) ?? recordColor,
      armedColor: Color.lerp(armedColor, other.armedColor, t) ?? armedColor,
      trackStateColors: {
        for (final entry in trackStateColors.entries)
          entry.key:
              Color.lerp(entry.value, other.trackStateColors[entry.key], t) ??
              entry.value,
      },
      mutedColor: Color.lerp(mutedColor, other.mutedColor, t) ?? mutedColor,
    );
  }
}
