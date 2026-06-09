import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/audio_setup.dart';
import 'package:loopy/looper/cubit/bank_cubit.dart';
import 'package:loopy/looper/cubit/big_picture_cubit.dart';
import 'package:loopy/looper/view/rename_track_dialog.dart';
import 'package:loopy/looper/view/routing_graph_view.dart';
import 'package:loopy/setup/setup_surface.dart';
import 'package:loopy/ui_mode/ui_mode.dart';
import 'package:loopy/visualizer/visualizer.dart';
import 'package:settings_repository/settings_repository.dart';

/// A settings section, shown one at a time and selected from the left rail.
enum _Section {
  view('View'),
  audio('Audio'),
  routing('Routing'),
  tracks('Tracks');

  const _Section(this.label);

  final String label;
}

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
        child: SetupSurfacePanel(
          child: Stack(
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
                  const VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: SetupSurfaceColors.line,
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
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.close,
                    size: 18,
                    color: SetupSurfaceColors.t2,
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
    final mode = context.watch<UiModeCubit>().state;
    final waveformEnabled = context.watch<WaveformWindowCubit>().state;
    return [
      const Text(
        'Switch layouts and toggle the secondary output-waveform window.',
        style: setupBody,
      ),
      const SizedBox(height: 28),
      const SetupGroupLabel('VIEW'),
      const SizedBox(height: 12),
      SetupToggleRow(
        toggleKey: const Key('bpSettings_bigPicture_switch'),
        title: 'Big Picture mode',
        subtitle: 'Full-screen performance layout',
        value: mode == UiMode.bigPicture,
        onChanged: (on) {
          unawaited(
            context.read<UiModeCubit>().setMode(
              on ? UiMode.bigPicture : UiMode.desktop,
            ),
          );
          unawaited(Navigator.of(context).maybePop());
        },
      ),
      const SizedBox(height: 12),
      SetupToggleRow(
        toggleKey: const Key('bpSettings_waveformWindow_switch'),
        title: 'Output waveform window',
        subtitle: 'Open a second window showing the whole-loop output waveform',
        value: waveformEnabled,
        onChanged: (on) =>
            context.read<WaveformWindowCubit>().setEnabled(value: on),
      ),
    ];
  }

  List<Widget> _audioSection(BuildContext context) => const [
    AudioSettingsSection(),
  ];

  List<Widget> _routingSection(BuildContext context) {
    // The settings page is pushed above the LooperBloc provider, so the graph
    // is sourced from — and edits are applied through — the repository (and
    // persisted via settings, mirroring what the bloc does for the in-view
    // routing controls).
    final repository = context.read<LooperRepository>();
    final settings = context.read<SettingsRepository>();
    final names = context.watch<BigPictureCubit>().state.names;
    return [
      const Text(
        'How audio is wired: hardware inputs flow into tracks, and tracks '
        'play out to hardware outputs. Loopback inputs are struck through — '
        'they are never recorded. Click a track to select it, then click an '
        'input or output to connect or disconnect it.',
        style: setupBody,
      ),
      const SizedBox(height: 28),
      const SetupGroupLabel('SIGNAL FLOW'),
      const SizedBox(height: 16),
      StreamBuilder<LooperState>(
        stream: repository.looperState,
        initialData: repository.state,
        builder: (context, snapshot) {
          final state = snapshot.data ?? const LooperState();
          return RoutingGraphView(
            tracks: state.tracks,
            inputChannels: state.status.inputChannels,
            outputChannels: state.status.outputChannels,
            excludedInputMask: state.status.excludedInputMask,
            trackLabels: names,
            onInputMaskChanged: (channel, mask) {
              repository.setInputMask(channel: channel, mask: mask);
              unawaited(settings.saveTrackInputMask(channel, mask));
            },
            onOutputMaskChanged: (channel, mask) {
              repository.setOutputMask(channel: channel, mask: mask);
              unawaited(settings.saveTrackOutputMask(channel, mask));
            },
          );
        },
      ),
    ];
  }

  List<Widget> _tracksSection(BuildContext context) {
    final big = context.watch<BigPictureCubit>();
    final bankEnabled = context.watch<BankCubit>().state.enabled;
    return [
      const Text(
        'Enable the second bank and rename tracks.',
        style: setupBody,
      ),
      const SizedBox(height: 28),
      const SetupGroupLabel('TRACKS'),
      const SizedBox(height: 12),
      SetupToggleRow(
        toggleKey: const Key('bpSettings_bank_switch'),
        title: 'Second bank (8 tracks)',
        subtitle: 'Adds a second bank of four tracks, switchable as A / B',
        value: bankEnabled,
        onChanged: (on) => context.read<BankCubit>().setEnabled(value: on),
      ),
      const SizedBox(height: 12),
      for (var i = 0; i < big.state.names.length; i++) ...[
        SetupTrackNameRow(
          rowKey: Key('bpSettings_trackName_$i'),
          channel: i,
          name: big.state.names[i],
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
                decoration: const BoxDecoration(
                  color: SetupSurfaceColors.accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 9),
              Text(
                'SETTINGS',
                style: setupKicker.copyWith(color: SetupSurfaceColors.t2),
              ),
            ],
          ),
          const SizedBox(height: 28),
          const Text('Big Picture', style: setupTitle),
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
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Material(
          color: selected ? SetupSurfaceColors.cardHi : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            key: Key('bpSettings_tab_${section.name}'),
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Text(
                section.label,
                style: TextStyle(
                  color: selected
                      ? SetupSurfaceColors.t1
                      : SetupSurfaceColors.t2,
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
