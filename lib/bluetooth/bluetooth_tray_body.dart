import 'dart:async';

import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/bluetooth/bluetooth_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';

/// The Bluetooth tab of the console's Network domain, drawn to
/// `NETWORK / bluetooth`.
///
/// The same shape as the WiFi tab — one card of rows that open to reveal their
/// actions — plus the console's own visibility switches, which belong to the
/// adapter rather than to any device and so sit in a card of their own.
class BluetoothTrayBody extends StatefulWidget {
  /// Creates a [BluetoothTrayBody].
  const BluetoothTrayBody({super.key});

  @override
  State<BluetoothTrayBody> createState() => _BluetoothTrayBodyState();
}

class _BluetoothTrayBodyState extends State<BluetoothTrayBody> {
  /// Address of the open row, if any. View state — see the WiFi body.
  String? _openAddress;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final cubit = context.read<BluetoothCubit>();
      await cubit.load();
      if (!mounted) return;
      if (cubit.state.supported && cubit.state.status.powered) {
        await cubit.scan();
      }
    });
  }

  Future<void> _forget(BluetoothCubit cubit, BluetoothDevice device) async {
    final l10n = context.l10n;
    final confirmed = await showConsoleForgetDialog(
      context,
      title: l10n.bluetoothForgetConfirmTitle(device.name),
      body: l10n.bluetoothForgetConfirmBody,
      confirmLabel: l10n.bluetoothForgetConfirmAction,
      confirmKey: const Key('bluetooth_forget_confirm'),
    );
    if (!confirmed) return;
    await cubit.forget(device);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<BluetoothCubit>().state;
    final cubit = context.read<BluetoothCubit>();
    final on = state.status.powered;
    final pairing = _pairingDevice(state);
    final error = state.errorMessage;

    return KeyedSubtree(
      key: const Key('bluetooth_tray_body'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConsoleFaceHeader(
            title: l10n.trayBluetoothLabel,
            rescanKey: const Key('bluetooth_scan'),
            powerKey: const Key('bluetooth_power'),
            status: pairing != null
                ? l10n.bluetoothHeaderPairing(pairing.name)
                : error != null
                ? l10n.bluetoothHeaderFailed
                : null,
            powered: on && state.supported,
            onPoweredChanged: state.supported && !state.busy
                ? (_) => unawaited(cubit.togglePowered())
                : null,
            scanning: state.scanning,
            onRescan: state.supported && on
                ? () => unawaited(cubit.scan())
                : null,
          ),
          const SizedBox(height: 14),
          if (!state.supported)
            ConsoleEmptyCard(message: l10n.bluetoothUnsupportedBody)
          else if (on)
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ConsoleCard(
                      children: [
                        if (pairing != null)
                          ConsoleBanner(
                            actionKey: const Key('bluetooth_pair_cancel'),
                            message: l10n.bluetoothPairingMessage(
                              pairing.name,
                            ),
                            actionLabel: l10n.cancel,
                            onAction: cubit.cancelPairing,
                          )
                        else if (error != null)
                          ConsoleBanner(
                            actionKey: const Key('bluetooth_error_retry'),
                            failed: true,
                            message: l10n.bluetoothPairFailed,
                            actionLabel: l10n.networkTryAgainAction,
                            onAction: () => unawaited(cubit.scan()),
                          ),
                        ..._deviceRows(l10n, state, cubit),
                      ],
                    ),
                    const SizedBox(height: 14),
                    ConsoleCard(
                      children: [
                        ConsoleRow(
                          title: l10n.bluetoothDiscoverableTitle,
                          subtitle: l10n.bluetoothDiscoverableSubtitle,
                          trailing: ConsoleSwitch(
                            key: const Key('bluetooth_discoverable'),
                            value: state.status.discoverable,
                            semanticLabel: l10n.bluetoothDiscoverableTitle,
                            onChanged: state.busy
                                ? null
                                : (on) => unawaited(
                                    cubit.setDiscoverable(enabled: on),
                                  ),
                          ),
                        ),
                        ConsoleRow(
                          divider: false,
                          title: l10n.bluetoothAdvertiseTitle,
                          subtitle: l10n.bluetoothAdvertiseSubtitle,
                          trailing: ConsoleSwitch(
                            key: const Key('bluetooth_advertise'),
                            value: state.status.advertising,
                            semanticLabel: l10n.bluetoothAdvertiseTitle,
                            onChanged: state.busy
                                ? null
                                : (on) => unawaited(
                                    cubit.setAdvertising(enabled: on),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The device a pairing is waiting on, resolved from the address so the
  /// banner can name it. Falls back to a bare device when the scan list has
  /// already moved on.
  BluetoothDevice? _pairingDevice(BluetoothState state) {
    final address = state.pairingAddress;
    if (address == null) return null;
    for (final device in state.devices) {
      if (device.address == address) return device;
    }
    return BluetoothDevice(name: address, address: address);
  }

  List<Widget> _deviceRows(
    AppLocalizations l10n,
    BluetoothState state,
    BluetoothCubit cubit,
  ) {
    final devices = state.devices;
    return [
      for (final device in devices)
        _deviceRow(
          l10n: l10n,
          device: device,
          state: state,
          cubit: cubit,
          last: device == devices.last,
        ),
    ];
  }

  Widget _deviceRow({
    required AppLocalizations l10n,
    required BluetoothDevice device,
    required BluetoothState state,
    required BluetoothCubit cubit,
    required bool last,
  }) {
    final open = _openAddress == device.address;
    // An unpaired device has exactly one thing to do — pair — so tapping it
    // starts that rather than opening a row with one chip in it.
    final expandable = device.paired || device.connected;
    final busy = state.busy;

    void toggle() {
      if (!expandable) {
        if (device.inRange) unawaited(cubit.pair(device));
        return;
      }
      setState(() => _openAddress = open ? null : device.address);
    }

    final row = ConsoleRow(
      key: Key('bluetooth_device_${device.address}'),
      title: device.name,
      subtitle: _deviceSubtitle(l10n, device),
      value: _deviceValue(l10n, device),
      expanded: open,
      divider: !last,
    );

    final onTap = busy && !expandable ? null : toggle;

    // Always the expanded form — see the WiFi body: it owns the animation.
    return ConsoleExpandedRow(
      expanded: open,
      onTap: onTap,
      row: row,
      actions: [
        if (open) ...[
          if (device.connected)
            ConsoleActionChip(
              key: const Key('bluetooth_disconnect'),
              label: l10n.bluetoothDisconnectAction,
              icon: Icons.link_off,
              onPressed: busy
                  ? null
                  : () => unawaited(cubit.disconnect(device)),
            )
          else if (device.inRange)
            ConsoleActionChip(
              key: const Key('bluetooth_connect'),
              label: l10n.bluetoothConnectAction,
              icon: Icons.bluetooth_connected,
              onPressed: busy ? null : () => unawaited(cubit.connect(device)),
            ),
          ConsoleActionChip(
            key: const Key('bluetooth_forget'),
            label: l10n.bluetoothForgetAction,
            icon: Icons.delete_outline,
            destructive: true,
            onPressed: busy ? null : () => unawaited(_forget(cubit, device)),
          ),
        ],
      ],
    );
  }

  String? _deviceSubtitle(AppLocalizations l10n, BluetoothDevice device) {
    if (!device.inRange) return l10n.bluetoothNotInRange;
    if (device.kind.isNotEmpty) return device.kind;
    if (!device.paired) return l10n.bluetoothDiscoverableDevice;
    return null;
  }

  String? _deviceValue(AppLocalizations l10n, BluetoothDevice device) {
    if (device.connected) return l10n.bluetoothConnectedLabel;
    if (device.paired) return l10n.bluetoothPairedLabel;
    return null;
  }
}
