import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
    );

    test('trackColor cycles through the palette', () {
      expect(theme.trackColor(0), const Color(0xFF000001));
      expect(theme.trackColor(1), const Color(0xFF000002));
      expect(theme.trackColor(2), const Color(0xFF000001));
    });

    test('copyWith overrides only the given fields', () {
      final updated = theme.copyWith(recordColor: const Color(0xFFABCDEF));
      expect(updated.recordColor, const Color(0xFFABCDEF));
      expect(updated.waveformColor, theme.waveformColor);
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

  test('AppTheme exposes a LooperTheme for both modes', () {
    expect(AppTheme.desktop.extension<LooperTheme>(), isNotNull);
    expect(AppTheme.bigPicture.extension<LooperTheme>(), isNotNull);
    expect(AppTheme.bigPicture.useMaterial3, isTrue);
  });
}
