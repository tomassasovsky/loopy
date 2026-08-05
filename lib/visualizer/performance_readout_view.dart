import 'package:flutter/material.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/performance_readout.dart';

/// The 7" screen's permanent performance surface: what every track is doing,
/// the tempo, and what a footswitch press means right now — with the waveform
/// as one region rather than the whole window.
///
/// This is what makes the near-fullscreen settings tray acceptable on the
/// 16": you can configure mid-set without losing sight of the loop. It is
/// therefore deliberately RIGID — it shows the same thing no matter what the
/// other screen is doing (#442, decision D7).
class PerformanceReadoutView extends StatelessWidget {
  /// Creates a [PerformanceReadoutView].
  const PerformanceReadoutView({
    required this.readout,
    required this.waveform,
    super.key,
  });

  /// Live state pushed from the main window.
  final PerformanceReadout readout;

  /// The waveform region, injected so this widget stays pure presentation.
  final Widget waveform;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReadoutHeader(readout: readout),
        const SizedBox(height: 12),
        Expanded(flex: 3, child: waveform),
        const SizedBox(height: 12),
        Expanded(
          flex: 2,
          child: _TrackStrip(tracks: readout.tracks),
        ),
      ],
    );
  }
}

/// Tempo, metre, loop length and the current interaction mode.
class _ReadoutHeader extends StatelessWidget {
  const _ReadoutHeader({required this.readout});

  final PerformanceReadout readout;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final tempo = readout.tempoBpm > 0
        ? readout.tempoBpm.toStringAsFixed(readout.tempoBpm % 1 == 0 ? 0 : 1)
        : '--';

    return Row(
      children: [
        _Stat(
          key: const Key('readout_tempo'),
          label: l10n.readoutTempoLabel,
          value: '$tempo  ${readout.tsNum}/${readout.tsDen}',
          emphasised: readout.isRunning,
        ),
        const SizedBox(width: 16),
        if (readout.loopBars > 0)
          _Stat(
            key: const Key('readout_bars'),
            label: l10n.readoutBarsLabel,
            value: '${readout.loopBars}',
          ),
        const Spacer(),
        // The mode chip is the readout's most load-bearing element: it is the
        // answer to "what does stepping on a track switch do right now".
        DecoratedBox(
          key: const Key('readout_mode'),
          decoration: BoxDecoration(
            color: surface.accent.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(SurfaceTheme.radius10),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              _modeLabel(l10n, readout.mode),
              style: TextStyle(
                color: surface.accent,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Maps `InteractionMode.token` to its display name.
  ///
  /// A token rather than the enum because the payload crossed a method
  /// channel; an unknown token renders verbatim rather than guessing, so a
  /// newer main window paired with an older sub-window degrades to showing
  /// the raw mode instead of lying about it.
  static String _modeLabel(AppLocalizations l10n, String token) =>
      switch (token) {
        'record' => l10n.readoutModeRecord,
        'mute' => l10n.readoutModeMute,
        'fx' => l10n.readoutModeFx,
        _ => token.toUpperCase(),
      };
}

/// One labelled figure in the header.
class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    this.emphasised = false,
    super.key,
  });

  final String label;
  final String value;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            color: surface.textTertiary,
            fontSize: 10,
            letterSpacing: 0.6,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: emphasised ? surface.textPrimary : surface.textSecondary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// One cell per track, coloured by what it is doing.
class _TrackStrip extends StatelessWidget {
  const _TrackStrip({required this.tracks});

  final List<ReadoutTrack> tracks;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        for (final (index, track) in tracks.indexed) ...[
          if (index > 0) const SizedBox(width: 8),
          Expanded(child: _TrackCell(track: track)),
        ],
      ],
    );
  }
}

/// A single track's state, readable from across a stage.
class _TrackCell extends StatelessWidget {
  const _TrackCell({required this.track});

  final ReadoutTrack track;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final tint = _tint(surface, track);

    return Semantics(
      label: '${track.name}, ${_stateLabel(l10n, track)}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tint.withValues(alpha: track.state == 'empty' ? 0.06 : 0.2),
          borderRadius: BorderRadius.circular(SurfaceTheme.radius12),
          border: Border.all(
            // A pending (quantized) action is the one thing worth an outline:
            // it is about to happen and nothing else on screen says so.
            color: track.pending
                ? surface.accent
                : tint.withValues(alpha: track.selected ? 0.8 : 0.15),
            width: track.pending || track.selected ? 2 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                track.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: surface.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              Text(
                _stateLabel(l10n, track),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: tint,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Color _tint(SurfaceTheme surface, ReadoutTrack track) {
    if (track.muted) return surface.textTertiary;
    return switch (track.state) {
      'recording' => surface.ledRed,
      'overdubbing' => surface.ledAmber,
      'playing' => surface.ledGreen,
      // Brighter than [empty]'s tertiary: a stopped track still HOLDS audio,
      // and rendering it identically to a never-recorded one is the readout
      // lying about the one thing it exists to report.
      'stopped' => surface.textSecondary,
      _ => surface.textTertiary,
    };
  }

  static String _stateLabel(AppLocalizations l10n, ReadoutTrack track) {
    if (track.pending) return l10n.readoutStatePending;
    if (track.muted) return l10n.readoutStateMuted;
    return switch (track.state) {
      'recording' => l10n.readoutStateRecording,
      'overdubbing' => l10n.readoutStateOverdubbing,
      'playing' => l10n.readoutStatePlaying,
      'stopped' => l10n.readoutStateStopped,
      _ => l10n.readoutStateEmpty,
    };
  }
}
