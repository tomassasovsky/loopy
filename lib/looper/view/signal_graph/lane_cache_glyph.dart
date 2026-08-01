import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/view/signal_graph/signal_style.dart';
import 'package:loopy/theme/surface_theme.dart';

/// A one-character debug glyph reporting a lane's Loop-stage wet-cache state
/// (R27).
///
/// This is the wet cache's ONLY UI surface, and it is deliberately tiny and
/// deliberately hidden: the cache is invisible in the signal contract ("when
/// in doubt, play live"), so a listener never needs to know what it is doing,
/// and putting a busy indicator on every lane card would clutter the calm
/// default view for no musical reason. It appears only while the existing
/// per-track indicator preference is on — the same toggle that reveals the
/// readiness strip on the track tiles.
///
/// A `null` [state] renders nothing at all: that means telemetry is off and
/// this lane was never polled, which is not the same as "playing live". That
/// null IS the visibility gate — `LooperRepository.cacheTelemetryEnabled`,
/// wired to the indicator preference in `app.dart`, is what decides whether a
/// lane carries a state at all — so this widget needs no preference lookup of
/// its own and the Signal surface takes on no dependency for it.
class LaneCacheGlyph extends StatelessWidget {
  /// Creates a [LaneCacheGlyph].
  const LaneCacheGlyph({required this.state, super.key});

  /// The lane's cache state, or `null` when it was never observed.
  final LaneCacheState? state;

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    if (state == null) return const SizedBox.shrink();
    final surface = context.surface;
    final l10n = context.l10n;

    final (glyph, color, label) = switch (state) {
      LaneCacheState.live => (
        '–',
        surface.textTertiary,
        l10n.a11yCacheStateLive,
      ),
      LaneCacheState.rendering => (
        '⟳',
        surface.textSecondary,
        l10n.a11yCacheStateRendering,
      ),
      LaneCacheState.cached => (
        '●',
        surface.accent,
        l10n.a11yCacheStateCached,
      ),
      LaneCacheState.failedRetrying => (
        '!',
        surface.warning,
        l10n.a11yCacheStateFailedRetrying,
      ),
      // Permanently live is a settled, unremarkable outcome (a chain hosting a
      // plugin can never render offline), so it reads as dimmed-out rather
      // than as the warning `failedRetrying` gets.
      LaneCacheState.gaveUp => (
        '✕',
        surface.textTertiary,
        l10n.a11yCacheStateGaveUp,
      ),
    };

    return Semantics(
      label: label,
      // The glyph itself is decoration: without this a screen reader would
      // announce the label AND read the bare character after it.
      excludeSemantics: true,
      child: Text(
        glyph,
        style: signalMono(color: color, size: 11.5),
      ),
    );
  }
}
