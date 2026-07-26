import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/appliance/host_page_chrome.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/setup/setup_surface.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/wifi/wifi_cubit.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:wifi_repository/wifi_repository.dart';

/// In-tray WiFi face — fills the Control Center radio division until Back.
class WifiTrayPanel extends StatefulWidget {
  /// Creates a [WifiTrayPanel].
  const WifiTrayPanel({required this.onBack, super.key});

  /// Returns to the tray home tiles (does not dismiss the tray).
  final VoidCallback onBack;

  @override
  State<WifiTrayPanel> createState() => _WifiTrayPanelState();
}

class _WifiTrayPanelState extends State<WifiTrayPanel> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final cubit = context.read<WifiCubit>();
      await cubit.load();
      if (!mounted) return;
      if (cubit.state.supported) await cubit.scan();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final state = context.watch<WifiCubit>().state;
    final cubit = context.read<WifiCubit>();

    return KeyedSubtree(
      key: const Key('wifi_tray_panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HostTrayChromeBar(
            backKey: const Key('wifi_back'),
            title: l10n.trayWifiLabel,
            onBack: widget.onBack,
            trailing: state.supported
                ? HostChromeIconButton(
                    key: const Key('wifi_scan'),
                    icon: Icons.refresh,
                    spinner: state.scanning,
                    tooltip: state.scanning
                        ? l10n.wifiScanningSubtitle
                        : l10n.wifiScanTitle,
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
                  l10n.wifiUnsupportedBody,
                  textAlign: TextAlign.center,
                  style: setupBody,
                ),
              ),
            )
          else ...[
            _StatusCard(state: state, cubit: cubit),
            if (state.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                state.errorMessage!,
                style: setupBody.copyWith(fontSize: 12),
              ),
            ],
            const SizedBox(height: 16),
            SetupGroupLabel(l10n.wifiNetworksGroup),
            const SizedBox(height: 8),
            Expanded(
              child: state.networks.isEmpty && !state.scanning
                  ? Align(
                      alignment: Alignment.topLeft,
                      child: Text(l10n.wifiEmptyNetworks, style: setupBody),
                    )
                  : DecoratedBox(
                      decoration: BoxDecoration(
                        color: surface.card.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: surface.line),
                      ),
                      child: ListView.separated(
                        padding: EdgeInsets.zero,
                        itemCount: state.networks.length,
                        separatorBuilder: (_, _) =>
                            Divider(height: 1, color: surface.line),
                        itemBuilder: (context, index) {
                          final network = state.networks[index];
                          final connecting =
                              state.connectingSsid == network.ssid;
                          return _NetworkRow(
                            network: network,
                            connecting: connecting,
                            onTap: state.busy
                                ? null
                                : () => unawaited(
                                    _join(context, cubit, network),
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

  Future<void> _join(
    BuildContext context,
    WifiCubit cubit,
    WifiNetwork network,
  ) async {
    final l10n = context.l10n;
    if (!network.secured) {
      await cubit.connect(network.ssid);
      return;
    }
    final controller = TextEditingController();
    final psk = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('wifi_password_dialog'),
        title: Text(l10n.wifiPasswordTitle(network.ssid)),
        content: TextField(
          key: const Key('wifi_password_field'),
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(hintText: l10n.wifiPasswordHint),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          TextButton(
            key: const Key('wifi_password_join'),
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(l10n.wifiJoinAction),
          ),
        ],
      ),
    );
    controller.dispose();
    if (psk == null || !context.mounted) return;
    await cubit.connect(network.ssid, psk: psk);
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state, required this.cubit});

  final WifiState state;
  final WifiCubit cubit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final connectingSsid = state.connectingSsid;
    final connecting = connectingSsid != null;
    final disconnecting = state.disconnecting;
    final connected = state.status.connected && !connecting && !disconnecting;
    final ssid = connecting
        ? connectingSsid
        : (state.status.ssid.isEmpty ? '—' : state.status.ssid);
    final ip = state.status.ip.isEmpty ? '—' : state.status.ip;
    final detail = connecting
        ? l10n.wifiConnectingLabel
        : disconnecting
        ? l10n.wifiStatusDisconnecting
        : connected
        ? '${l10n.wifiStatusConnected} · $ip'
        : l10n.wifiStatusDisconnected;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface.card.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: surface.line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (connecting || disconnecting)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      key: const Key('wifi_status_spinner'),
                      strokeWidth: 2,
                      color: surface.accent,
                    ),
                  )
                else
                  Icon(
                    connected ? Icons.wifi : Icons.wifi_off,
                    size: 18,
                    color: connected ? surface.accent : surface.textTertiary,
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: ssid,
                          style: TextStyle(
                            color: surface.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        TextSpan(
                          text: '  $detail',
                          style: TextStyle(
                            color: surface.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (connected) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  HostActionChip(
                    key: const Key('wifi_disconnect'),
                    label: l10n.wifiDisconnectTitle,
                    icon: Icons.link_off,
                    onPressed: state.busy
                        ? null
                        : () => unawaited(cubit.disconnect()),
                  ),
                  HostActionChip(
                    key: const Key('wifi_forget'),
                    label: l10n.wifiForgetTitle,
                    icon: Icons.delete_outline,
                    onPressed: state.busy
                        ? null
                        : () => unawaited(_confirmForget(context, cubit, ssid)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmForget(
    BuildContext context,
    WifiCubit cubit,
    String ssid,
  ) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.wifiForgetTitle),
        content: Text(l10n.wifiForgetConfirm(ssid)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            key: const Key('wifi_forget_confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.wifiForgetTitle),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await cubit.forget(ssid);
  }
}

class _NetworkRow extends StatelessWidget {
  const _NetworkRow({
    required this.network,
    required this.connecting,
    required this.onTap,
  });

  final WifiNetwork network;
  final bool connecting;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return FocusableTapTarget(
      onTap: onTap,
      semanticLabel: connecting
          ? '${network.ssid}, ${l10n.wifiConnectingLabel}'
          : network.ssid,
      child: InkWell(
        key: Key('wifi_network_${network.ssid}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(
                network.secured ? Icons.lock_outline : Icons.wifi,
                size: 16,
                color: surface.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  network.ssid,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (connecting)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    key: Key('wifi_network_spinner_${network.ssid}'),
                    strokeWidth: 2,
                    color: surface.accent,
                  ),
                )
              else
                Text(
                  '${network.signal} dBm',
                  style: TextStyle(
                    color: surface.textTertiary,
                    fontSize: 11,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
