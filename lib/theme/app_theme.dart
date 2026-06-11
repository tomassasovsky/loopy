import 'package:flutter/material.dart';
import 'package:loopy/setup/setup_surface.dart';
import 'package:loopy/theme/looper_theme.dart';

/// Track meter (peak bar) color per meter state while in **record** mode.
const _recordMeterColors = <LooperMeterState, Color>{
  LooperMeterState.empty: Color(0xFF2C313A), // not shown (empty = no bar)
  LooperMeterState.recording: Color(0xFFFF1744),
  LooperMeterState.overdubbing: Color(0xFFFF1744),
  LooperMeterState.playing: Color(0xFF4CDA4A),
  LooperMeterState.stopped: Colors.transparent,
  LooperMeterState.muted: Color(0xFFFFFFFF),
};

/// Track meter (peak bar) color per meter state while in **play** mode.
// TODO(loopy): differentiate from record mode as desired.
const _playMeterColors = <LooperMeterState, Color>{
  LooperMeterState.empty: Color(0xFF2C313A),
  LooperMeterState.recording: Color(0xFFFF1744),
  LooperMeterState.overdubbing: Color(0xFFFF1744),
  LooperMeterState.playing: Color(0xFF4CDA4A),
  LooperMeterState.stopped: Color(0xFFFFFFFF),
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
          recordMeterColors: _recordMeterColors,
          playMeterColors: _playMeterColors,
        ),
      ],
    );
  }

  /// Neon-on-near-black performance theme (Chewie-Monsta vibe).
  static ThemeData get bigPicture {
    const scheme = ColorScheme.dark(
      primary: SetupSurfaceColors.t1,
      secondary: SetupSurfaceColors.accent,
      surface: SetupSurfaceColors.surface,
    );
    return _base(scheme).copyWith(
      scaffoldBackgroundColor: const Color(0xFF06060A),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        selectedColor: scheme.primary,
        secondarySelectedColor: scheme.secondary,
        labelStyle: TextStyle(color: scheme.onSurface),
        secondaryLabelStyle: TextStyle(color: scheme.onSecondary),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      extensions: const [
        LooperTheme(
          tileBackground: Color(0xFF101019),
          tileBorder: Color(0xFF22222E),
          waveformColor: Color(0xFF00E5FF),
          waveformBackground: Color(0xFF06060A),
          recordColor: Color(0xFFFF1744),
          recordMeterColors: _recordMeterColors,
          playMeterColors: _playMeterColors,
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
