import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/wifi/wifi_cubit.dart';
import 'package:segno/wifi/wifi_error_message.dart';
import 'package:segno/wifi/wifi_join_sheet.dart';
import 'package:segno/wifi/wifi_network_visibility.dart';
import 'package:wifi_repository/wifi_repository.dart';

/// The WiFi tab of the console's Network domain, drawn to `NETWORK / wifi`.
///
/// One card of networks, each row `SSID / detail` with its state on the right.
/// Switched off, the power row is the whole face — there is nothing truthful
/// to list about a radio that is down, and the mockups say so by showing
/// nothing.
///
/// Chrome-less: the domain owns the tab strip above this, and this owns its
/// own title row (which carries the radio switch, because the switch decides
/// whether the rest of the face exists).
class WifiTrayBody extends StatefulWidget {
  /// Creates a [WifiTrayBody].
  const WifiTrayBody({super.key});

  @override
  State<WifiTrayBody> createState() => _WifiTrayBodyState();
}

class _WifiTrayBodyState extends State<WifiTrayBody> {
  /// SSID of the row that is currently open, if any. Local to the view: which
  /// row is showing its actions is not something the radio has an opinion
  /// about, and it must not survive the face being left.
  String? _openSsid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final cubit = context.read<WifiCubit>();
      await cubit.load();
      if (!mounted) return;
      if (cubit.state.supported && cubit.state.status.enabled) {
        await cubit.scan();
      }
    });
  }

  Future<void> _join(WifiCubit cubit, WifiNetwork network) async {
    final l10n = context.l10n;
    // A saved network already has its passphrase on the console; asking again
    // would be theatre.
    if (!network.secured || network.saved) {
      await cubit.connect(network.ssid);
      return;
    }
    final passphrase = await showWifiJoinSheet(
      context,
      ssid: network.ssid,
      security: l10n.wifiSecuritySecured,
    );
    if (passphrase == null || !mounted) return;
    await cubit.connect(network.ssid, psk: passphrase);
  }

  Future<void> _forget(WifiCubit cubit, String ssid) async {
    final l10n = context.l10n;
    final confirmed = await showConsoleForgetDialog(
      context,
      title: l10n.wifiForgetConfirmTitle(ssid),
      body: l10n.wifiForgetConfirmBody,
      confirmLabel: l10n.wifiForgetConfirmAction,
      confirmKey: const Key('wifi_forget_confirm'),
    );
    if (!confirmed) return;
    await cubit.forget(ssid);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<WifiCubit>().state;
    final cubit = context.read<WifiCubit>();
    final on = state.status.enabled;
    final connecting = state.connectingSsid;
    final error = state.errorMessage;

    return KeyedSubtree(
      key: const Key('wifi_tray_body'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConsoleFaceHeader(
            title: l10n.trayWifiLabel,
            rescanKey: const Key('wifi_scan'),
            powerKey: const Key('wifi_power'),
            status: _headerStatus(l10n, state),
            powered: on && state.supported,
            onPoweredChanged: state.supported && !state.busy
                ? (_) => unawaited(cubit.toggleEnabled())
                : null,
            scanning: state.scanning,
            onRescan: state.supported && on
                ? () => unawaited(cubit.scan())
                : null,
          ),
          const SizedBox(height: 14),
          if (!state.supported)
            ConsoleEmptyCard(
              // A helper that failed for a real reason says so; only a build
              // with no WiFi at all falls back to the generic line.
              message: error != null
                  ? wifiErrorMessage(l10n, error)
                  : l10n.wifiUnsupportedBody,
            )
          else if (on)
            Flexible(
              child: SingleChildScrollView(
                child: ConsoleCard(
                  children: [
                    if (connecting != null)
                      ConsoleBanner(
                        actionKey: const Key('wifi_connect_cancel'),
                        message: l10n.wifiJoiningMessage(connecting),
                        actionLabel: l10n.cancel,
                        onAction: () => unawaited(cubit.cancelConnect()),
                      )
                    else if (error != null)
                      ConsoleBanner(
                        actionKey: const Key('wifi_error_retry'),
                        failed: true,
                        message: wifiErrorMessage(l10n, error),
                        actionLabel: l10n.networkTryAgainAction,
                        onAction: () => unawaited(cubit.scan()),
                      ),
                    ..._rows(l10n, state, cubit),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The live line beside the title: what the radio is doing right now, or
  /// what it just failed to do.
  String? _headerStatus(AppLocalizations l10n, WifiState state) {
    final connecting = state.connectingSsid;
    if (connecting != null) return l10n.wifiHeaderJoining(connecting);
    if (state.errorMessage != null) return l10n.wifiHeaderJoinFailed;
    return null;
  }

  List<Widget> _rows(
    AppLocalizations l10n,
    WifiState state,
    WifiCubit cubit,
  ) {
    final rows = <_WifiRowData>[
      if (state.status.connected && state.status.ssid.isNotEmpty)
        _WifiRowData(
          ssid: state.status.ssid,
          subtitle: state.status.ip.isEmpty ? null : state.status.ip,
          value: state.disconnecting
              ? l10n.wifiStatusDisconnecting
              : l10n.wifiRowConnected,
          connected: true,
          saved: true,
        ),
      for (final network in visibleWifiNetworks(state))
        _WifiRowData(
          ssid: network.ssid,
          subtitle: _networkSubtitle(l10n, network),
          value: _networkValue(l10n, network),
          saved: network.saved,
          joinable: network.inRange,
          network: network,
        ),
    ];

    return [
      for (final row in rows)
        _wifiRow(
          l10n: l10n,
          data: row,
          state: state,
          cubit: cubit,
          last: row == rows.last,
        ),
    ];
  }

  Widget _wifiRow({
    required AppLocalizations l10n,
    required _WifiRowData data,
    required WifiState state,
    required WifiCubit cubit,
    required bool last,
  }) {
    final open = _openSsid == data.ssid;
    // Only a network the console holds credentials for has anything to show
    // when opened; the rest simply join on tap.
    final expandable = data.connected || data.saved;

    void toggle() {
      if (!expandable) {
        final network = data.network;
        if (network != null && data.joinable) {
          unawaited(_join(cubit, network));
        }
        return;
      }
      setState(() => _openSsid = open ? null : data.ssid);
    }

    final row = ConsoleRow(
      key: Key('wifi_network_${data.ssid}'),
      title: data.ssid,
      subtitle: data.subtitle,
      value: data.value,
      expanded: open,
      divider: !last && !open,
      onTap: state.busy && !expandable ? null : toggle,
    );

    // Always the expanded form, open or shut: it owns the open/close
    // animation, and a widget that only exists while open cannot animate
    // into existence.
    return ConsoleExpandedRow(
      expanded: open,
      row: row,
      actions: [
        if (open) ...[
          if (data.connected)
            ConsoleActionChip(
              key: const Key('wifi_disconnect'),
              label: l10n.wifiDisconnectTitle,
              icon: Icons.link_off,
              onPressed: state.busy
                  ? null
                  : () => unawaited(cubit.disconnect()),
            )
          else if (data.joinable)
            ConsoleActionChip(
              key: const Key('wifi_connect'),
              label: l10n.wifiJoinAction,
              icon: Icons.wifi,
              onPressed: state.busy
                  ? null
                  : () => unawaited(cubit.connect(data.ssid)),
            ),
          if (data.saved)
            ConsoleActionChip(
              key: const Key('wifi_forget'),
              label: l10n.wifiForgetAction,
              icon: Icons.delete_outline,
              destructive: true,
              onPressed: state.busy
                  ? null
                  : () => unawaited(_forget(cubit, data.ssid)),
            ),
        ],
      ],
    );
  }

  String? _networkSubtitle(AppLocalizations l10n, WifiNetwork network) {
    if (!network.inRange) return l10n.wifiNotInRange;
    final security = network.secured
        ? l10n.wifiSecuritySecured
        : l10n.wifiSecurityOpen;
    return '${network.signal} dBm · $security';
  }

  String? _networkValue(AppLocalizations l10n, WifiNetwork network) {
    if (network.saved) return l10n.wifiRowSaved;
    if (!network.secured) return l10n.wifiRowOpen;
    return null;
  }
}

/// One list row's worth of WiFi, whether it came from the association status
/// or from a scan result.
@immutable
class _WifiRowData {
  const _WifiRowData({
    required this.ssid,
    this.subtitle,
    this.value,
    this.connected = false,
    this.saved = false,
    this.joinable = true,
    this.network,
  });

  final String ssid;
  final String? subtitle;
  final String? value;
  final bool connected;
  final bool saved;
  final bool joinable;
  final WifiNetwork? network;
}
