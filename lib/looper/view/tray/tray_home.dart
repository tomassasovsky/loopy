import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/bluetooth/bluetooth_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/view/tray/tray_brightness_slider.dart';
import 'package:segno/looper/view/tray/tray_tile.dart';
import 'package:segno/wifi/wifi_cubit.dart';

/// Home face: quick-access cards + brightness.
///
/// The cards that stay here are the ones the navigation rail deliberately
/// does not carry: the two radio *toggles* (tap toggles, long-press opens the
/// rail's own config face) and Settings, the last surface that still pushes a
/// full-screen route.
///
/// Signal was the fourth, and is gone: #533 made it a rail destination, so a
/// tile whose whole job was to navigate away from the tray had nothing left to
/// do. Three cards remain.
///
/// Sizing is a deliberate middle ground. The pre-rail 72px tiles were the
/// smallest touch target on a console operated by hand while standing over
/// it; letting cards expand to fill a 1080p pane instead turns the
/// destinations into billboards. So cards cap at [_maxCardExtent] and the
/// grid centres as a block — the pane is simply larger than its content, and
/// what resolves that is the parent plan's own remaining item (what the home
/// face is FOR once the rail carries every domain), not inflating what is
/// here now.
class TrayHome extends StatelessWidget {
  /// Creates a [TrayHome].
  const TrayHome({super.key});

  /// Below this pane width the grid drops to a single column — a two-column
  /// grid in a narrow desktop window produces cards too thin to read.
  static const double _twoColumnMinWidth = 520;

  /// Cards stop growing here. Generous for a floor console at arm's length,
  /// and far short of the full-pane stretch that reads as a billboard.
  static const double _maxCardExtent = 280;

  /// Width of the brightness column beside the grid.
  static const double _brightnessWidth = 72;

  static const double _gap = 16;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<SettingsTrayCubit>().state;
    final cubit = context.read<SettingsTrayCubit>();
    final wifi = context.watch<WifiCubit>().state;
    final bluetooth = context.watch<BluetoothCubit>().state;

    final wifiConnected = wifi.status.connected && wifi.status.ssid.isNotEmpty;
    final bluetoothConnected =
        bluetooth.status.connected && bluetooth.status.device.isNotEmpty;

    final cards = <Widget>[
      TrayTile(
        key: const Key('settingsTray_settings'),
        icon: Icons.settings_outlined,
        label: l10n.settingsTooltip,
        isOn: false,
        onTap: state.isNavigating
            ? null
            : () => unawaited(_navigate(context, openSegnoSettings)),
      ),
      TrayTile(
        key: const Key('settingsTray_wifi'),
        // On = radio up (`enabled`), not association (`connected`).
        icon: wifi.status.enabled ? Icons.wifi : Icons.wifi_off,
        label: l10n.trayWifiLabel,
        // The card has room for a status line, so the SSID no longer has to
        // displace the label the way it did on the old single-caption tile.
        subtitle: wifiConnected ? wifi.status.ssid : null,
        semanticLabel: wifiConnected
            ? '${l10n.trayWifiLabel}, ${wifi.status.ssid}'
            : l10n.trayWifiLabel,
        isOn: wifi.supported && wifi.status.enabled,
        onTap: wifi.supported && !wifi.busy
            ? () => unawaited(_toggleWifi(context))
            : null,
        onLongPress: cubit.openWifi,
      ),
      TrayTile(
        key: const Key('settingsTray_bluetooth'),
        // On = adapter powered, not discoverable/advertising.
        icon: bluetooth.status.powered
            ? Icons.bluetooth
            : Icons.bluetooth_disabled,
        label: l10n.trayBluetoothLabel,
        subtitle: bluetoothConnected ? bluetooth.status.device : null,
        semanticLabel: bluetoothConnected
            ? '${l10n.trayBluetoothLabel}, ${bluetooth.status.device}'
            : l10n.trayBluetoothLabel,
        isOn: bluetooth.supported && bluetooth.status.powered,
        onTap: bluetooth.supported && !bluetooth.busy
            ? () => unawaited(_toggleBluetooth(context))
            : null,
        onLongPress: cubit.openBluetooth,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        // The block is sized from the grid's ACTUAL shape, not an assumed
        // 2x2: `_maxCardExtent` is a cap on a *card*, so the block has to
        // grow with the row and column count or the cap silently stops
        // governing card size as destinations are added.
        final columns = _columnsFor(
          constraints.maxWidth - _brightnessWidth - _gap,
          cards.length,
        );
        final rows = (cards.length + columns - 1) ~/ columns;

        // Solve for one square cell that fits both axes, capped at
        // [_maxCardExtent], then size the block to exactly that many cells.
        // Sizing the block EXPLICITLY rather than via a max-constraint
        // matters: under the loose constraints a `Center` hands down, a
        // stretch `Row` takes its cross-axis extent from its children's
        // intrinsics, so a maximum alone leaves the height to whatever the
        // brightness slider happens to report.
        final cell = [
          (constraints.maxWidth -
                  _brightnessWidth -
                  _gap -
                  (columns - 1) * _gap) /
              columns,
          (constraints.maxHeight - (rows - 1) * _gap) / rows,
          _maxCardExtent,
        ].reduce((a, b) => a < b ? a : b).clamp(0.0, _maxCardExtent);

        final blockWidth =
            columns * cell + (columns - 1) * _gap + _gap + _brightnessWidth;
        final blockHeight = rows * cell + (rows - 1) * _gap;

        return Center(
          child: SizedBox(
            width: blockWidth,
            height: blockHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _CardGrid(cards: cards, columns: columns),
                ),
                const SizedBox(width: _gap),
                // Taller than the old 56x212 stub — it tracks the card block
                // rather than the whole pane, so it reads as part of the same
                // object.
                SizedBox(
                  width: _brightnessWidth,
                  child: TrayBrightnessSlider(
                    value: state.brightness,
                    onChanged: (value) => unawaited(cubit.setBrightness(value)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Column count for [cardCount] cards in [gridWidth] of space.
  ///
  /// The one place this is decided: [TrayHome] needs it to size the block and
  /// [_CardGrid] needs it to lay the cards out, and the two disagreeing is
  /// exactly how the block stops matching its contents.
  static int _columnsFor(double gridWidth, int cardCount) =>
      gridWidth >= _twoColumnMinWidth && cardCount > 1 ? 2 : 1;
}

/// Lays [cards] out as an even grid that fills its box — one column when
/// narrow, two otherwise.
///
/// Deliberately not a `GridView`: every card is visible at once and none of
/// them scroll, so what is needed is an even *division* of the available box,
/// which nested `Expanded`s express directly. A `GridView` would size cells
/// from a cross-axis extent and leave the main axis to scroll.
class _CardGrid extends StatelessWidget {
  const _CardGrid({required this.cards, required this.columns});

  final List<Widget> cards;

  /// Column count, decided by [TrayHome] so the block it sizes and the grid
  /// it contains can never disagree.
  final int columns;

  @override
  Widget build(BuildContext context) {
    final rows = (cards.length + columns - 1) ~/ columns;

    return Column(
      children: [
        for (var row = 0; row < rows; row++) ...[
          if (row > 0) const SizedBox(height: TrayHome._gap),
          Expanded(
            child: Row(
              children: [
                for (var column = 0; column < columns; column++) ...[
                  if (column > 0) const SizedBox(width: TrayHome._gap),
                  Expanded(
                    // The last row can be short of a full set of cards;
                    // the empty cell holds the grid's shape rather than
                    // letting the final card stretch across it.
                    child:
                        cards.elementAtOrNull(row * columns + column) ??
                        const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Runs a tray nav-button push (`openSegnoSettings`, unchanged from the `S`
/// keyboard shortcut and the desktop toolbar — both pick up the app-wide fade
/// + scale-up transition from `AppTheme`'s `pageTransitionsTheme`). Kept
/// generic over [push] rather than inlined: the guard below is about a route
/// leaving the tray, not about which route.
/// Closes the tray synchronously —
/// before [push] resolves — and holds the `isNavigating` guard for the
/// push's duration even if it throws, so a failed navigation can never leave
/// both nav cards stuck disabled.
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
