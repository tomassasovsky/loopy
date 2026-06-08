import 'package:flutter/material.dart';

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

  /// The accent color for [channel] (cycles through [trackColors]).
  Color trackColor(int channel) => trackColors[channel % trackColors.length];

  @override
  LooperTheme copyWith({
    List<Color>? trackColors,
    Color? tileBackground,
    Color? tileBorder,
    Color? waveformColor,
    Color? waveformBackground,
    Color? recordColor,
    Color? armedColor,
  }) => LooperTheme(
    trackColors: trackColors ?? this.trackColors,
    tileBackground: tileBackground ?? this.tileBackground,
    tileBorder: tileBorder ?? this.tileBorder,
    waveformColor: waveformColor ?? this.waveformColor,
    waveformBackground: waveformBackground ?? this.waveformBackground,
    recordColor: recordColor ?? this.recordColor,
    armedColor: armedColor ?? this.armedColor,
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
    );
  }
}
