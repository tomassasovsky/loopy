import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/network/network_surface.dart';
import 'package:segno/network/wifi_join_sheet.dart';
import 'package:segno/wifi/wifi_cubit.dart';
import 'package:segno/wifi/wifi_error_message.dart';
import 'package:segno/wifi/wifi_network_visibility.dart';
import 'package:wifi_repository/wifi_repository.dart';

/// The WiFi tab of the Network domain — chrome-less.
///
/// No chrome bar and no back chevron: the rail is always on screen, and a
/// second way back would be a second navigation surface. What was the panel's
/// title bar is now [NetworkFaceHeader], which belongs to *this tab* because
/// the controls it carries — rescan, power — are this radio's, not the
/// domain's.
class WifiTrayBody extends StatefulWidget {
  /// Creates a [WifiTrayBody].
  const WifiTrayBody({super.key});

  @override
  State<WifiTrayBody> createState() => _WifiTrayBodyState();
}

class _WifiTrayBodyState extends State<WifiTrayBody> {
  /// Which row is open. At most one — an accordion, so the list never grows
  /// past the sheet it has to fit in.
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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<WifiCubit>().state;
    final cubit = context.read<WifiCubit>();

    if (!state.supported) {
      return KeyedSubtree(
        key: const Key('wifi_tray_body'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NetworkFaceHeader(title: l10n.trayWifiLabel),
            const SizedBox(height: 14),
            NetworkEmptyCard(
              // Helper failures used to leave supported=false with no message,
              // and operators then saw the "appliance only" copy even when the
              // binary was present. Prefer the real error.
              message: state.errorMessage != null
                  ? wifiErrorMessage(l10n, state.errorMessage)
                  : l10n.wifiUnsupportedBody,
            ),
          ],
        ),
      );
    }

    final on = state.status.enabled;
    final header = NetworkFaceHeader(
      title: l10n.trayWifiLabel,
      status: _statusLine(l10n, state),
      actions: [
        // The rescan control only exists while the radio does. There is
        // nothing to scan with when it is off, and a disabled button beside a
        // switch invites the wrong tap.
        if (on)
          NetworkIconButton(
            key: const Key('wifi_scan'),
            icon: Icons.refresh,
            spinning: state.scanning,
            tooltip: state.scanning
                ? l10n.wifiScanningSubtitle
                : l10n.wifiRescan,
            onPressed: state.scanning || state.busy
                ? null
                : () => unawaited(cubit.scan()),
          ),
        NetworkSwitch(
          key: const Key('wifi_power'),
          value: on,
          semanticLabel: l10n.trayWifiLabel,
          onChanged: state.busy
              ? null
              : (value) => unawaited(cubit.setEnabled(enabled: value)),
        ),
      ],
    );

    // Power decides whether the rest of the face exists. Switched off, this
    // row IS the face: there is nothing truthful to list about a radio that is
    // down, and a stale list is worse than no list.
    if (!on) {
      return KeyedSubtree(
        key: const Key('wifi_tray_body'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [header],
        ),
      );
    }

    final networks = _listed(state);
    final banner = _banner(l10n, state, cubit);

    return KeyedSubtree(
      key: const Key('wifi_tray_body'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: 14),
          if (networks.isEmpty && banner == null)
            NetworkEmptyCard(
              message: state.scanning
                  ? l10n.wifiScanningSubtitle
                  : l10n.wifiEmptyNetworks,
            )
          else
            Flexible(
              child: SingleChildScrollView(
                child: NetworkCard(
                  children: [
                    ?banner,
                    for (final (index, network) in networks.indexed)
                      _row(
                        context,
                        state: state,
                        cubit: cubit,
                        network: network,
                        last: index == networks.length - 1,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The list: the association, then the console's other saved profiles, then
  /// everything else the scan saw.
  ///
  /// Saved before seen, for the same reason paired sorts before discovered on
  /// the other tab: a profile is a relationship this console already has, and
  /// leaving it to fall wherever its signal puts it buries the networks the
  /// operator actually uses under whatever is in the room. The cubit's
  /// signal-descending order survives inside each group.
  List<WifiNetwork> _listed(WifiState state) {
    final visible = visibleWifiNetworks(state);
    final saved = visible.where((n) => n.saved).toList();
    final rest = visible.where((n) => !n.saved).toList();
    final ssid = state.status.ssid;
    if (!state.status.connected || ssid.isEmpty) return [...saved, ...rest];
    final active = state.networks.where((n) => n.ssid == ssid).firstOrNull;
    return [
      active ??
          WifiNetwork(
            ssid: ssid,
            signal: state.status.signal,
            secured: true,
            saved: true,
          ),
      ...saved,
      ...rest,
    ];
  }

  String? _statusLine(AppLocalizations l10n, WifiState state) {
    final joining = state.connectingSsid;
    if (joining != null) return l10n.wifiJoiningShort(joining);
    final failed = state.failedSsid;
    if (failed != null) return l10n.wifiJoinFailedShort(failed);
    return null;
  }

  Widget? _banner(AppLocalizations l10n, WifiState state, WifiCubit cubit) {
    if (state.connectingSsid case final ssid?) {
      return NetworkBanner(
        key: const Key('wifi_banner'),
        message: l10n.wifiJoiningBanner(ssid),
        tone: NetworkBannerTone.pending,
        actionLabel: l10n.cancel,
        onAction: () => unawaited(cubit.cancelConnect()),
      );
    }
    if (state.errorMessage == null) return null;
    final ssid = state.failedSsid;
    return NetworkBanner(
      key: const Key('wifi_banner'),
      message: wifiErrorMessage(l10n, state.errorMessage),
      tone: NetworkBannerTone.failure,
      actionLabel: ssid == null ? null : l10n.networkTryAgain,
      onAction: ssid == null
          ? null
          : () => unawaited(_join(context, cubit, state, ssid)),
    );
  }

  Widget _row(
    BuildContext context, {
    required WifiState state,
    required WifiCubit cubit,
    required WifiNetwork network,
    required bool last,
  }) {
    final l10n = context.l10n;
    final connected =
        state.status.connected && state.status.ssid == network.ssid;
    final open = _openSsid == network.ssid;
    // Every row in the card carries a marker, because every row does
    // something when tapped — the mockups draw `▸` on all four. It marks the
    // row as actionable rather than promising an expansion specifically:
    // only a network the console has a relationship with has more than one
    // thing to do with it and opens in place. The others act on the tap (an
    // open network joins, a secured one raises the passphrase sheet), which
    // is exactly what `NETWORK / wifi-password` draws — its list sits behind
    // the sheet with every row still collapsed.
    final opens = connected || network.saved;

    final row = NetworkRow(
      key: Key('wifi_network_${network.ssid}'),
      title: network.ssid,
      subtitle: _subtitle(l10n, state, network, connected: connected),
      state: _stateWord(l10n, network, connected: connected),
      expanded: opens && open,
      showDivider: !last && !open,
      onTap: state.busy
          ? null
          : () {
              if (opens) {
                setState(() => _openSsid = open ? null : network.ssid);
                return;
              }
              unawaited(_join(context, cubit, state, network.ssid));
            },
    );

    // A row that never opens stays a bare row; one that can open keeps its
    // container in the tree either way, so opening animates instead of
    // swapping one widget for another.
    if (!opens) return row;

    return NetworkExpandedRow(
      row: row,
      expanded: open,
      actions: [
        if (connected)
          NetworkActionChip(
            key: const Key('wifi_disconnect'),
            label: l10n.wifiDisconnectTitle,
            icon: Icons.link_off,
            // Reversible — tapping the row again reconnects — so it asks
            // nothing.
            onPressed: state.busy ? null : () => unawaited(cubit.disconnect()),
          )
        else
          NetworkActionChip(
            key: const Key('wifi_connect'),
            label: l10n.wifiJoinAction,
            icon: Icons.wifi,
            onPressed: state.busy || !network.inRange
                ? null
                : () => unawaited(_join(context, cubit, state, network.ssid)),
          ),
        if (network.saved)
          NetworkActionChip(
            key: const Key('wifi_forget'),
            label: l10n.wifiForget,
            icon: Icons.delete_outline,
            destructive: true,
            onPressed: state.busy
                ? null
                : () => unawaited(_confirmForget(context, cubit, network.ssid)),
          ),
      ],
    );
  }

  String? _subtitle(
    AppLocalizations l10n,
    WifiState state,
    WifiNetwork network, {
    required bool connected,
  }) {
    if (connected) {
      final ip = state.status.ip;
      // The mockups also put a link rate here. The helper reports none, and a
      // rate the app cannot know is not drawn as a zero.
      return ip.isEmpty ? null : ip;
    }
    if (!network.inRange) return l10n.wifiNotInRange;
    final signal = l10n.wifiSignalDbm(network.signal);
    return network.secured ? '$signal · ${l10n.wifiSecurityWpa2}' : signal;
  }

  String? _stateWord(
    AppLocalizations l10n,
    WifiNetwork network, {
    required bool connected,
  }) {
    if (connected) return l10n.networkStateConnected;
    if (network.saved) return l10n.networkStateSaved;
    if (!network.secured) return l10n.networkStateOpen;
    return null;
  }

  Future<void> _join(
    BuildContext context,
    WifiCubit cubit,
    WifiState state,
    String ssid,
  ) async {
    final network = state.networks.where((n) => n.ssid == ssid).firstOrNull;
    // A saved network already holds its credential; asking again for a
    // passphrase the console has is a question with a known answer.
    if (network != null && (!network.secured || network.saved)) {
      await cubit.connect(ssid);
      return;
    }
    final psk = await showWifiJoinSheet(
      context,
      ssid: ssid,
      security: context.mounted ? context.l10n.wifiSecurityWpa2 : null,
    );
    if (psk == null) return;
    await cubit.connect(ssid, psk: psk);
  }

  Future<void> _confirmForget(
    BuildContext context,
    WifiCubit cubit,
    String ssid,
  ) async {
    final l10n = context.l10n;
    final confirmed = await showNetworkForgetDialog(
      context,
      title: l10n.wifiForgetTitleNamed(ssid),
      body: l10n.wifiForgetBody,
      confirmLabel: l10n.wifiForgetConfirmAction,
    );
    if (!confirmed) return;
    setState(() => _openSsid = null);
    await cubit.forget(ssid);
  }
}
