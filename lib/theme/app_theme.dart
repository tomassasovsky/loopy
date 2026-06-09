import 'package:flutter/material.dart';
import 'package:loopy/theme/looper_theme.dart';

/// The track meter (peak bar) color for every meter state, shared by both
/// themes. One table — muted overlays the others and is just another entry.
const _meterColors = <LooperMeterState, Color>{
  LooperMeterState.empty: Color(0xFF2C313A), // not shown (empty = no bar)
  LooperMeterState.recording: Color(0xFFFF1744),
  LooperMeterState.overdubbing: Color(0xFFFF1744),
  LooperMeterState.playing: Color(0xFF4CDA4A),
  LooperMeterState.stopped: Colors.transparent,
  LooperMeterState.muted: Color(0xFFFFFFFF),
};

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
          tileBackground: Color(0xFF1B1E24),
          tileBorder: Color(0xFF2C313A),
          waveformColor: Color(0xFF35D6C4),
          waveformBackground: Color(0xFF14161B),
          recordColor: Color(0xFFFF5252),
          meterColors: _meterColors,
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
          tileBackground: Color(0xFF101019),
          tileBorder: Color(0xFF22222E),
          waveformColor: Color(0xFF00E5FF),
          waveformBackground: Color(0xFF06060A),
          recordColor: Color(0xFFFF1744),
          meterColors: _meterColors,
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
