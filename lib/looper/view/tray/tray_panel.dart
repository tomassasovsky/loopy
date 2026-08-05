import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/bluetooth/bluetooth_tray_panel.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/view/tray/pedal_tray_panel.dart';
import 'package:segno/looper/view/tray/tray_home.dart';
import 'package:segno/looper/view/tray/tray_navigation_rail.dart';
import 'package:segno/looper/view/tray/tuner_tray_panel.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/wifi/wifi_tray_panel.dart';

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
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(SurfaceTheme.radius24),
        ),
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
                          padding: const EdgeInsets.fromLTRB(20, 18, 20, 40),
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
                                SettingsTrayDestination.pedal => _TrayFaceFrame(
                                  // Landscape: the plate is a 2.08:1 diagram
                                  // of real hardware, so the radios' portrait
                                  // frame would squash it to nothing.
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
                                SettingsTrayDestination.wifi => _TrayFaceFrame(
                                  child: WifiTrayPanel(
                                    onBack: cubit.showHome,
                                  ),
                                ),
                                SettingsTrayDestination.bluetooth =>
                                  _TrayFaceFrame(
                                    child: BluetoothTrayPanel(
                                      onBack: cubit.showHome,
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

/// Fixed footprint for the in-tray config faces — sizing only; no extra card
/// chrome. Lists scroll inside the panel.
///
/// Named for the frame rather than the radios: it started out sizing only the
/// WiFi and Bluetooth faces, and now sizes the Tuner too.
class _TrayFaceFrame extends StatelessWidget {
  const _TrayFaceFrame({required this.child, this.size = _portrait});

  /// Designated panel size (1080p console Control Center) — the list-shaped
  /// faces: WiFi, Bluetooth, Tuner.
  static const Size _portrait = Size(520, 680);

  /// Landscape frame for faces built around the pedal plate, whose
  /// `AspectRatio` is 846:406.6.
  static const Size wide = Size(980, 700);

  /// Frame to size [child] to.
  final Size size;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: child,
      ),
    );
  }
}
