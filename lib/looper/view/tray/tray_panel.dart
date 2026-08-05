import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/view/tray/pedal_tray_panel.dart';
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
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

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
                          child: AnimatedSwitcher(
                            duration: reduceMotion
                                ? Duration.zero
                                : const Duration(milliseconds: 240),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder: (child, animation) {
                              // Vertical handoff: incoming rises from below.
                              final offset =
                                  Tween<Offset>(
                                    begin: const Offset(0, 0.12),
                                    end: Offset.zero,
                                  ).animate(
                                    CurvedAnimation(
                                      parent: animation,
                                      curve: Curves.easeOutCubic,
                                    ),
                                  );
                              return FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: offset,
                                  child: child,
                                ),
                              );
                            },
                            child: KeyedSubtree(
                              key: ValueKey(state.destination),
                              child: switch (state.destination) {
                                SettingsTrayDestination.home =>
                                  const TrayHome(),
                                SettingsTrayDestination.pedal =>
                                  _TrayFaceFrame.fixed(
                                    // Landscape: the plate is a 2.08:1 diagram
                                    // of real hardware, so filling the sheet
                                    // would distort it.
                                    size: _TrayFaceFrame.wide,
                                    child: PedalTrayPanel(
                                      onBack: cubit.showHome,
                                    ),
                                  ),
                                SettingsTrayDestination.tuner => _TrayFaceFrame(
                                  child: TunerTrayPanel(
                                    onBack: cubit.showHome,
                                  ),
                                ),
                                SettingsTrayDestination.network =>
                                  _TrayFaceFrame(
                                    child: NetworkTrayPanel(
                                      tab: state.networkTab,
                                      onTabChanged: cubit.showNetworkTab,
                                    ),
                                  ),
                              },
                            ),
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
///
/// Named for the frame rather than the radios: it started out sizing only the
/// WiFi and Bluetooth faces, and now sizes the Tuner too.
class _TrayFaceFrame extends StatelessWidget {
  /// A face that fills the sheet beside the rail.
  ///
  /// The default, because that is what the rail is for: the destination you
  /// picked is the panel, so it should be the panel. These faces used to be
  /// pinned to a fixed 520x680 box and centred, which left a list floating in
  /// the middle of a mostly empty sheet no matter how much room was beside the
  /// rail (#493).
  const _TrayFaceFrame({required this.child}) : size = null;

  /// A face sized to a fixed landscape frame, for content whose own aspect
  /// ratio drives the layout — the pedal plate is 846:406.6 and stretching it
  /// to the sheet would distort the thing being pointed at.
  const _TrayFaceFrame.fixed({required this.child, required Size this.size});

  /// Landscape frame for faces built around the pedal plate.
  static const Size wide = Size(980, 700);

  /// Frame to size [child] to, or null to fill the available space.
  final Size? size;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bounds = size;
    if (bounds == null) return SizedBox.expand(child: child);
    return Center(
      child: SizedBox(
        width: bounds.width,
        height: bounds.height,
        child: child,
      ),
    );
  }
}
