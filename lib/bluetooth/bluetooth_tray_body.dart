import 'dart:async';

import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/bluetooth/bluetooth_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';

/// The Bluetooth tab of the Network domain — chrome-less.
///
/// The same shape as the WiFi face, plus the console's **own** visibility
/// card: Discoverable and Broadcast are properties of this adapter rather than
/// of any device in the list, so they sit in a card of their own rather than
/// among the devices.
class BluetoothTrayBody extends StatefulWidget {
  /// Creates a [BluetoothTrayBody].
  const BluetoothTrayBody({super.key});

  @override
  State<BluetoothTrayBody> createState() => _BluetoothTrayBodyState();
}

class _BluetoothTrayBodyState extends State<BluetoothTrayBody> {
  /// Which row is open. At most one.
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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<BluetoothCubit>().state;
    final cubit = context.read<BluetoothCubit>();

    if (!state.supported) {
      return KeyedSubtree(
        key: const Key('bluetooth_tray_body'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConsoleFaceHeader(title: l10n.trayBluetoothLabel),
            const SizedBox(height: 14),
            ConsoleEmptyCard(
              message: state.errorMessage ?? l10n.bluetoothUnsupportedBody,
            ),
          ],
        ),
      );
    }

    final on = state.status.powered;
    final header = ConsoleFaceHeader(
      title: l10n.trayBluetoothLabel,
      status: _statusLine(l10n, state),
      actions: [
        if (on)
          ConsoleIconButton(
            key: const Key('bluetooth_scan'),
            icon: Icons.refresh,
            spinning: state.scanning,
            tooltip: state.scanning
                ? l10n.bluetoothScanningSubtitle
                : l10n.bluetoothScanTitle,
            onPressed: state.scanning || state.busy
                ? null
                : () => unawaited(cubit.scan()),
          ),
        ConsoleSwitch(
          key: const Key('bluetooth_power'),
          value: on,
          semanticLabel: l10n.trayBluetoothLabel,
          onChanged: state.busy
              ? null
              : (value) => unawaited(cubit.setPowered(enabled: value)),
        ),
      ],
    );

    // The same rule as WiFi: switched off, this row is the face.
    if (!on) {
      return KeyedSubtree(
        key: const Key('bluetooth_tray_body'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [header],
        ),
      );
    }

    final devices = _listed(state);
    final banner = _banner(l10n, state, cubit);

    return KeyedSubtree(
      key: const Key('bluetooth_tray_body'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: 14),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (devices.isEmpty && banner == null)
                    ConsoleEmptyCard(
                      message: state.scanning
                          ? l10n.bluetoothScanningSubtitle
                          : l10n.bluetoothEmptyDevices,
                    )
                  else
                    ConsoleCard(
                      children: [
                        // Always present so arriving and leaving both animate:
                        // as a bare conditional child the banner appeared
                        // between two frames and shoved the whole list down.
                        // ConsoleExpansion keeps drawing the outgoing banner
                        // for the length of the close, so the rows travel back
                        // up rather than snapping.
                        ConsoleExpansion(
                          key: const Key('bluetooth_banner_slot'),
                          expanded: banner != null,
                          child:
                              banner ?? const SizedBox(width: double.infinity),
                        ),
                        for (final (index, device) in devices.indexed)
                          _row(
                            context,
                            state: state,
                            cubit: cubit,
                            device: device,
                            last: index == devices.length - 1,
                          ),
                      ],
                    ),
                  const SizedBox(height: 14),
                  _visibilityCard(l10n, state, cubit),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Paired devices first, then whatever else the scan saw.
  ///
  /// A pairing is a relationship the console already has; a sighting is a
  /// possibility. Sorting the second above the first would bury the devices
  /// the operator actually owns under whatever happened to be in the room.
  List<BluetoothDevice> _listed(BluetoothState state) {
    final paired = state.devices.where((d) => d.paired).toList();
    final rest = state.devices.where((d) => !d.paired).toList();
    return [...paired, ...rest];
  }

  Widget _visibilityCard(
    AppLocalizations l10n,
    BluetoothState state,
    BluetoothCubit cubit,
  ) => ConsoleCard(
    children: [
      ConsoleRow(
        key: const Key('bluetooth_discoverable_row'),
        title: l10n.bluetoothDiscoverableTitle,
        subtitle: l10n.bluetoothDiscoverableSubtitle,
        trailing: ConsoleSwitch(
          key: const Key('bluetooth_discoverable'),
          value: state.status.discoverable,
          semanticLabel: l10n.bluetoothDiscoverableTitle,
          onChanged: state.busy
              ? null
              : (value) => unawaited(cubit.setDiscoverable(enabled: value)),
        ),
      ),
      ConsoleRow(
        key: const Key('bluetooth_advertise_row'),
        title: l10n.bluetoothAdvertiseTitle,
        subtitle: l10n.bluetoothAdvertiseSubtitle,
        showDivider: false,
        trailing: ConsoleSwitch(
          key: const Key('bluetooth_advertise'),
          value: state.status.advertising,
          semanticLabel: l10n.bluetoothAdvertiseTitle,
          onChanged: state.busy
              ? null
              : (value) => unawaited(cubit.setAdvertising(enabled: value)),
        ),
      ),
    ],
  );

  String? _statusLine(AppLocalizations l10n, BluetoothState state) {
    if (state.pairingAddress case final address?) {
      return l10n.bluetoothPairingShort(_nameFor(state, address));
    }
    if (state.failedAddress case final address?) {
      return l10n.bluetoothPairFailedShort(_nameFor(state, address));
    }
    return null;
  }

  Widget? _banner(
    AppLocalizations l10n,
    BluetoothState state,
    BluetoothCubit cubit,
  ) {
    if (state.pairingAddress case final address?) {
      return ConsoleBanner(
        key: const Key('bluetooth_banner'),
        message: l10n.bluetoothPairingBanner(_nameFor(state, address)),
        tone: ConsoleBannerTone.pending,
        actions: [
          ConsoleSmallButton(
            label: l10n.cancel,
            onPressed: cubit.cancelPairing,
          ),
        ],
      );
    }
    if (state.errorMessage == null) return null;
    final address = state.failedAddress;
    return ConsoleBanner(
      key: const Key('bluetooth_banner'),
      message: state.errorMessage!,
      tone: ConsoleBannerTone.failure,
      actions: [
        if (address case final failed?)
          ConsoleSmallButton(
            label: l10n.networkTryAgain,
            onPressed: () => unawaited(cubit.pair(failed)),
          ),
      ],
    );
  }

  String _nameFor(BluetoothState state, String address) =>
      state.devices
          .where((d) => d.address == address)
          .map((d) => d.name)
          .firstOrNull ??
      address;

  Widget _row(
    BuildContext context, {
    required BluetoothState state,
    required BluetoothCubit cubit,
    required BluetoothDevice device,
    required bool last,
  }) {
    final l10n = context.l10n;
    final open = _openAddress == device.address;
    // Every row carries a marker (see the WiFi face). Only a paired device has
    // more than one thing to do with it and opens in place; an unpaired one
    // pairs on the tap.
    final opens = device.paired;

    final row = ConsoleRow(
      key: Key('bluetooth_device_${device.address}'),
      title: device.name,
      subtitle: _subtitle(l10n, device),
      state: _stateWord(l10n, device),
      expanded: opens && open,
      showDivider: !last && !open,
      onTap: state.busy
          ? null
          : () {
              if (opens) {
                setState(() => _openAddress = open ? null : device.address);
                return;
              }
              unawaited(cubit.pair(device.address));
            },
    );

    // See the WiFi face: the container stays in the tree so opening animates.
    if (!opens) return row;

    return ConsoleExpandedRow(
      row: row,
      expanded: open,
      actions: [
        if (device.connected)
          ConsoleActionChip(
            key: const Key('bluetooth_disconnect'),
            label: l10n.bluetoothDisconnectAction,
            icon: Icons.link_off,
            onPressed: state.busy
                ? null
                : () => unawaited(cubit.disconnect(device.address)),
          )
        else
          ConsoleActionChip(
            key: const Key('bluetooth_connect'),
            label: l10n.bluetoothConnectAction,
            icon: Icons.bluetooth_connected,
            // A device that is not in range cannot be connected to, and an
            // enabled control that always fails is worse than a dimmed one.
            onPressed: state.busy || !device.inRange
                ? null
                : () => unawaited(cubit.connect(device.address)),
          ),
        ConsoleActionChip(
          key: const Key('bluetooth_forget'),
          label: l10n.bluetoothForgetAction,
          icon: Icons.delete_outline,
          destructive: true,
          onPressed: state.busy
              ? null
              : () => unawaited(_confirmForget(context, cubit, device)),
        ),
      ],
    );
  }

  String? _subtitle(AppLocalizations l10n, BluetoothDevice device) {
    if (!device.inRange) return l10n.bluetoothNotInRange;
    final kind = _kindLabel(l10n, device.kind);
    // bluez gives no `Icon:` for some devices. Rather than guess, the row says
    // the one thing that is true of anything the scan can see.
    return kind ?? l10n.bluetoothDiscoverableState;
  }

  String? _kindLabel(AppLocalizations l10n, BluetoothDeviceKind kind) =>
      switch (kind) {
        BluetoothDeviceKind.headphones => l10n.bluetoothKindHeadphones,
        BluetoothDeviceKind.speaker => l10n.bluetoothKindSpeaker,
        BluetoothDeviceKind.phone => l10n.bluetoothKindPhone,
        BluetoothDeviceKind.computer => l10n.bluetoothKindComputer,
        BluetoothDeviceKind.keyboard => l10n.bluetoothKindKeyboard,
        BluetoothDeviceKind.mouse => l10n.bluetoothKindMouse,
        BluetoothDeviceKind.gamepad => l10n.bluetoothKindGamepad,
        BluetoothDeviceKind.unknown => null,
      };

  String? _stateWord(AppLocalizations l10n, BluetoothDevice device) {
    if (device.connected) return l10n.networkStateConnected;
    if (device.paired) return l10n.networkStatePaired;
    return null;
  }

  Future<void> _confirmForget(
    BuildContext context,
    BluetoothCubit cubit,
    BluetoothDevice device,
  ) async {
    final l10n = context.l10n;
    final confirmed = await showConsoleForgetDialog(
      context,
      title: l10n.bluetoothForgetTitleNamed(device.name),
      body: l10n.bluetoothForgetBody,
      confirmLabel: l10n.bluetoothForgetConfirmAction,
    );
    if (!confirmed) return;
    setState(() => _openAddress = null);
    await cubit.forget(device.address);
  }
}
