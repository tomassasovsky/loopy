import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart' show TrackState;
import 'package:loopy/theme/looper_theme.dart';

/// Track meter (peak bar) color per track state, shared by both themes.
//
// TODO(loopy): fill in the intended color for each track state.
const _trackStateColors = <TrackState, Color>{
  TrackState.empty: Color(0xFF2C313A), // not shown (empty tracks have no bar)
  TrackState.recording: Color(0xFFFF1744),
  TrackState.overdubbing: Color(0xFFFFA000),
  TrackState.playing: Color(0xFF4CDA4A),
  TrackState.stopped: Color(0xFF7E8590),
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
          trackStateColors: _trackStateColors,
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
            Color(0xFF4cda4a), // green
          ],
          tileBackground: Color(0xFF101019),
          tileBorder: Color(0xFF22222E),
          waveformColor: Color(0xFF00E5FF),
          waveformBackground: Color(0xFF06060A),
          recordColor: Color(0xFFFF1744),
          armedColor: Color(0xFFFFD740),
          trackStateColors: _trackStateColors,
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
