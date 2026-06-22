import 'package:loopy/theme/looper_theme.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

/// Maps the app's neutral [SurfaceTheme] tokens onto the structural tokens the
/// `routing_graph` package reads via `context.routingGraph`, so the graphs
/// share the setup surface's palette without the package depending on the app.
///
/// The single source of truth for the mapping — both [AppTheme] variants and
/// the golden tests register the result of this, so the two themes can never
/// drift apart.
RoutingGraphTheme routingGraphThemeFromSurface(SurfaceTheme s) =>
    RoutingGraphTheme(
      background: s.background,
      surface: s.surface,
      card: s.card,
      cardHigh: s.cardHigh,
      line: s.line,
      textPrimary: s.textPrimary,
      textSecondary: s.textSecondary,
      textTertiary: s.textTertiary,
    );

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
const _playMeterColors = <LooperMeterState, Color>{
  LooperMeterState.empty: Color(0xFF2C313A),
  LooperMeterState.recording: Color(0xFFFF1744),
  LooperMeterState.overdubbing: Color(0xFFFF1744),
  LooperMeterState.playing: Color(0xFF4CDA4A),
  LooperMeterState.stopped: Color(0xFFFFFFFF),
  LooperMeterState.muted: Color(0xFFFFFFFF),
};

/// Loopy's visual theme: a high-contrast neon-on-black **Big Picture** theme
/// for the performance/visualizer windows.
abstract final class AppTheme {
  /// Neon-on-near-black performance theme (Chewie-Monsta vibe).
  static ThemeData get bigPicture {
    const scheme = ColorScheme.dark(
      primary: Color(0xFFF3F4F7), // SurfaceTheme.dark.textPrimary
      secondary: Color(0xFF3B82F6), // SurfaceTheme.dark.accent
      surface: Color(0xFF0D0D11), // SurfaceTheme.dark.surface
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
      extensions: [
        const LooperTheme(
          tileBackground: Color(0xFF101019),
          tileBorder: Color(0xFF22222E),
          waveformColor: Color(0xFF00E5FF),
          waveformBackground: Color(0xFF06060A),
          recordColor: Color(0xFFFF1744),
          recordMeterColors: _recordMeterColors,
          playMeterColors: _playMeterColors,
        ),
        SurfaceTheme.dark,
        routingGraphThemeFromSurface(SurfaceTheme.dark),
      ],
    );
  }

  static ThemeData _base(ColorScheme scheme) => ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    appBarTheme: AppBarTheme(backgroundColor: scheme.surfaceContainerHighest),
  );
}
