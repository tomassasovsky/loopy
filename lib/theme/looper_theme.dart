import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart' show TrackState;

/// The distinct appearances a track meter (peak bar) can take. This is the
/// track's [TrackState] plus a [muted] case that overlays any state — collapsed
/// into one enum so a single color table ([LooperTheme.meterColors]) covers
/// every meter color in one place.
enum LooperMeterState {
  /// No audio recorded.
  empty,

  /// Capturing the first pass.
  recording,

  /// Summing input into the existing loop.
  overdubbing,

  /// Looping playback.
  playing,

  /// Playback halted; buffer retained.
  stopped,

  /// Muted (overlays any state).
  muted;

  /// The meter appearance for a track in [state] that may be [muted]. Muted
  /// wins over the underlying state.
  factory LooperMeterState.of(TrackState state, {required bool muted}) {
    if (muted) return LooperMeterState.muted;
    return switch (state) {
      TrackState.empty => LooperMeterState.empty,
      TrackState.recording => LooperMeterState.recording,
      TrackState.overdubbing => LooperMeterState.overdubbing,
      TrackState.playing => LooperMeterState.playing,
      TrackState.stopped => LooperMeterState.stopped,
    };
  }
}

/// Loopy-specific design tokens layered on top of [ThemeData] via a
/// [ThemeExtension], so the looper grid and visualizer pick up per-mode colors
/// (per-track accents, waveform stroke, tile surfaces) without hard-coding them
/// in widgets.
@immutable
class LooperTheme extends ThemeExtension<LooperTheme> {
  /// Creates a [LooperTheme].
  const LooperTheme({
    required this.tileBackground,
    required this.tileBorder,
    required this.waveformColor,
    required this.waveformBackground,
    required this.recordColor,
    required this.meterColors,
  });

  /// Background of a track tile.
  final Color tileBackground;

  /// Border/divider color on a track tile.
  final Color tileBorder;

  /// Waveform stroke/fill color.
  final Color waveformColor;

  /// Background behind the waveform.
  final Color waveformBackground;

  /// Accent for the record/recording state (e.g. the mode indicator).
  final Color recordColor;

  /// The single source of truth for the track-meter (peak bar) color in each
  /// [LooperMeterState].
  final Map<LooperMeterState, Color> meterColors;

  /// The meter color for [state] (transparent if the table omits it).
  Color meterColor(LooperMeterState state) =>
      meterColors[state] ?? Colors.transparent;

  @override
  LooperTheme copyWith({
    Color? tileBackground,
    Color? tileBorder,
    Color? waveformColor,
    Color? waveformBackground,
    Color? recordColor,
    Map<LooperMeterState, Color>? meterColors,
  }) => LooperTheme(
    tileBackground: tileBackground ?? this.tileBackground,
    tileBorder: tileBorder ?? this.tileBorder,
    waveformColor: waveformColor ?? this.waveformColor,
    waveformBackground: waveformBackground ?? this.waveformBackground,
    recordColor: recordColor ?? this.recordColor,
    meterColors: meterColors ?? this.meterColors,
  );

  @override
  LooperTheme lerp(ThemeExtension<LooperTheme>? other, double t) {
    if (other is! LooperTheme) return this;
    return LooperTheme(
      tileBackground:
          Color.lerp(tileBackground, other.tileBackground, t) ?? tileBackground,
      tileBorder: Color.lerp(tileBorder, other.tileBorder, t) ?? tileBorder,
      waveformColor:
          Color.lerp(waveformColor, other.waveformColor, t) ?? waveformColor,
      waveformBackground:
          Color.lerp(waveformBackground, other.waveformBackground, t) ??
          waveformBackground,
      recordColor: Color.lerp(recordColor, other.recordColor, t) ?? recordColor,
      meterColors: {
        for (final entry in meterColors.entries)
          entry.key:
              Color.lerp(entry.value, other.meterColors[entry.key], t) ??
              entry.value,
      },
    );
  }
}
