import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart' show TrackState;
import 'package:loopy/theme/theme.dart';

void main() {
  group('LooperTheme', () {
    const theme = LooperTheme(
      trackColors: [Color(0xFF000001), Color(0xFF000002)],
      tileBackground: Color(0xFF111111),
      tileBorder: Color(0xFF222222),
      waveformColor: Color(0xFF00E5FF),
      waveformBackground: Color(0xFF000000),
      recordColor: Color(0xFFFF1744),
      armedColor: Color(0xFFFFD740),
      meterColors: {
        LooperMeterState.recording: Color(0xFFFF0000),
        LooperMeterState.playing: Color(0xFF00FF00),
        LooperMeterState.muted: Color(0xFFFFFFFF),
      },
    );

    test('trackColor cycles through the palette', () {
      expect(theme.trackColor(0), const Color(0xFF000001));
      expect(theme.trackColor(1), const Color(0xFF000002));
      expect(theme.trackColor(2), const Color(0xFF000001));
    });

    test('meterColor looks up the meter state in the table', () {
      expect(
        theme.meterColor(LooperMeterState.playing),
        const Color(0xFF00FF00),
      );
      expect(
        theme.meterColor(LooperMeterState.recording),
        const Color(0xFFFF0000),
      );
      expect(theme.meterColor(LooperMeterState.muted), const Color(0xFFFFFFFF));
      // A state the table omits resolves to transparent.
      expect(theme.meterColor(LooperMeterState.stopped), Colors.transparent);
    });

    test('copyWith overrides only the given fields', () {
      final updated = theme.copyWith(recordColor: const Color(0xFFABCDEF));
      expect(updated.recordColor, const Color(0xFFABCDEF));
      expect(updated.waveformColor, theme.waveformColor);
      expect(updated.meterColors, theme.meterColors);
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

  test('AppTheme maps every meter state to a color in both modes', () {
    final desktop = AppTheme.desktop.extension<LooperTheme>()!;
    final big = AppTheme.bigPicture.extension<LooperTheme>()!;
    for (final state in LooperMeterState.values) {
      expect(desktop.meterColors[state], isNotNull);
      expect(big.meterColors[state], isNotNull);
    }
    expect(AppTheme.bigPicture.useMaterial3, isTrue);
  });
}
