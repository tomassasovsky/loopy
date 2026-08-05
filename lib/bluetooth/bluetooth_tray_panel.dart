import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/appliance/host_page_chrome.dart';
import 'package:segno/bluetooth/bluetooth_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/setup/setup_surface.dart';
import 'package:segno/theme/theme.dart';

/// In-tray Bluetooth face — fills the Control Center radio division until Back.
class BluetoothTrayPanel extends StatefulWidget {
  /// Creates a [BluetoothTrayPanel].
  const BluetoothTrayPanel({required this.onBack, super.key});

  /// Returns to the tray home tiles (does not dismiss the tray).
  final VoidCallback onBack;

  @override
  State<BluetoothTrayPanel> createState() => _BluetoothTrayPanelState();
}

class _BluetoothTrayPanelState extends State<BluetoothTrayPanel> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final cubit = context.read<BluetoothCubit>();
      await cubit.load();
      if (!mounted) return;
      if (cubit.state.supported) await cubit.scan();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final state = context.watch<BluetoothCubit>().state;
    final cubit = context.read<BluetoothCubit>();
    final alias = state.status.alias.isEmpty ? 'Segno' : state.status.alias;

    return KeyedSubtree(
      key: const Key('bluetooth_tray_panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HostTrayChromeBar(
            backKey: const Key('bluetooth_back'),
            title: l10n.trayBluetoothLabel,
            onBack: widget.onBack,
            trailing: state.supported
                ? HostChromeIconButton(
                    key: const Key('bluetooth_scan'),
                    icon: Icons.refresh,
                    spinner: state.scanning,
                    tooltip: state.scanning
                        ? l10n.bluetoothScanningSubtitle
                        : l10n.bluetoothScanTitle,
                    onPressed: state.scanning || state.busy
                        ? null
                        : () => unawaited(cubit.scan()),
                  )
                : null,
          ),
          const SizedBox(height: 12),
          if (!state.supported)
            Expanded(
              child: Center(
                child: Text(
                  l10n.bluetoothUnsupportedBody,
                  textAlign: TextAlign.center,
                  style: context.setupBody,
                ),
              ),
            )
          else ...[
            // No wrapping card — status + toggles sit on the tray sheet.
            Row(
              children: [
                Icon(
                  Icons.bluetooth,
                  size: 18,
                  color: surface.accent,
                ),
                const SizedBox(width: 10),
                Text(
                  alias,
                  strutStyle: const StrutStyle(
                    fontSize: 14,
                    height: 1,
                    leading: 0,
                    forceStrutHeight: true,
                  ),
                  textHeightBehavior: const TextHeightBehavior(
                    applyHeightToFirstAscent: false,
                    applyHeightToLastDescent: false,
                  ),
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  state.status.powered ? l10n.bluetoothOn : l10n.bluetoothOff,
                  strutStyle: const StrutStyle(
                    fontSize: 12,
                    height: 1,
                    leading: 0,
                    forceStrutHeight: true,
                  ),
                  textHeightBehavior: const TextHeightBehavior(
                    applyHeightToFirstAscent: false,
                    applyHeightToLastDescent: false,
                  ),
                  style: TextStyle(
                    color: surface.textSecondary,
                    fontSize: 12,
                    height: 1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _TraySwitchRow(
              toggleKey: const Key('bluetooth_discoverable'),
              title: l10n.bluetoothDiscoverableTitle,
              value: state.status.discoverable,
              onChanged: state.busy
                  ? null
                  : (on) => unawaited(cubit.setDiscoverable(enabled: on)),
            ),
            Divider(height: 1, color: surface.line),
            _TraySwitchRow(
              toggleKey: const Key('bluetooth_advertise'),
              title: l10n.bluetoothAdvertiseTitle,
              value: state.status.advertising,
              onChanged: state.busy
                  ? null
                  : (on) => unawaited(cubit.setAdvertising(enabled: on)),
            ),
            if (state.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                state.errorMessage!,
                style: context.setupBody.copyWith(fontSize: 12),
              ),
            ],
            const SizedBox(height: 16),
            SetupGroupLabel(l10n.bluetoothDevicesGroup),
            const SizedBox(height: 8),
            Expanded(
              child: state.devices.isEmpty && !state.scanning
                  ? Align(
                      alignment: Alignment.topLeft,
                      child: Text(
                        l10n.bluetoothEmptyDevices,
                        style: context.setupBody,
                      ),
                    )
                  : DecoratedBox(
                      decoration: BoxDecoration(
                        color: surface.card.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(
                          SurfaceTheme.radius10,
                        ),
                        border: Border.all(color: surface.line),
                      ),
                      child: ListView.separated(
                        padding: EdgeInsets.zero,
                        itemCount: state.devices.length,
                        separatorBuilder: (_, _) =>
                            Divider(height: 1, color: surface.line),
                        itemBuilder: (context, index) {
                          final device = state.devices[index];
                          return Padding(
                            key: Key('bluetooth_device_${device.address}'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.bluetooth,
                                  size: 16,
                                  color: surface.textSecondary,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    device.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: surface.textPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Text(
                                  device.address,
                                  style: TextStyle(
                                    color: surface.textTertiary,
                                    fontSize: 11,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Compact switch row matching [SetupToggleRow]'s Switch colors (not
/// `Switch.adaptive` / Cupertino purple). Title only — no subtitle stack.
class _TraySwitchRow extends StatelessWidget {
  const _TraySwitchRow({
    required this.toggleKey,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final Key toggleKey;
  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            key: toggleKey,
            value: value,
            onChanged: onChanged,
            activeThumbColor: surface.onAccent,
            activeTrackColor: surface.accent,
            inactiveThumbColor: surface.textSecondary,
            inactiveTrackColor: surface.cardHigh,
            trackOutlineColor: WidgetStatePropertyAll(surface.line),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }
}
