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
      indicatorColors: {
        TrackIndicator.idle: Color(0xFF3A3F49),
        TrackIndicator.play: Color(0xFF4CDA4A),
        TrackIndicator.record: Color(0xFFFF1744),
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

    test('indicatorColor picks the color for the indicator', () {
      expect(
        theme.indicatorColor(TrackIndicator.idle),
        const Color(0xFF3A3F49),
      );
      expect(
        theme.indicatorColor(TrackIndicator.play),
        const Color(0xFF4CDA4A),
      );
      expect(
        theme.indicatorColor(TrackIndicator.record),
        const Color(0xFFFF1744),
      );
    });

    test('indicatorColor resolves to transparent when the table omits it', () {
      const sparse = LooperTheme(
        tileBackground: Color(0xFF111111),
        tileBorder: Color(0xFF222222),
        waveformColor: Color(0xFF00E5FF),
        waveformBackground: Color(0xFF000000),
        recordColor: Color(0xFFFF1744),
        recordMeterColors: {},
        playMeterColors: {},
        indicatorColors: {},
      );
      expect(sparse.indicatorColor(TrackIndicator.play), Colors.transparent);
    });

    test('copyWith overrides only the given fields', () {
      final updated = theme.copyWith(recordColor: const Color(0xFFABCDEF));
      expect(updated.recordColor, const Color(0xFFABCDEF));
      expect(updated.waveformColor, theme.waveformColor);
      expect(updated.recordMeterColors, theme.recordMeterColors);
      expect(updated.playMeterColors, theme.playMeterColors);
      expect(updated.indicatorColors, theme.indicatorColors);
    });

    test('copyWith replaces indicatorColors when given', () {
      final updated = theme.copyWith(
        indicatorColors: const {TrackIndicator.idle: Color(0xFF010203)},
      );
      expect(
        updated.indicatorColor(TrackIndicator.idle),
        const Color(0xFF010203),
      );
    });

    test('lerp interpolates toward the other theme', () {
      final other = theme.copyWith(waveformColor: const Color(0xFFFFFFFF));
      final mid = theme.lerp(other, 1);
      expect(mid.waveformColor, const Color(0xFFFFFFFF));
    });

    test('lerp carries indicatorColors toward the other theme', () {
      final other = theme.copyWith(
        indicatorColors: const {
          TrackIndicator.idle: Color(0xFFFFFFFF),
          TrackIndicator.play: Color(0xFFFFFFFF),
          TrackIndicator.record: Color(0xFFFFFFFF),
        },
      );
      final end = theme.lerp(other, 1);
      const white = Color(0xFFFFFFFF);
      expect(end.indicatorColor(TrackIndicator.idle), white);
      expect(end.indicatorColor(TrackIndicator.play), white);
      expect(end.indicatorColor(TrackIndicator.record), white);
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

  group('TrackIndicator.of', () {
    test('muted reads as idle regardless of state, selection, or mode', () {
      for (final state in TrackState.values) {
        expect(
          TrackIndicator.of(
            state,
            muted: true,
            selected: true,
            playMode: false,
          ),
          TrackIndicator.idle,
        );
      }
    });

    test('live transport beats the armed derivation', () {
      // Recording/overdubbing -> record, even when unselected in play mode.
      expect(
        TrackIndicator.of(
          TrackState.recording,
          muted: false,
          selected: false,
          playMode: true,
        ),
        TrackIndicator.record,
      );
      expect(
        TrackIndicator.of(
          TrackState.overdubbing,
          muted: false,
          selected: false,
          playMode: true,
        ),
        TrackIndicator.record,
      );
      // Playing -> play, even when selected in record mode.
      expect(
        TrackIndicator.of(
          TrackState.playing,
          muted: false,
          selected: true,
          playMode: false,
        ),
        TrackIndicator.play,
      );
    });

    test('empty/stopped + selected arms by mode', () {
      for (final state in [TrackState.empty, TrackState.stopped]) {
        expect(
          TrackIndicator.of(
            state,
            muted: false,
            selected: true,
            playMode: false,
          ),
          TrackIndicator.record,
          reason: 'record mode arms red',
        );
        expect(
          TrackIndicator.of(
            state,
            muted: false,
            selected: true,
            playMode: true,
          ),
          TrackIndicator.play,
          reason: 'play mode arms green',
        );
      }
    });

    test('empty/stopped + unselected is idle in either mode', () {
      for (final state in [TrackState.empty, TrackState.stopped]) {
        for (final playMode in [true, false]) {
          expect(
            TrackIndicator.of(
              state,
              muted: false,
              selected: false,
              playMode: playMode,
            ),
            TrackIndicator.idle,
          );
        }
      }
    });
  });

  test('AppTheme maps every meter state in both record and play modes', () {
    final theme = AppTheme.bigPicture.extension<LooperTheme>()!;
    for (final state in LooperMeterState.values) {
      expect(theme.recordMeterColors[state], isNotNull);
      expect(theme.playMeterColors[state], isNotNull);
    }
    expect(AppTheme.bigPicture.useMaterial3, isTrue);
  });

  test('both palettes map every indicator state, idle distinct from tile', () {
    for (final data in [AppTheme.bigPicture, AppTheme.bigPictureHighContrast]) {
      final theme = data.extension<LooperTheme>()!;
      for (final indicator in TrackIndicator.values) {
        expect(theme.indicatorColors[indicator], isNotNull);
      }
      // The idle tone must be distinguishable from the tile surface, or the
      // strip vanishes on inactive tiles.
      expect(
        theme.indicatorColor(TrackIndicator.idle),
        isNot(theme.tileBackground),
      );
    }
  });
}
