import 'dart:math' show sqrt;

import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart' show TrackState;
import 'package:loopy/looper/model/interaction_mode.dart';

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

/// The discrete arm/readiness appearance of a track's status indicator —
/// independent of the meter palette and of the hardware pedal LEDs.
enum TrackIndicator {
  /// Inactive / not armed. Dim.
  idle,

  /// Playing, or armed to play (selected in mute mode). Green.
  play,

  /// Recording/overdubbing, or armed to record (selected in record mode). Red.
  record;

  /// Indicator state for a track. Transport state wins over the
  /// selected/armed derivation; `muted` reads as [idle] (matching the meter's
  /// muted-first precedence on the same tile).
  ///
  /// A **stopped** track that still holds a loop ([hasContent]) reads as
  /// [play] — it is armed to play and will sound on the next play-all, so the
  /// indicator stays lit after a stop rather than going dark. An empty/cleared
  /// track only arms (by mode) when [selected]: green in mute mode, red in
  /// record mode.
  factory TrackIndicator.of(
    TrackState state, {
    required bool muted,
    required bool hasContent,
    required bool selected,
    required InteractionMode mode,
  }) {
    if (muted) return TrackIndicator.idle;
    return switch (state) {
      TrackState.recording || TrackState.overdubbing => TrackIndicator.record,
      TrackState.playing => TrackIndicator.play,
      TrackState.stopped when hasContent => TrackIndicator.play,
      TrackState.empty || TrackState.stopped =>
        selected
            ? (mode == InteractionMode.mute
                  ? TrackIndicator.play
                  : TrackIndicator.record)
            : TrackIndicator.idle,
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
    required this.muteMeterColors,
    required this.indicatorColors,
    required this.toolbarIconColor,
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

  /// Track-meter (peak bar) colors by [LooperMeterState] in mute mode.
  final Map<LooperMeterState, Color> muteMeterColors;

  /// Per-track status-indicator colors by [TrackIndicator].
  final Map<TrackIndicator, Color> indicatorColors;

  /// Icon color for the toolbar's unarmed/neutral icon buttons (Play/Stop
  /// All, Clear All, Fullscreen, Signal, Settings, Session, and the
  /// unarmed performance-record button).
  final Color toolbarIconColor;

  /// The meter color for [state] in the current mode ([mode] selects the
  /// mute or record table). Transparent if the table omits it.
  Color meterColor(LooperMeterState state, {required InteractionMode mode}) =>
      {
        InteractionMode.mute: muteMeterColors,
        InteractionMode.record: recordMeterColors,
      }[mode]![state] ??
      Colors.transparent;

  /// The status-indicator color for [indicator]. Transparent if the table
  /// omits it.
  Color indicatorColor(TrackIndicator indicator) =>
      indicatorColors[indicator] ?? Colors.transparent;

  @override
  LooperTheme copyWith({
    Color? tileBackground,
    Color? tileBorder,
    Color? waveformColor,
    Color? waveformBackground,
    Color? recordColor,
    Map<LooperMeterState, Color>? recordMeterColors,
    Map<LooperMeterState, Color>? muteMeterColors,
    Map<TrackIndicator, Color>? indicatorColors,
    Color? toolbarIconColor,
  }) => LooperTheme(
    tileBackground: tileBackground ?? this.tileBackground,
    tileBorder: tileBorder ?? this.tileBorder,
    waveformColor: waveformColor ?? this.waveformColor,
    waveformBackground: waveformBackground ?? this.waveformBackground,
    recordColor: recordColor ?? this.recordColor,
    recordMeterColors: recordMeterColors ?? this.recordMeterColors,
    muteMeterColors: muteMeterColors ?? this.muteMeterColors,
    indicatorColors: indicatorColors ?? this.indicatorColors,
    toolbarIconColor: toolbarIconColor ?? this.toolbarIconColor,
  );

  static Map<K, Color> _lerpColorMap<K>(
    Map<K, Color> a,
    Map<K, Color> b,
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
      recordMeterColors: _lerpColorMap(
        recordMeterColors,
        other.recordMeterColors,
        t,
      ),
      muteMeterColors: _lerpColorMap(
        muteMeterColors,
        other.muteMeterColors,
        t,
      ),
      indicatorColors: _lerpColorMap(
        indicatorColors,
        other.indicatorColors,
        t,
      ),
      toolbarIconColor:
          Color.lerp(toolbarIconColor, other.toolbarIconColor, t) ??
          toolbarIconColor,
    );
  }
}
