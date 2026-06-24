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
// TODO(loopy): differentiate from record mode as desired.
const _playMeterColors = <LooperMeterState, Color>{
  LooperMeterState.empty: Color(0xFF2C313A),
  LooperMeterState.recording: Color(0xFFFF1744),
  LooperMeterState.overdubbing: Color(0xFFFF1744),
  LooperMeterState.playing: Color(0xFF4CDA4A),
  LooperMeterState.stopped: Color(0xFFFFFFFF),
  LooperMeterState.muted: Color(0xFFFFFFFF),
};

/// Track meter (peak bar) colors per meter state in the **high-contrast**
/// theme: the empty/idle tone clears the 3:1 non-text threshold (1.4.11)
/// against the brighter tile, and play/record stay vivid.
const _hcRecordMeterColors = <LooperMeterState, Color>{
  LooperMeterState.empty: Color(0xFF6B6D78),
  LooperMeterState.recording: Color(0xFFFF5470),
  LooperMeterState.overdubbing: Color(0xFFFF5470),
  LooperMeterState.playing: Color(0xFF6EE77F),
  LooperMeterState.stopped: Colors.transparent,
  LooperMeterState.muted: Color(0xFFFFFFFF),
};

const _hcPlayMeterColors = <LooperMeterState, Color>{
  LooperMeterState.empty: Color(0xFF6B6D78),
  LooperMeterState.recording: Color(0xFFFF5470),
  LooperMeterState.overdubbing: Color(0xFFFF5470),
  LooperMeterState.playing: Color(0xFF6EE77F),
  LooperMeterState.stopped: Color(0xFFFFFFFF),
  LooperMeterState.muted: Color(0xFFFFFFFF),
};

/// Per-track status-indicator colors: a dim `idle` that still reads above the
/// tile surface, reusing the meter green/red for the play/record states.
const _indicatorColors = <TrackIndicator, Color>{
  TrackIndicator.idle: Color(0xFF3A3F49), // dim, above tileBackground
  TrackIndicator.play: Color(0xFF4CDA4A), // meter green
  TrackIndicator.record: Color(0xFFFF1744), // meter red
};

/// High-contrast status-indicator colors: `idle` reuses the brighter HC
/// "empty" tone so it clears the 3:1 non-text threshold (1.4.11) against the
/// brighter tile, and play/record stay vivid.
const _hcIndicatorColors = <TrackIndicator, Color>{
  TrackIndicator.idle: Color(0xFF6B6D78),
  TrackIndicator.play: Color(0xFF6EE77F),
  TrackIndicator.record: Color(0xFFFF5470),
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
    return _themed(
      scheme: scheme,
      scaffoldBackground: const Color(0xFF06060A),
      surface: SurfaceTheme.dark,
      looper: const LooperTheme(
        tileBackground: Color(0xFF101019),
        tileBorder: Color(0xFF22222E),
        waveformColor: Color(0xFF00E5FF),
        waveformBackground: Color(0xFF06060A),
        recordColor: Color(0xFFFF1744),
        recordMeterColors: _recordMeterColors,
        playMeterColors: _playMeterColors,
        indicatorColors: _indicatorColors,
      ),
    );
  }

  /// High-contrast counterpart of [bigPicture], wired into
  /// `MaterialApp.highContrastTheme` so the OS high-contrast preference
  /// (macOS Increase Contrast / Windows High Contrast) swaps the palette for
  /// brighter text, tile borders, and meters (WCAG 1.4.3 / 1.4.11).
  static ThemeData get bigPictureHighContrast {
    const scheme = ColorScheme.highContrastDark(
      primary: Color(0xFFFFFFFF), // SurfaceTheme.highContrast.textPrimary
      secondary: Color(0xFF6BA8FF), // SurfaceTheme.highContrast.accent
      surface: Color(0xFF000000),
    );
    return _themed(
      scheme: scheme,
      scaffoldBackground: const Color(0xFF000000),
      surface: SurfaceTheme.highContrast,
      looper: const LooperTheme(
        tileBackground: Color(0xFF0A0A12),
        tileBorder: Color(0xFF7A7C88),
        waveformColor: Color(0xFF4DEEFF),
        waveformBackground: Color(0xFF000000),
        recordColor: Color(0xFFFF5470),
        recordMeterColors: _hcRecordMeterColors,
        playMeterColors: _hcPlayMeterColors,
        indicatorColors: _hcIndicatorColors,
      ),
    );
  }

  static ThemeData _themed({
    required ColorScheme scheme,
    required Color scaffoldBackground,
    required SurfaceTheme surface,
    required LooperTheme looper,
  }) => _base(scheme).copyWith(
    scaffoldBackgroundColor: scaffoldBackground,
    chipTheme: ChipThemeData(
      backgroundColor: scheme.surfaceContainerHighest,
      selectedColor: scheme.primary,
      secondarySelectedColor: scheme.secondary,
      labelStyle: TextStyle(color: scheme.onSurface),
      secondaryLabelStyle: TextStyle(color: scheme.onSecondary),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    ),
    extensions: [
      looper,
      surface,
      routingGraphThemeFromSurface(surface),
    ],
  );

  static ThemeData _base(ColorScheme scheme) => ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: SurfaceTheme.displayFont,
    appBarTheme: AppBarTheme(backgroundColor: scheme.surfaceContainerHighest),
  );
}
