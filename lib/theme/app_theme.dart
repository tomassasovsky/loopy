import 'package:flutter/material.dart';
import 'package:loopy/theme/looper_theme.dart';

/// The two Loopy visual themes: a refined dark-neutral **Desktop** theme for
/// the working layout, and a high-contrast neon-on-black **Big Picture** theme
/// for the performance/visualizer windows.
abstract final class AppTheme {
  /// Dark-neutral desktop theme with a single teal accent.
  static ThemeData get desktop {
    const seed = Color(0xFF1FB6A6);
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );
    return _base(scheme).copyWith(
      extensions: const [
        LooperTheme(
          trackColors: [
            Color(0xFF26C6DA), // teal
            Color(0xFF7E9CFF), // indigo
            Color(0xFFFFCA56), // amber
            Color(0xFFFF8A80), // rose
          ],
          tileBackground: Color(0xFF1B1E24),
          tileBorder: Color(0xFF2C313A),
          waveformColor: Color(0xFF35D6C4),
          waveformBackground: Color(0xFF14161B),
          recordColor: Color(0xFFFF5252),
          armedColor: Color(0xFFFFB74D),
        ),
      ],
    );
  }

  /// Neon-on-near-black performance theme (Chewie-Monsta vibe).
  static ThemeData get bigPicture {
    const scheme = ColorScheme.dark(
      primary: Color(0xFF00E5FF),
      secondary: Color(0xFFFF2D95),
      surface: Color(0xFF0C0C12),
    );
    return _base(scheme).copyWith(
      scaffoldBackgroundColor: const Color(0xFF06060A),
      extensions: const [
        LooperTheme(
          trackColors: [
            Color(0xFF00E5FF), // cyan
            Color(0xFFFF2D95), // magenta
            Color(0xFFB6FF00), // lime
            Color(0xFFFF9100), // orange
          ],
          tileBackground: Color(0xFF101019),
          tileBorder: Color(0xFF22222E),
          waveformColor: Color(0xFF00E5FF),
          waveformBackground: Color(0xFF06060A),
          recordColor: Color(0xFFFF1744),
          armedColor: Color(0xFFFFD740),
        ),
      ],
    );
  }

  static ThemeData _base(ColorScheme scheme) => ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    appBarTheme: AppBarTheme(backgroundColor: scheme.surfaceContainerHighest),
  );
}
