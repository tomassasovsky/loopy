import 'dart:math' show sqrt;

import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart' show TrackState;

/// Maps engine peak amplitude (`0..1`) to meter fill (`0..1`).
///
/// Square-root compression keeps normal playback levels readable on tall meters
/// without clipping early; full scale still maps to 100%.
double peakMeterFill(double peak) {
  if (peak <= 0) return 0;
  return sqrt(peak.clamp(0.0, 1.0));
}

/// The distinct appearances a track meter (peak bar) can take: the track's
/// [TrackState] plus a `muted` case that overlays any state — collapsed into
/// one enum so the per-mode meter tables key off a single concept.
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
    required this.recordMeterColors,
    required this.playMeterColors,
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

  /// Track-meter (peak bar) colors by [LooperMeterState] in record mode.
  final Map<LooperMeterState, Color> recordMeterColors;

  /// Track-meter (peak bar) colors by [LooperMeterState] in play mode.
  final Map<LooperMeterState, Color> playMeterColors;

  /// The meter color for [state] in the current mode ([playMode] selects the
  /// play table, else the record table). Transparent if the table omits it.
  Color meterColor(LooperMeterState state, {required bool playMode}) =>
      (playMode ? playMeterColors : recordMeterColors)[state] ??
      Colors.transparent;

  @override
  LooperTheme copyWith({
    Color? tileBackground,
    Color? tileBorder,
    Color? waveformColor,
    Color? waveformBackground,
    Color? recordColor,
    Map<LooperMeterState, Color>? recordMeterColors,
    Map<LooperMeterState, Color>? playMeterColors,
  }) => LooperTheme(
    tileBackground: tileBackground ?? this.tileBackground,
    tileBorder: tileBorder ?? this.tileBorder,
    waveformColor: waveformColor ?? this.waveformColor,
    waveformBackground: waveformBackground ?? this.waveformBackground,
    recordColor: recordColor ?? this.recordColor,
    recordMeterColors: recordMeterColors ?? this.recordMeterColors,
    playMeterColors: playMeterColors ?? this.playMeterColors,
  );

  static Map<LooperMeterState, Color> _lerpMeters(
    Map<LooperMeterState, Color> a,
    Map<LooperMeterState, Color> b,
    double t,
  ) => {
    for (final entry in a.entries)
      entry.key: Color.lerp(entry.value, b[entry.key], t) ?? entry.value,
  };

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
      recordMeterColors: _lerpMeters(
        recordMeterColors,
        other.recordMeterColors,
        t,
      ),
      playMeterColors: _lerpMeters(playMeterColors, other.playMeterColors, t),
    );
  }
}
