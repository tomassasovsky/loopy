import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/control/view/control_tray_panel.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/view/loop/loop_tray_panel.dart';
import 'package:segno/looper/view/tray/tray_home.dart';
import 'package:segno/looper/view/tray/tray_navigation_rail.dart';
import 'package:segno/looper/view/tray/tuner_tray_panel.dart';
import 'package:segno/network/network_tray_panel.dart';
import 'package:segno/theme/theme.dart';

/// The tray's contents once open — near-fullscreen frosted sheet, split into
/// a persistent [TrayNavigationRail] and the face it selects.
///
/// The face swap is an animated destination switch inside the sheet, never a
/// full-screen route: config is an overlay you drop out of with one gesture,
/// so it never routes the performer away from the stage view.
class TrayPanel extends StatelessWidget {
  /// Creates a [TrayPanel].
  const TrayPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final state = context.watch<SettingsTrayCubit>().state;
    final cubit = context.read<SettingsTrayCubit>();

    return Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: surface.background.withValues(alpha: 0.78),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Semantics(
                    button: true,
                    label: l10n.dismiss,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: cubit.closeTray,
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const TrayNavigationRail(),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(19, 19, 19, 41),
                          // Home FILLS the pane — it is a grid of cards sized
                          // from the space available, not a content-sized
                          // blob. The config faces keep a fixed
                          // [_TrayFaceFrame] footprint and are centred
                          // individually, since a WiFi list stretched across
                          // a 1080p sheet reads worse than a centred panel.
                          child: KeyedSubtree(
                            key: ValueKey(state.destination),
                            child: switch (state.destination) {
                              SettingsTrayDestination.home => const TrayHome(),
                              SettingsTrayDestination.control => _TrayFaceFrame(
                                child: ControlTrayPanel(
                                  tab: state.controlTab,
                                  onTabChanged: cubit.showControlTab,
                                ),
                              ),
                              SettingsTrayDestination.loop => _TrayFaceFrame(
                                child: LoopTrayPanel(
                                  tab: state.loopTab,
                                  onTabChanged: cubit.showLoopTab,
                                ),
                              ),
                              SettingsTrayDestination.tuner => _TrayFaceFrame(
                                child: TunerTrayPanel(
                                  onBack: cubit.showHome,
                                ),
                              ),
                              SettingsTrayDestination.network => _TrayFaceFrame(
                                child: NetworkTrayPanel(
                                  tab: state.networkTab,
                                  onTabChanged: cubit.showNetworkTab,
                                ),
                              ),
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Footprint for the in-tray config faces — sizing only; no extra card
/// chrome. Lists scroll inside the panel.
class _TrayFaceFrame extends StatelessWidget {
  /// A face fills the sheet beside the rail.
  ///
  /// That is what the rail is for: the destination you picked is the panel, so
  /// it should be the panel. Faces used to be pinned to a fixed 520x680 box
  /// and centred, which left a list floating in the middle of a mostly empty
  /// sheet no matter how much room was beside the rail (#493). The one
  /// exception — a fixed landscape frame for the pedal plate — went with the
  /// plate when the Control face replaced it with a target list (#516).
  const _TrayFaceFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox.expand(child: child);
}
