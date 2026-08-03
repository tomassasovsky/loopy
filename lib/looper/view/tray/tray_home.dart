import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/app/loopy_navigator.dart';
import 'package:loopy/bluetooth/bluetooth_cubit.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/cubit/settings_tray_cubit.dart';
import 'package:loopy/looper/view/signal_graph/signal_graph.dart';
import 'package:loopy/looper/view/tray/tray_brightness_slider.dart';
import 'package:loopy/looper/view/tray/tray_tile.dart';
import 'package:loopy/wifi/wifi_cubit.dart';

/// Home face: quick-access tiles + brightness slider.
///
/// The tiles that stay here are the ones the navigation rail deliberately
/// does not carry: the two radio *toggles* (tap toggles, long-press opens the
/// rail's own config face) and the two surfaces that still push a full-screen
/// route (Settings, Signal).
class TrayHome extends StatelessWidget {
  /// Creates a [TrayHome].
  const TrayHome({super.key});

  /// Fixed tile footprint — real Control Center tiles stay small no matter
  /// how large the sheet behind them is. Taller than it is wide, to leave
  /// room for the label under the icon.
  static const double _tileWidth = 72;
  static const double _tileHeight = 100;
  static const double _gap = 12;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<SettingsTrayCubit>().state;
    final cubit = context.read<SettingsTrayCubit>();
    final wifi = context.watch<WifiCubit>().state;
    final bluetooth = context.watch<BluetoothCubit>().state;
    const blockHeight = _tileHeight * 2 + _gap;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          // Rows are left-aligned: the second row holds fewer tiles than the
          // first, and centring it reads as a stray tile rather than a grid.
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: _tileWidth,
                  height: _tileHeight,
                  child: TrayTile(
                    key: const Key('settingsTray_settings'),
                    icon: Icons.settings_outlined,
                    label: l10n.settingsTooltip,
                    isOn: false,
                    onTap: state.isNavigating
                        ? null
                        : () => unawaited(
                            _navigate(context, openLoopySettings),
                          ),
                  ),
                ),
                const SizedBox(width: _gap),
                SizedBox(
                  width: _tileWidth,
                  height: _tileHeight,
                  child: TrayTile(
                    key: const Key('settingsTray_signal'),
                    icon: Icons.account_tree_outlined,
                    label: l10n.signalTooltip,
                    isOn: false,
                    onTap: state.isNavigating
                        ? null
                        : () => unawaited(
                            _navigate(context, () => showSignalPage(context)),
                          ),
                  ),
                ),
                const SizedBox(width: _gap),
                SizedBox(
                  width: _tileWidth,
                  height: _tileHeight,
                  child: TrayTile(
                    key: const Key('settingsTray_wifi'),
                    // On = radio up (`enabled`), not association (`connected`).
                    icon: wifi.status.enabled ? Icons.wifi : Icons.wifi_off,
                    // Caption: SSID when associated, else the generic label.
                    label: wifi.status.connected && wifi.status.ssid.isNotEmpty
                        ? wifi.status.ssid
                        : l10n.trayWifiLabel,
                    semanticLabel:
                        wifi.status.connected && wifi.status.ssid.isNotEmpty
                        ? '${l10n.trayWifiLabel}, ${wifi.status.ssid}'
                        : l10n.trayWifiLabel,
                    isOn: wifi.supported && wifi.status.enabled,
                    onTap: wifi.supported && !wifi.busy
                        ? () => unawaited(_toggleWifi(context))
                        : null,
                    onLongPress: cubit.openWifi,
                  ),
                ),
              ],
            ),
            const SizedBox(height: _gap),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: _tileWidth,
                  height: _tileHeight,
                  child: TrayTile(
                    key: const Key('settingsTray_bluetooth'),
                    // On = adapter powered, not discoverable/advertising.
                    icon: bluetooth.status.powered
                        ? Icons.bluetooth
                        : Icons.bluetooth_disabled,
                    // Caption: peer name when Connected, else the generic label
                    label:
                        bluetooth.status.connected &&
                            bluetooth.status.device.isNotEmpty
                        ? bluetooth.status.device
                        : l10n.trayBluetoothLabel,
                    semanticLabel:
                        bluetooth.status.connected &&
                            bluetooth.status.device.isNotEmpty
                        ? '${l10n.trayBluetoothLabel}, '
                              '${bluetooth.status.device}'
                        : l10n.trayBluetoothLabel,
                    isOn: bluetooth.supported && bluetooth.status.powered,
                    onTap: bluetooth.supported && !bluetooth.busy
                        ? () => unawaited(_toggleBluetooth(context))
                        : null,
                    onLongPress: cubit.openBluetooth,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(width: _gap),
        SizedBox(
          width: 56,
          height: blockHeight,
          child: TrayBrightnessSlider(
            value: state.brightness,
            onChanged: (value) => unawaited(cubit.setBrightness(value)),
          ),
        ),
      ],
    );
  }
}

/// Runs a tray nav-button push (`openLoopySettings` or `showSignalPage`,
/// unchanged from the `S`/`G` keyboard shortcuts and desktop toolbar — both
/// pick up the app-wide fade + scale-up transition from
/// `AppTheme`'s `pageTransitionsTheme`). Closes the tray synchronously —
/// before [push] resolves — and holds the `isNavigating` guard for the
/// push's duration even if it throws, so a failed navigation can never leave
/// both nav tiles stuck disabled.
Future<void> _navigate(
  BuildContext context,
  Future<void> Function() push,
) async {
  final cubit = context.read<SettingsTrayCubit>()
    ..closeTray()
    ..beginNavigating();
  try {
    await push();
  } finally {
    if (context.mounted) cubit.endNavigating();
  }
}

/// Tap toggle for WiFi: radio on/off. Turning **on** also opens the in-tray
/// WiFi panel so the user can pick a network.
Future<void> _toggleWifi(BuildContext context) async {
  final wifi = context.read<WifiCubit>();
  final tray = context.read<SettingsTrayCubit>();
  final turningOn = !wifi.state.status.enabled;
  await wifi.toggleEnabled();
  if (!context.mounted) return;
  if (turningOn && wifi.state.status.enabled) tray.openWifi();
}

/// Tap toggle for Bluetooth: adapter power. Turning **on** also opens the
/// in-tray Bluetooth panel.
Future<void> _toggleBluetooth(BuildContext context) async {
  final bluetooth = context.read<BluetoothCubit>();
  final tray = context.read<SettingsTrayCubit>();
  final turningOn = !bluetooth.state.status.powered;
  await bluetooth.togglePowered();
  if (!context.mounted) return;
  if (turningOn && bluetooth.state.status.powered) tray.openBluetooth();
}
