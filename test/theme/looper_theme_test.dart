import 'dart:math' show sqrt;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart' show TrackState;
import 'package:loopy/theme/theme.dart';

void main() {
  group('peakMeterFill', () {
    test('returns 0 for non-positive peaks', () {
      expect(peakMeterFill(0), 0);
      expect(peakMeterFill(-0.5), 0);
    });

    test('maps full scale to 1 and uses sqrt compression', () {
      expect(peakMeterFill(1), 1);
      expect(peakMeterFill(0.25), closeTo(sqrt(0.25), 1e-12));
      expect(peakMeterFill(0.5), closeTo(sqrt(0.5), 1e-12));
    });

    test('clamps peaks above 1', () {
      expect(peakMeterFill(2), 1);
    });
  });

  group('LooperTheme', () {
    const theme = LooperTheme(
      tileBackground: Color(0xFF111111),
      tileBorder: Color(0xFF222222),
      waveformColor: Color(0xFF00E5FF),
      waveformBackground: Color(0xFF000000),
      recordColor: Color(0xFFFF1744),
      recordMeterColors: {
        LooperMeterState.playing: Color(0xFF00FF00),
        LooperMeterState.muted: Color(0xFFFFFFFF),
      },
      playMeterColors: {
        LooperMeterState.playing: Color(0xFF0000FF),
      },
    );

    test('meterColor picks the table for the current mode', () {
      // Record mode uses recordMeterColors; play mode uses playMeterColors.
      expect(
        theme.meterColor(LooperMeterState.playing, playMode: false),
        const Color(0xFF00FF00),
      );
      expect(
        theme.meterColor(LooperMeterState.playing, playMode: true),
        const Color(0xFF0000FF),
      );
      // A state the active table omits resolves to transparent.
      expect(
        theme.meterColor(LooperMeterState.stopped, playMode: false),
        Colors.transparent,
      );
      expect(
        theme.meterColor(LooperMeterState.muted, playMode: true),
        Colors.transparent,
      );
    });

    test('copyWith overrides only the given fields', () {
      final updated = theme.copyWith(recordColor: const Color(0xFFABCDEF));
      expect(updated.recordColor, const Color(0xFFABCDEF));
      expect(updated.waveformColor, theme.waveformColor);
      expect(updated.recordMeterColors, theme.recordMeterColors);
      expect(updated.playMeterColors, theme.playMeterColors);
    });

    test('lerp interpolates toward the other theme', () {
      final other = theme.copyWith(waveformColor: const Color(0xFFFFFFFF));
      final mid = theme.lerp(other, 1);
      expect(mid.waveformColor, const Color(0xFFFFFFFF));
    });

    test('lerp with a non-LooperTheme returns this', () {
      expect(theme.lerp(null, 0.5), same(theme));
    });
  });

  group('LooperMeterState.of', () {
    test('muted wins over the underlying track state', () {
      expect(
        LooperMeterState.of(TrackState.playing, muted: true),
        LooperMeterState.muted,
      );
      expect(
        LooperMeterState.of(TrackState.recording, muted: true),
        LooperMeterState.muted,
      );
    });

    test('maps each track state when not muted', () {
      expect(
        LooperMeterState.of(TrackState.empty, muted: false),
        LooperMeterState.empty,
      );
      expect(
        LooperMeterState.of(TrackState.recording, muted: false),
        LooperMeterState.recording,
      );
      expect(
        LooperMeterState.of(TrackState.overdubbing, muted: false),
        LooperMeterState.overdubbing,
      );
      expect(
        LooperMeterState.of(TrackState.playing, muted: false),
        LooperMeterState.playing,
      );
      expect(
        LooperMeterState.of(TrackState.stopped, muted: false),
        LooperMeterState.stopped,
      );
    });
  });

  test('AppTheme maps every meter state in both modes and both themes', () {
    final themes = [
      AppTheme.desktop.extension<LooperTheme>()!,
      AppTheme.bigPicture.extension<LooperTheme>()!,
    ];
    for (final theme in themes) {
      for (final state in LooperMeterState.values) {
        expect(theme.recordMeterColors[state], isNotNull);
        expect(theme.playMeterColors[state], isNotNull);
      }
    }
    expect(AppTheme.bigPicture.useMaterial3, isTrue);
  });
}
