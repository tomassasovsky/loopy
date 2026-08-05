import 'package:routing_graph/routing_graph.dart';
import 'package:segno/theme/looper_theme.dart';
import 'package:segno/theme/page_transitions.dart';
import 'package:segno/theme/surface_theme.dart';

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
  LooperMeterState.empty: Color(0xFF2E2E31), // not shown (empty = no bar)
  LooperMeterState.recording: Color(0xFFFF1744),
  LooperMeterState.overdubbing: Color(0xFFFF1744),
  LooperMeterState.playing: Color(0xFF4CDA4A),
  // A stopped loop holds its frozen level; show it (white) rather than hiding
  // the bar, so a loaded-but-paused track stays visible after a stop.
  LooperMeterState.stopped: Color(0xFFFFFFFF),
  LooperMeterState.muted: Color(0xFFFFFFFF),
};

/// Track meter (peak bar) color per meter state while in **mute** mode.
const _muteMeterColors = <LooperMeterState, Color>{
  LooperMeterState.empty: Color(0xFF2E2E31),
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
  LooperMeterState.empty: Color(0xFF6E6E6E),
  LooperMeterState.recording: Color(0xFFFF5470),
  LooperMeterState.overdubbing: Color(0xFFFF5470),
  LooperMeterState.playing: Color(0xFF6EE77F),
  // Visible frozen-level bar for a stopped loop (matches the mute table).
  LooperMeterState.stopped: Color(0xFFFFFFFF),
  LooperMeterState.muted: Color(0xFFFFFFFF),
};

const _hcMuteMeterColors = <LooperMeterState, Color>{
  LooperMeterState.empty: Color(0xFF6E6E6E),
  LooperMeterState.recording: Color(0xFFFF5470),
  LooperMeterState.overdubbing: Color(0xFFFF5470),
  LooperMeterState.playing: Color(0xFF6EE77F),
  LooperMeterState.stopped: Color(0xFFFFFFFF),
  LooperMeterState.muted: Color(0xFFFFFFFF),
};

/// Waveform stroke color per meter state.
///
/// The design system's decided reading of this surface (#499): the waveform is
/// part of the transport legend, not a fixed brand accent, so it reuses the
/// same stage colours the meters and pedal LEDs already speak — recording red,
/// playing green, stopped white. The retired single cyan (`0xFF00E5FF`) said
/// only "this is a waveform".
///
/// The three not-sounding states share one white, dimmed by alpha rather than
/// split into hues: `empty` and `stopped` are both "this track is not playing"
/// and read identically, while `muted` dims further to say it was silenced on
/// purpose. Spending a hue on them would imply a distinction the transport does
/// not make. Every state clears 3:1 against [LooperTheme.waveformBackground]
/// (asserted in `test/theme/`) — a waveform is a non-text component (WCAG
/// 1.4.11).
///
/// `empty` deliberately does *not* borrow the meter's dim empty groove, even
/// though every other state matches the meter table. The meter can afford a
/// near-invisible empty because it draws no bar there; this surface paints the
/// **mixed output**, so it still has a full waveform to show while the cursor
/// track itself is empty — parking the cursor on a fresh track mid-performance
/// would black out the mix.
const _waveformColors = <LooperMeterState, Color>{
  LooperMeterState.empty: Color(0xB3FFFFFF),
  LooperMeterState.recording: Color(0xFFFF1744),
  LooperMeterState.overdubbing: Color(0xFFFF1744),
  LooperMeterState.playing: Color(0xFF4CDA4A),
  LooperMeterState.stopped: Color(0xB3FFFFFF),
  LooperMeterState.muted: Color(0x66FFFFFF),
};

/// High-contrast waveform colors: the same legend with the HC state pair
/// (`0xFFFF5470` / `0xFF6EE77F`) and the dim tones lifted — stopped goes fully
/// opaque and muted takes the alpha stopped used to, so the "not sounding"
/// pair stays distinguishable without either dropping under the 3:1 floor.
const _hcWaveformColors = <LooperMeterState, Color>{
  LooperMeterState.empty: Color(0xFFFFFFFF),
  LooperMeterState.recording: Color(0xFFFF5470),
  LooperMeterState.overdubbing: Color(0xFFFF5470),
  LooperMeterState.playing: Color(0xFF6EE77F),
  LooperMeterState.stopped: Color(0xFFFFFFFF),
  LooperMeterState.muted: Color(0x99FFFFFF),
};

/// Per-track status-indicator colors: a dim `idle` that still reads above the
/// tile surface, reusing the meter green/red for the play/record states.
const _indicatorColors = <TrackIndicator, Color>{
  TrackIndicator.idle: Color(0xFF3D3F43), // dim, above tileBackground
  TrackIndicator.play: Color(0xFF4CDA4A), // meter green
  TrackIndicator.record: Color(0xFFFF1744), // meter red
};

/// High-contrast status-indicator colors: `idle` reuses the brighter HC
/// "empty" tone so it clears the 3:1 non-text threshold (1.4.11) against the
/// brighter tile, and play/record stay vivid.
const _hcIndicatorColors = <TrackIndicator, Color>{
  TrackIndicator.idle: Color(0xFF6E6E6E),
  TrackIndicator.play: Color(0xFF6EE77F),
  TrackIndicator.record: Color(0xFFFF5470),
};

/// Segno's visual themes — named for their palettes, not for any screen or
/// mode they happen to dress.
abstract final class AppTheme {
  /// The default **Neon** theme: neon-on-near-black (Chewie-Monsta vibe).
  static ThemeData get neon {
    const scheme = ColorScheme.dark(
      primary: Color(0xFFF3F4F7), // SurfaceTheme.dark.textPrimary
      secondary: Color(0xFF3B82F6), // SurfaceTheme.dark.accent
      surface: Color(0xFF141417), // SurfaceTheme.dark.surface
    );
    return _themed(
      scheme: scheme,
      scaffoldBackground: const Color(0xFF060607),
      surface: SurfaceTheme.dark,
      looper: const LooperTheme(
        tileBackground: Colors.black,
        tileBorder: Color(0xFF17171B),
        waveformColors: _waveformColors,
        waveformBackground: Color(0xFF060607),
        recordColor: Color(0xFFFF1744),
        fxColor: Color(0xFF3B82F6),
        recordMeterColors: _recordMeterColors,
        muteMeterColors: _muteMeterColors,
        indicatorColors: _indicatorColors,
        toolbarIconColor: Colors.white70,
      ),
    );
  }

  /// High-contrast counterpart of [neon], wired into
  /// `MaterialApp.highContrastTheme` so the OS high-contrast preference
  /// (macOS Increase Contrast / Windows High Contrast) swaps the palette for
  /// brighter text, tile borders, and meters (WCAG 1.4.3 / 1.4.11).
  static ThemeData get highContrast {
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
        tileBackground: Color(0xFF0A0A0B),
        tileBorder: Color(0xFF7A7A80),
        waveformColors: _hcWaveformColors,
        waveformBackground: Color(0xFF000000),
        recordColor: Color(0xFFFF5470),
        fxColor: Color(0xFF6BA8FF),
        recordMeterColors: _hcRecordMeterColors,
        muteMeterColors: _hcMuteMeterColors,
        indicatorColors: _hcIndicatorColors,
        // SurfaceTheme.highContrast.textSecondary — brighter than the neon
        // theme's white70 to clear the HC contrast threshold.
        toolbarIconColor: Color(0xFFD8D8D8),
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
    // The design system's hover/pressed tiers as the app-wide ink defaults, so
    // stock InkWells answer the pointer without each call site restating it
    // (#499). Widgets that paint their own state layer — the setup option
    // cards — resolve the same tokens directly.
    hoverColor: surface.borderHairline,
    highlightColor: surface.borderSubtle,
    focusColor: surface.accent.withValues(alpha: 0.24),
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
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeScalePageTransitionsBuilder(),
        TargetPlatform.iOS: FadeScalePageTransitionsBuilder(),
        TargetPlatform.macOS: FadeScalePageTransitionsBuilder(),
        TargetPlatform.windows: FadeScalePageTransitionsBuilder(),
        TargetPlatform.linux: FadeScalePageTransitionsBuilder(),
        TargetPlatform.fuchsia: FadeScalePageTransitionsBuilder(),
      },
    ),
  );
}
