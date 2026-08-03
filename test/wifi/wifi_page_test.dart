import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/wifi/wifi_cubit.dart';
import 'package:loopy/wifi/wifi_page.dart';
import 'package:wifi_repository/wifi_repository.dart';

class _FakeWifiClient implements WifiClient {
  _FakeWifiClient({
    WifiStatus? status,
    List<WifiNetwork>? networks,
  }) : supported = true,
       statusValue =
           status ??
           const WifiStatus(
             supported: true,
             enabled: true,
             connected: false,
           ),
       networks = List.of(networks ?? const []);

  bool supported;
  WifiStatus statusValue;
  List<WifiNetwork> networks;
  Completer<void>? connectGate;

  @override
  bool get isSupported => supported;

  @override
  Future<WifiStatus> status() async => statusValue;

  @override
  Future<List<WifiNetwork>> scan() async => networks;

  @override
  Future<void> connect(String ssid, {String? psk}) async {
    final gate = connectGate;
    if (gate != null) await gate.future;
    statusValue = WifiStatus(
      supported: true,
      enabled: true,
      connected: true,
      ssid: ssid,
      ip: '10.0.0.2',
      signal: -40,
    );
  }

  @override
  Future<void> disconnect() async {
    statusValue = const WifiStatus(
      supported: true,
      enabled: true,
      connected: false,
    );
  }

  @override
  Future<void> forget(String ssid) async {}

  @override
  Future<void> setEnabled({required bool enabled}) async {
    statusValue = WifiStatus(
      supported: true,
      enabled: enabled,
      connected: false,
    );
  }
}

void main() {
  testWidgets('shows unsupported body when the helper is absent', (
    tester,
  ) async {
    final cubit = WifiCubit(
      repository: const WifiRepository(client: UnsupportedWifiClient()),
    );
    addTearDown(cubit.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider.value(
          value: cubit,
          child: const WifiPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.byKey(const Key('wifi_page')), findsOneWidget);
    expect(find.text(l10n.wifiUnsupportedBody), findsOneWidget);
  });

  testWidgets('shows connecting spinner on the joining network row', (
    tester,
  ) async {
    final client = _FakeWifiClient(
      networks: const [
        WifiNetwork(ssid: 'Cafe', signal: -40, secured: false),
      ],
    )..connectGate = Completer<void>();
    final cubit = WifiCubit(repository: WifiRepository(client: client));
    addTearDown(cubit.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider.value(
          value: cubit,
          child: const WifiPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.tap(find.byKey(const Key('wifi_network_Cafe')));
    await tester.pump();

    expect(cubit.state.connectingSsid, 'Cafe');
    // Joining feedback lives on the found-networks row only — not the
    // connected slot — until association succeeds.
    expect(find.byKey(const Key('wifi_status_spinner')), findsNothing);
    expect(find.byKey(const Key('wifi_network_spinner_Cafe')), findsOneWidget);
    // The joining row swaps its signal readout for the spinner rather than
    // adding a label, so "Connecting…" reaches the user through semantics.
    expect(
      tester.widgetList<Semantics>(find.byType(Semantics)).any((s) {
        final label = s.properties.label ?? '';
        return label.contains('Cafe') &&
            label.contains(l10n.wifiConnectingLabel);
      }),
      isTrue,
    );
    expect(find.textContaining(l10n.wifiStatusDisconnected), findsOneWidget);

    client.connectGate!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wifi_network_spinner_Cafe')), findsNothing);
    expect(find.textContaining(l10n.wifiStatusConnected), findsOneWidget);
    // Connected SSID moves out of the found list into the status strip.
    expect(find.byKey(const Key('wifi_network_Cafe')), findsNothing);
  });
}
