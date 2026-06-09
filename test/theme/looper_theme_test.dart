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
      trackStateColors: {
        TrackState.recording: Color(0xFFFF0000),
        TrackState.playing: Color(0xFF00FF00),
      },
    );

    test('trackColor cycles through the palette', () {
      expect(theme.trackColor(0), const Color(0xFF000001));
      expect(theme.trackColor(1), const Color(0xFF000002));
      expect(theme.trackColor(2), const Color(0xFF000001));
    });

    test('barColor maps a state, falling back to the track accent', () {
      expect(theme.barColor(TrackState.playing, 0), const Color(0xFF00FF00));
      expect(theme.barColor(TrackState.recording, 1), const Color(0xFFFF0000));
      // Unmapped state -> the track accent for the channel.
      expect(theme.barColor(TrackState.stopped, 1), const Color(0xFF000002));
    });

    test('copyWith overrides only the given fields', () {
      final updated = theme.copyWith(recordColor: const Color(0xFFABCDEF));
      expect(updated.recordColor, const Color(0xFFABCDEF));
      expect(updated.waveformColor, theme.waveformColor);
      expect(updated.trackStateColors, theme.trackStateColors);
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

  test('AppTheme maps every track state to a meter color in both modes', () {
    final desktop = AppTheme.desktop.extension<LooperTheme>()!;
    final big = AppTheme.bigPicture.extension<LooperTheme>()!;
    for (final state in TrackState.values) {
      expect(desktop.trackStateColors[state], isNotNull);
      expect(big.trackStateColors[state], isNotNull);
    }
    expect(AppTheme.bigPicture.useMaterial3, isTrue);
  });
}
