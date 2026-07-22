import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/cubit/high_contrast_cubit.dart';
import 'package:loopy/looper/cubit/refresh_rate_cubit.dart';
import 'package:loopy/looper/cubit/tracks_cubit.dart';
import 'package:loopy/looper/model/interaction_mode.dart';
import 'package:loopy/looper/view/rename_track_dialog.dart';
import 'package:loopy/setup/setup_surface.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:loopy/visualizer/visualizer.dart';

/// A settings section, shown one at a time and selected from the left rail.
enum _Section { view, audio, tracks }

/// The app settings page, reachable from the Tracks view via right-click or
/// the `S` key, and from the system menu bar on macOS.
///
/// Laid out like the audio onboarding panel: a dark centered surface with a
/// left rail that selects a section, and a scrollable right pane of the
/// selected section's controls. `Esc` closes the page.
class SettingsPage extends StatefulWidget {
  /// Creates a [SettingsPage].
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  _Section _section = _Section.view;

  void _select(_Section section) => setState(() => _section = section);

  @override
  Widget build(BuildContext context) {
    // Esc closes settings. The rename dialog is a separate route pushed on top,
    // so its own focus scope handles Esc first — this never swallows it.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(Navigator.of(context).maybePop()),
      },
      child: Focus(
        autofocus: true,
        // Full-bleed: a full-screen Scaffold (supplying the Material ancestor
        // the rail's ink taps need) instead of the old centered 940×640 panel.
        // CallbackShortcuts + Focus stay outside it so Esc still closes.
        child: Scaffold(
          backgroundColor: context.surface.background,
          body: Stack(
            fit: StackFit.expand,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 264,
                    child: _SettingsRail(
                      current: _section,
                      onSelect: _select,
                    ),
                  ),
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: context.surface.line,
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      key: ValueKey(_section),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(34, 34, 30, 26),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: _sectionChildren(context),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              Positioned(
                top: 10,
                right: 10,
                child: IconButton(
                  key: const Key('settings_close_button'),
                  tooltip: context.l10n.close,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.close,
                    size: 18,
                    color: context.surface.textSecondary,
                  ),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _sectionChildren(BuildContext context) => switch (_section) {
    _Section.view => _viewSection(context),
    _Section.audio => _audioSection(context),
    _Section.tracks => _tracksSection(context),
  };

  List<Widget> _viewSection(BuildContext context) {
    final l10n = context.l10n;
    final waveformEnabled = context.watch<WaveformWindowCubit>().state;
    final highContrast = context.watch<HighContrastCubit>().state;
    final tracks = context.watch<TracksCubit>().state;
    final showIndicators = tracks.showIndicators;
    // The default mode is a looper-wide behavior default, owned by the shared
    // control overlay (the InteractionMode's home), not a view preference.
    final defaultMode = context.watch<ControlCubit>().state.defaultMode;
    final refreshHz = context.watch<RefreshRateCubit>().state;
    return [
      Text(l10n.settingsViewIntro, style: setupBody),
      const SizedBox(height: 28),
      SetupGroupLabel(l10n.viewGroupLabel),
      const SizedBox(height: 12),
      SetupToggleRow(
        toggleKey: const Key('settings_waveformWindow_switch'),
        title: l10n.waveformWindowTitle,
        subtitle: l10n.waveformWindowSubtitle,
        value: waveformEnabled,
        onChanged: (on) =>
            context.read<WaveformWindowCubit>().setEnabled(value: on),
      ),
      const SizedBox(height: 12),
      SetupToggleRow(
        toggleKey: const Key('settings_highContrast_switch'),
        title: l10n.highContrastTitle,
        subtitle: l10n.highContrastSubtitle,
        value: highContrast,
        onChanged: (on) =>
            unawaited(context.read<HighContrastCubit>().setEnabled(value: on)),
      ),
      const SizedBox(height: 12),
      SetupToggleRow(
        toggleKey: const Key('settings_trackIndicators_switch'),
        title: l10n.trackIndicatorsTitle,
        subtitle: l10n.trackIndicatorsSubtitle,
        value: showIndicators,
        onChanged: (on) => unawaited(
          context.read<TracksCubit>().setShowIndicators(value: on),
        ),
      ),
      const SizedBox(height: 28),
      SetupGroupLabel(l10n.looperGroupLabel),
      const SizedBox(height: 12),
      Text(l10n.defaultModeIntro, style: setupBody),
      const SizedBox(height: 12),
      SetupOptionRow<InteractionMode>(
        selected: defaultMode,
        onSelected: (m) => context.read<ControlCubit>().setDefaultMode(m),
        options: [
          SetupOption(
            value: InteractionMode.record,
            label: l10n.recordModeLabel,
            sub: l10n.recordModeSub,
            optionKey: const Key('settings_defaultMode_record'),
          ),
          SetupOption(
            value: InteractionMode.play,
            label: l10n.playModeLabel,
            sub: l10n.playModeSub,
            optionKey: const Key('settings_defaultMode_play'),
          ),
        ],
      ),
      const SizedBox(height: 20),
      Text(l10n.refreshRateIntro, style: setupBody),
      const SizedBox(height: 12),
      SetupOptionRow<int>(
        selected: refreshHz,
        onSelected: (hz) =>
            unawaited(context.read<RefreshRateCubit>().setHz(hz)),
        options: [
          for (final hz in RefreshRateCubit.options)
            SetupOption(
              value: hz,
              label: l10n.refreshRateHz(hz),
              sub: switch (hz) {
                30 => l10n.refreshRateLowCpu,
                120 => l10n.refreshRateSmoothest,
                _ => l10n.defaultLabel,
              },
              optionKey: Key('settings_refreshRate_$hz'),
            ),
        ],
      ),
    ];
  }

  List<Widget> _audioSection(BuildContext context) => const [
    AudioSettingsSection(),
  ];

  List<Widget> _tracksSection(BuildContext context) {
    final l10n = context.l10n;
    final tracks = context.watch<TracksCubit>();
    return [
      Text(l10n.tracksIntro, style: setupBody),
      const SizedBox(height: 28),
      SetupGroupLabel(l10n.tracksGroupLabel),
      const SizedBox(height: 12),
      for (var i = 0; i < tracks.state.names.length; i++) ...[
        SetupTrackNameRow(
          rowKey: Key('settings_trackName_$i'),
          channel: i,
          name: l10n.displayTrackName(tracks.state.names[i], i),
          onTap: () => showRenameTrackDialog(
            context: context,
            cubit: context.read<TracksCubit>(),
            channel: i,
            current: tracks.state.names[i],
          ),
        ),
        if (i < tracks.state.names.length - 1) const SizedBox(height: 8),
      ],
    ];
  }
}

class _SettingsRail extends StatelessWidget {
  const _SettingsRail({required this.current, required this.onSelect});

  final _Section current;
  final ValueChanged<_Section> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 32, 22, 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: context.surface.accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 9),
              Text(
                l10n.settingsKicker,
                style: setupKicker.copyWith(
                  color: context.surface.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Text(l10n.settingsTitle, style: setupTitle),
          const SizedBox(height: 20),
          for (final section in _Section.values)
            _SectionTab(
              section: section,
              selected: section == current,
              onTap: () => onSelect(section),
            ),
        ],
      ),
    );
  }
}

class _SectionTab extends StatelessWidget {
  const _SectionTab({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final _Section section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label = switch (section) {
      _Section.view => l10n.settingsSectionView,
      _Section.audio => l10n.settingsSectionAudio,
      _Section.tracks => l10n.settingsSectionTracks,
    };
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Material(
          color: selected ? context.surface.cardHigh : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            key: Key('settings_tab_${section.name}'),
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Text(
                label,
                style: TextStyle(
                  color: selected
                      ? context.surface.textPrimary
                      : context.surface.textSecondary,
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
