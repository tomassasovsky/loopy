import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/wifi/cubit/wifi_cubit.dart';
import 'package:loopy/wifi/system_wifi_env.dart';
import 'package:loopy/wifi/wifi_env.dart';

/// Opens the Wi-Fi picker.
///
/// Pushed as a route rather than shown in the tray: joining a network involves
/// a password and an on-screen keyboard, which needs the height.
Future<void> showWifiPage(BuildContext context, {WifiEnv? env}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WifiPage(env: env ?? const SystemWifiEnv()),
      ),
    );

/// The console's Wi-Fi picker: scan, join, forget.
class WifiPage extends StatelessWidget {
  /// Creates a [WifiPage] over [env].
  const WifiPage({required this.env, super.key});

  /// The OS boundary; injected so tests need no radio.
  final WifiEnv env;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) {
      final cubit = WifiCubit(env: env);
      unawaited(cubit.refresh());
      return cubit;
    },
    child: const _WifiView(),
  );
}

class _WifiView extends StatelessWidget {
  const _WifiView();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.watch<WifiCubit>();
    final state = cubit.state;

    return Scaffold(
      key: const Key('wifiPage'),
      appBar: AppBar(
        title: Text(l10n.trayWifiLabel),
        actions: [
          IconButton(
            key: const Key('wifiPage_refresh'),
            tooltip: l10n.wifiRescan,
            onPressed: state.busy ? null : () => unawaited(cubit.refresh()),
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: state.busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: !state.supported
          ? Center(
              key: const Key('wifiPage_unsupported'),
              child: Text(l10n.wifiUnsupported),
            )
          : Column(
              children: [
                if (state.message case final message?)
                  Material(
                    key: const Key('wifiPage_message'),
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline, size: 18),
                          const SizedBox(width: 8),
                          Expanded(child: Text(message)),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: state.networks.isEmpty && !state.busy
                      ? Center(
                          key: const Key('wifiPage_empty'),
                          child: Text(l10n.wifiNoNetworks),
                        )
                      : ListView.builder(
                          itemCount: state.networks.length,
                          itemBuilder: (context, index) =>
                              _NetworkRow(state.networks[index]),
                        ),
                ),
              ],
            ),
    );
  }
}

class _NetworkRow extends StatelessWidget {
  const _NetworkRow(this.network);

  final WifiNetwork network;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<WifiCubit>();
    return ListTile(
      key: Key('wifiNetwork_${network.ssid}'),
      leading: Icon(_signalIcon(network.signal)),
      title: Text(network.ssid),
      subtitle: Text(
        network.active
            ? l10n.wifiConnected
            : network.secured
            ? l10n.wifiSecured
            : l10n.wifiOpen,
      ),
      trailing: network.saved
          ? IconButton(
              key: Key('wifiForget_${network.ssid}'),
              tooltip: l10n.wifiForget,
              onPressed: () => unawaited(cubit.forget(network)),
              icon: const Icon(Icons.delete_outline),
            )
          : null,
      onTap: network.active
          ? null
          : () => unawaited(_join(context, cubit, network)),
    );
  }

  Future<void> _join(
    BuildContext context,
    WifiCubit cubit,
    WifiNetwork network,
  ) async {
    // A saved or open network needs no password — asking for one we already
    // hold is the kind of friction this whole screen exists to remove.
    if (!network.secured || network.saved) {
      await cubit.connect(network);
      return;
    }
    final password = await _askPassword(context, network.ssid);
    if (password == null || password.isEmpty) return;
    await cubit.connect(network, password: password);
  }

  Future<String?> _askPassword(BuildContext context, String ssid) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final l10n = dialogContext.l10n;
        return AlertDialog(
          key: const Key('wifiPassword_dialog'),
          title: Text(ssid),
          content: _PasswordField(controller: controller),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              key: const Key('wifiPassword_join'),
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: Text(l10n.wifiJoin),
            ),
          ],
        );
      },
    ).whenComplete(controller.dispose);
  }

  static IconData _signalIcon(int signal) => switch (signal) {
    >= 75 => Icons.signal_wifi_4_bar,
    >= 50 => Icons.network_wifi_3_bar,
    >= 25 => Icons.network_wifi_2_bar,
    _ => Icons.network_wifi_1_bar,
  };
}

class _PasswordField extends StatefulWidget {
  const _PasswordField({required this.controller});

  final TextEditingController controller;

  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) => TextField(
    key: const Key('wifiPassword_field'),
    controller: widget.controller,
    autofocus: true,
    obscureText: _obscured,
    // Not TextInputType.visiblePassword: that would be honest, but the
    // on-screen keyboard picks its layout from this and a Wi-Fi key is
    // ordinary text. It already maps password types to QWERTY; this keeps
    // the intent obvious at the call site too.
    keyboardType: TextInputType.text,
    decoration: InputDecoration(
      labelText: context.l10n.wifiPassword,
      suffixIcon: IconButton(
        key: const Key('wifiPassword_reveal'),
        // Typing a long key blind on a touchscreen, on stage, is how you end
        // up retyping it three times.
        onPressed: () => setState(() => _obscured = !_obscured),
        icon: Icon(_obscured ? Icons.visibility : Icons.visibility_off),
      ),
    ),
  );
}
