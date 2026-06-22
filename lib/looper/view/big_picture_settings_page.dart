import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/cubit/big_picture_cubit.dart';
import 'package:loopy/looper/cubit/refresh_rate_cubit.dart';
import 'package:loopy/looper/view/rename_track_dialog.dart';
import 'package:loopy/looper/view/tracks_routing_graph/tracks_routing_graph_view.dart';
import 'package:loopy/setup/setup_surface.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:loopy/visualizer/visualizer.dart';
import 'package:settings_repository/settings_repository.dart';

/// A settings section, shown one at a time and selected from the left rail.
enum _Section { view, audio, routing, tracks }

/// Settings for the Big Picture performance view, reachable from the view via
/// right-click or the `S` key, and from the system menu bar on macOS.
///
/// Laid out like the audio onboarding panel: a dark centered surface with a
/// left rail that selects a section, and a scrollable right pane of the
/// selected section's controls. `Esc` closes the page.
class BigPictureSettingsPage extends StatefulWidget {
  /// Creates a [BigPictureSettingsPage].
  const BigPictureSettingsPage({super.key});

  @override
  State<BigPictureSettingsPage> createState() => _BigPictureSettingsPageState();
}

class _BigPictureSettingsPageState extends State<BigPictureSettingsPage> {
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
                  key: const Key('bpSettings_close_button'),
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
    _Section.routing => _routingSection(context),
    _Section.tracks => _tracksSection(context),
  };

  List<Widget> _viewSection(BuildContext context) {
    final l10n = context.l10n;
    final waveformEnabled = context.watch<WaveformWindowCubit>().state;
    final defaultMode = context.watch<BigPictureCubit>().state.defaultMode;
    final refreshHz = context.watch<RefreshRateCubit>().state;
    return [
      Text(l10n.bpSettingsViewIntro, style: setupBody),
      const SizedBox(height: 28),
      SetupGroupLabel(l10n.viewGroupLabel),
      const SizedBox(height: 12),
      SetupToggleRow(
        toggleKey: const Key('bpSettings_waveformWindow_switch'),
        title: l10n.waveformWindowTitle,
        subtitle: l10n.waveformWindowSubtitle,
        value: waveformEnabled,
        onChanged: (on) =>
            context.read<WaveformWindowCubit>().setEnabled(value: on),
      ),
      const SizedBox(height: 28),
      SetupGroupLabel(l10n.performanceGroupLabel),
      const SizedBox(height: 12),
      Text(l10n.bpDefaultModeIntro, style: setupBody),
      const SizedBox(height: 12),
      SetupOptionRow<PerformanceMode>(
        selected: defaultMode,
        onSelected: (m) => unawaited(
          context.read<BigPictureCubit>().setDefaultPerformanceMode(m),
        ),
        options: [
          SetupOption(
            value: PerformanceMode.record,
            label: l10n.recordModeLabel,
            sub: l10n.recordModeSub,
            optionKey: const Key('bpSettings_defaultMode_record'),
          ),
          SetupOption(
            value: PerformanceMode.play,
            label: l10n.playModeLabel,
            sub: l10n.playModeSub,
            optionKey: const Key('bpSettings_defaultMode_play'),
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
              optionKey: Key('bpSettings_refreshRate_$hz'),
            ),
        ],
      ),
    ];
  }

  List<Widget> _audioSection(BuildContext context) => const [
    AudioSettingsSection(),
  ];

  List<Widget> _routingSection(BuildContext context) {
    final l10n = context.l10n;
    // The settings page is pushed above the LooperBloc provider, so the graph
    // is sourced from — and edits are applied through — the repository (and
    // persisted via settings, mirroring what the bloc does for the in-view
    // routing controls).
    final repository = context.read<LooperRepository>();
    final settings = context.read<SettingsRepository>();
    final names = context.watch<BigPictureCubit>().state.names;
    final trackLabels = [
      for (var i = 0; i < names.length; i++) l10n.displayTrackName(names[i], i),
    ];
    return [
      Text(l10n.routingIntro, style: setupBody),
      const SizedBox(height: 28),
      SetupGroupLabel(l10n.signalFlowGroupLabel),
      const SizedBox(height: 16),
      StreamBuilder<LooperState>(
        stream: repository.looperState,
        initialData: repository.state,
        builder: (context, snapshot) {
          final state = snapshot.data ?? const LooperState();
          return TracksRoutingGraphView(
            tracks: state.tracks,
            inputChannels: state.status.inputChannels,
            outputChannels: state.status.outputChannels,
            excludedInputMask: state.status.excludedInputMask,
            trackLabels: trackLabels,
            onInputMaskChanged: (channel, mask) {
              repository.setInputMask(channel: channel, mask: mask);
              unawaited(
                settings.saveLaneInput(channel, 0, maskToInputChannel(mask)),
              );
            },
            onOutputMaskChanged: (channel, mask) {
              repository.setOutputMask(channel: channel, mask: mask);
              unawaited(settings.saveLaneOutput(channel, 0, mask));
            },
          );
        },
      ),
    ];
  }

  List<Widget> _tracksSection(BuildContext context) {
    final l10n = context.l10n;
    final big = context.watch<BigPictureCubit>();
    return [
      Text(l10n.tracksIntro, style: setupBody),
      const SizedBox(height: 28),
      SetupGroupLabel(l10n.tracksGroupLabel),
      const SizedBox(height: 12),
      for (var i = 0; i < big.state.names.length; i++) ...[
        SetupTrackNameRow(
          rowKey: Key('bpSettings_trackName_$i'),
          channel: i,
          name: l10n.displayTrackName(big.state.names[i], i),
          onTap: () => showRenameTrackDialog(
            context: context,
            cubit: context.read<BigPictureCubit>(),
            channel: i,
            current: big.state.names[i],
          ),
        ),
        if (i < big.state.names.length - 1) const SizedBox(height: 8),
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
          Text(l10n.bigPictureTitle, style: setupTitle),
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
      _Section.routing => l10n.settingsSectionRouting,
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
            key: Key('bpSettings_tab_${section.name}'),
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
