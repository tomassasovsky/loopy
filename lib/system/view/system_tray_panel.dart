import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/pill_tabs.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/system/system_tab.dart';
import 'package:segno/system/view/about_system_tab.dart';
import 'package:segno/system/view/display_system_tab.dart';
import 'package:segno/system/view/storage_system_tab.dart';
import 'package:segno/system/view/updates_system_tab.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/cubit/waveform_window_cubit.dart';

/// In-tray System face: what the console shows and what it runs, as tabs of
/// one rail destination, drawn to the `SYSTEM / *` screens.
class SystemTrayPanel extends StatefulWidget {
  /// Creates a [SystemTrayPanel].
  const SystemTrayPanel({
    required this.tab,
    required this.onTabChanged,
    super.key,
  });

  /// The showing tab.
  final SystemTab tab;

  /// Called with the tab the user picked.
  final ValueChanged<SystemTab> onTabChanged;

  @override
  State<SystemTrayPanel> createState() => _SystemTrayPanelState();
}

class _SystemTrayPanelState extends State<SystemTrayPanel> {
  /// Set when asking for the second window leaves it shut.
  ///
  /// Held by the face rather than the cubit: the cubit records the PREFERENCE
  /// (the window is wanted), and whether the window actually opened is a
  /// property of this attempt, on this screen, right now.
  bool _waveformFailed = false;

  Future<void> _retryWaveform() async {
    final cubit = context.read<WaveformWindowCubit>();
    await cubit.setEnabled(value: true);
    if (mounted) setState(() => _waveformFailed = !cubit.state);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;

    return KeyedSubtree(
      key: const Key('system_tray_panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.traySystemLabel,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: PillTabs<SystemTab>(
              key: const Key('system_tabs'),
              selected: widget.tab,
              onChanged: widget.onTabChanged,
              tabs: [
                PillTab(value: SystemTab.display, label: l10n.systemDisplayTab),
                PillTab(value: SystemTab.updates, label: l10n.systemUpdatesTab),
                PillTab(value: SystemTab.storage, label: l10n.systemStorageTab),
                PillTab(value: SystemTab.about, label: l10n.systemAboutTab),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: switch (widget.tab) {
              SystemTab.display => DisplaySystemTab(
                waveformFailed: _waveformFailed,
                onRetryWaveform: () => unawaited(_retryWaveform()),
              ),
              SystemTab.updates => const UpdatesSystemTab(),
              SystemTab.storage => const StorageSystemTab(),
              SystemTab.about => const AboutSystemTab(),
            },
          ),
        ],
      ),
    );
  }
}
