import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/appliance/host_page_chrome.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/setup/setup_surface.dart';
import 'package:segno/theme/page_transitions.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/wifi/wifi_cubit.dart';
import 'package:segno/wifi/wifi_error_message.dart';
import 'package:segno/wifi/wifi_network_visibility.dart';
import 'package:wifi_repository/wifi_repository.dart';

/// Opens the WiFi surface as a full-screen page from the settings tray.
Future<void> showWifiPage(BuildContext context) {
  final repository = context.read<WifiRepository>();
  return Navigator.of(context).push(
    desktopPageRoute<void>(
      (_) => BlocProvider(
        create: (_) => WifiCubit(repository: repository),
        child: const WifiPage(),
      ),
    ),
  );
}

/// Console WiFi settings — dense, content-sized (no full-bleed card stacks).
///
/// Status + actions live in one compact strip under the chrome; the network
/// list is a single grouped card capped at 520px so labels and signal stay
/// visually connected on the 15.6in panel.
class WifiPage extends StatefulWidget {
  /// Creates a [WifiPage].
  const WifiPage({super.key});

  @override
  State<WifiPage> createState() => _WifiPageState();
}

class _WifiPageState extends State<WifiPage> {
  static const double _listMaxWidth = 520;

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

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(Navigator.of(context).maybePop()),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const Key('wifi_page'),
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
                    backKey: const Key('wifi_back'),
                    title: l10n.trayWifiLabel,
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
                  Expanded(
                    child: !state.supported
                        ? Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(
                              state.errorMessage != null
                                  ? wifiErrorMessage(
                                      l10n,
                                      state.errorMessage,
                                    )
                                  : l10n.wifiUnsupportedBody,
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
                                      _WifiStatusStrip(
                                        state: state,
                                        onDisconnect: state.busy
                                            ? null
                                            : () => unawaited(
                                                cubit.disconnect(),
                                              ),
                                        onForget:
                                            state.busy ||
                                                !state.status.connected
                                            ? null
                                            : () => unawaited(
                                                _confirmForget(
                                                  context,
                                                  cubit,
                                                  state.status.ssid,
                                                ),
                                              ),
                                      ),
                                      if (state.errorMessage != null) ...[
                                        const SizedBox(height: 8),
                                        Text(
                                          wifiErrorMessage(
                                            l10n,
                                            state.errorMessage,
                                          ),
                                          style: context.setupBody.copyWith(
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 14),
                                      _WifiNetworkList(
                                        state: state,
                                        onJoin: (network) => unawaited(
                                          _join(context, cubit, network),
                                        ),
                                        onForgetNetwork: (network) => unawaited(
                                          _confirmForget(
                                            context,
                                            cubit,
                                            network.ssid,
                                          ),
                                        ),
                                      ),
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

  Future<void> _join(
    BuildContext context,
    WifiCubit cubit,
    WifiNetwork network,
  ) async {
    final l10n = context.l10n;
    // An open network needs no secret, and a saved one already has its secret
    // stored (psk-flags=0) — NetworkManager will use it. Asking again for a
    // password the console is holding is how a user ends up re-typing a
    // correct key at a network that is failing for some entirely other reason
    // (#471, and #459 for what that costs).
    if (!network.secured || network.saved) {
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

/// One horizontal strip: SSID · status · IP + action chips.
///
/// While a join is in flight the joining SSID stays in the found-networks
/// list (with a spinner) — this strip only shows a real association.
class _WifiStatusStrip extends StatelessWidget {
  const _WifiStatusStrip({
    required this.state,
    required this.onDisconnect,
    required this.onForget,
  });

  final WifiState state;
  final VoidCallback? onDisconnect;
  final VoidCallback? onForget;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final disconnecting = state.disconnecting;
    final connected = state.status.connected && !disconnecting;
    final ssid = connected && state.status.ssid.isNotEmpty
        ? state.status.ssid
        : '—';
    final ip = state.status.ip.isEmpty ? '—' : state.status.ip;
    final detail = disconnecting
        ? l10n.wifiStatusDisconnecting
        : connected
        ? '${l10n.wifiStatusConnected} · $ip'
        : l10n.wifiStatusDisconnected;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface.card,
        borderRadius: BorderRadius.circular(SurfaceTheme.radius10),
        border: Border.all(color: surface.line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
        child: Row(
          children: [
            if (disconnecting)
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
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: Text.rich(
                  key: ValueKey<String>('$ssid|$detail'),
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
            ),
            if (connected) ...[
              const SizedBox(width: 8),
              HostActionChip(
                key: const Key('wifi_disconnect'),
                label: l10n.wifiDisconnectTitle,
                icon: Icons.link_off,
                onPressed: onDisconnect,
              ),
              const SizedBox(width: 6),
              HostActionChip(
                key: const Key('wifi_forget'),
                label: l10n.wifiForgetTitle,
                icon: Icons.delete_outline,
                onPressed: onForget,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WifiNetworkList extends StatelessWidget {
  const _WifiNetworkList({
    required this.state,
    required this.onJoin,
    required this.onForgetNetwork,
  });

  final WifiState state;
  final ValueChanged<WifiNetwork> onJoin;
  final ValueChanged<WifiNetwork> onForgetNetwork;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetupGroupLabel(l10n.wifiNetworksGroup),
        const SizedBox(height: 6),
        if (state.networks.isEmpty && !state.scanning)
          Text(l10n.wifiEmptyNetworks, style: context.setupBody)
        else
          DecoratedBox(
            decoration: BoxDecoration(
              color: surface.card,
              borderRadius: BorderRadius.circular(SurfaceTheme.radius10),
              border: Border.all(color: surface.line),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in visibleWifiNetworks(
                  state,
                ).asMap().entries) ...[
                  if (entry.key > 0) Divider(height: 1, color: surface.line),
                  _NetworkRow(
                    network: entry.value,
                    connecting: state.connectingSsid == entry.value.ssid,
                    onTap: state.busy || !entry.value.inRange
                        ? null
                        : () => onJoin(entry.value),
                    onForget: state.busy || !entry.value.saved
                        ? null
                        : () => onForgetNetwork(entry.value),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _NetworkRow extends StatelessWidget {
  const _NetworkRow({
    required this.network,
    required this.connecting,
    required this.onTap,
    required this.onForget,
  });

  final WifiNetwork network;
  final bool connecting;
  final VoidCallback? onTap;

  /// Offered on every saved network, in range or not. Requiring a connection
  /// first made a profile that refuses to connect impossible to remove (#471).
  final VoidCallback? onForget;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final String meta;
    if (connecting) {
      meta = l10n.wifiConnectingLabel;
    } else if (network.saved && !network.inRange) {
      meta = l10n.wifiSavedOutOfRange;
    } else if (network.saved) {
      meta = '${l10n.wifiSavedLabel} · ${network.signal}';
    } else if (network.secured) {
      meta = '${l10n.wifiSecuredLabel} · ${network.signal}';
    } else {
      meta = '${l10n.wifiOpenLabel} · ${network.signal}';
    }

    return FocusableTapTarget(
      onTap: onTap,
      semanticLabel: '${network.ssid}, $meta',
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
                color: onTap == null
                    ? surface.textTertiary
                    : surface.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  network.ssid,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: onTap == null
                        ? surface.textTertiary
                        : surface.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (network.saved && !connecting) ...[
                Text(
                  network.inRange
                      ? l10n.wifiSavedLabel
                      : l10n.wifiSavedOutOfRange,
                  style: TextStyle(color: surface.accent, fontSize: 11),
                ),
                IconButton(
                  key: Key('wifi_network_forget_${network.ssid}'),
                  onPressed: onForget,
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  color: surface.textTertiary,
                  tooltip: l10n.wifiForget,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
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
              else if (network.inRange)
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
