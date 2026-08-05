import 'dart:async';
import 'dart:math' as math;

import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/appliance/host_page_chrome.dart';
import 'package:segno/bluetooth/bluetooth_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/setup/setup_surface.dart';
import 'package:segno/theme/page_transitions.dart';
import 'package:segno/theme/theme.dart';

/// Opens the Bluetooth surface as a full-screen page from the settings tray.
Future<void> showBluetoothPage(BuildContext context) {
  final repository = context.read<BluetoothRepository>();
  return Navigator.of(context).push(
    desktopPageRoute<void>(
      (_) => BlocProvider(
        create: (_) => BluetoothCubit(repository: repository),
        child: const BluetoothPage(),
      ),
    ),
  );
}

/// Console Bluetooth — dense, content-sized (discovery / broadcast only).
///
/// Controls sit in one compact strip; the device list is a grouped card
/// capped at 520px so name and address stay adjacent on a wide panel.
class BluetoothPage extends StatefulWidget {
  /// Creates a [BluetoothPage].
  const BluetoothPage({super.key});

  @override
  State<BluetoothPage> createState() => _BluetoothPageState();
}

class _BluetoothPageState extends State<BluetoothPage> {
  static const double _listMaxWidth = 520;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<BluetoothCubit>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final state = context.watch<BluetoothCubit>().state;
    final cubit = context.read<BluetoothCubit>();

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(Navigator.of(context).maybePop()),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const Key('bluetooth_page'),
          body: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.5, -1.15),
                radius: 1.25,
                colors: [surface.pageGlow, surface.background],
                stops: const [0, 0.62],
              ),
            ),
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  HostChromeBar(
                    backKey: const Key('bluetooth_back'),
                    title: l10n.trayBluetoothLabel,
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
                  Expanded(
                    child: !state.supported
                        ? Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(
                              l10n.bluetoothUnsupportedBody,
                              style: context.setupBody,
                            ),
                          )
                        : LayoutBuilder(
                            builder: (context, constraints) {
                              return Align(
                                alignment: Alignment.topLeft,
                                child: SizedBox(
                                  width: math.min(
                                    _listMaxWidth,
                                    constraints.maxWidth,
                                  ),
                                  height: constraints.maxHeight,
                                  child: ListView(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      4,
                                      16,
                                      16,
                                    ),
                                    children: [
                                      _BluetoothControlStrip(
                                        state: state,
                                        onDiscoverable: state.busy
                                            ? null
                                            : (on) => unawaited(
                                                cubit.setDiscoverable(
                                                  enabled: on,
                                                ),
                                              ),
                                        onAdvertise: state.busy
                                            ? null
                                            : (on) => unawaited(
                                                cubit.setAdvertising(
                                                  enabled: on,
                                                ),
                                              ),
                                      ),
                                      if (state.errorMessage != null) ...[
                                        const SizedBox(height: 8),
                                        Text(
                                          state.errorMessage!,
                                          style: context.setupBody.copyWith(
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 14),
                                      _BluetoothDeviceList(state: state),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Alias + two toggles in one horizontal strip (no stacked cards / intro block).
class _BluetoothControlStrip extends StatelessWidget {
  const _BluetoothControlStrip({
    required this.state,
    required this.onDiscoverable,
    required this.onAdvertise,
  });

  final BluetoothState state;
  final ValueChanged<bool>? onDiscoverable;
  final ValueChanged<bool>? onAdvertise;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final alias = state.status.alias.isEmpty ? 'Segno' : state.status.alias;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: surface.line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        child: Row(
          children: [
            Icon(Icons.bluetooth, size: 18, color: surface.accent),
            const SizedBox(width: 10),
            Text(
              alias,
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              state.status.powered ? l10n.bluetoothOn : l10n.bluetoothOff,
              style: TextStyle(color: surface.textSecondary, fontSize: 12),
            ),
            const Spacer(),
            _InlineToggle(
              toggleKey: const Key('bluetooth_discoverable'),
              label: l10n.bluetoothDiscoverableTitle,
              value: state.status.discoverable,
              onChanged: onDiscoverable,
            ),
            const SizedBox(width: 8),
            _InlineToggle(
              toggleKey: const Key('bluetooth_advertise'),
              label: l10n.bluetoothAdvertiseTitle,
              value: state.status.advertising,
              onChanged: onAdvertise,
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineToggle extends StatelessWidget {
  const _InlineToggle({
    required this.toggleKey,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final Key toggleKey;
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            color: surface.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 4),
        Switch.adaptive(
          key: toggleKey,
          value: value,
          onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }
}

class _BluetoothDeviceList extends StatelessWidget {
  const _BluetoothDeviceList({required this.state});

  final BluetoothState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetupGroupLabel(l10n.bluetoothDevicesGroup),
        const SizedBox(height: 6),
        if (state.devices.isEmpty && !state.scanning)
          Text(l10n.bluetoothEmptyDevices, style: context.setupBody)
        else
          DecoratedBox(
            decoration: BoxDecoration(
              color: surface.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: surface.line),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < state.devices.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: surface.line),
                  Padding(
                    key: Key('bluetooth_device_${state.devices[i].address}'),
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
                            state.devices[i].name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: surface.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          state.devices[i].address,
                          style: TextStyle(
                            color: surface.textTertiary,
                            fontSize: 11,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
