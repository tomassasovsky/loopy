import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/wifi/wifi_cubit.dart';
import 'package:wifi_repository/wifi_repository.dart';

class _FakeWifiClient implements WifiClient {
  _FakeWifiClient({
    this.supported = true,
    this.connectFails = false,
    WifiStatus? status,
    List<WifiNetwork>? networks,
  }) : statusValue =
           status ??
           const WifiStatus(
             supported: true,
             enabled: true,
             connected: false,
           ),
       networks = List.of(networks ?? const []);

  bool supported;

  /// When true, every [connect] refuses the way the supplicant does.
  bool connectFails;
  WifiStatus statusValue;
  List<WifiNetwork> networks;
  final connects = <(String, String?)>[];
  int disconnectCalls = 0;
  final forgotten = <String>[];
  Completer<void>? connectGate;

  @override
  bool get isSupported => supported;

  @override
  Future<WifiStatus> status() async => statusValue;

  @override
  Future<List<WifiNetwork>> scan() async => networks;

  @override
  Future<void> connect(String ssid, {String? psk}) async {
    connects.add((ssid, psk));
    final gate = connectGate;
    if (gate != null) await gate.future;
    if (connectFails) throw StateError('authentication failed');
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
    disconnectCalls++;
    statusValue = const WifiStatus(
      supported: true,
      enabled: true,
      connected: false,
    );
  }

  @override
  Future<void> forget(String ssid) async {
    forgotten.add(ssid);
    networks = [
      for (final n in networks)
        if (n.ssid != ssid) n,
    ];
    if (statusValue.ssid == ssid) {
      statusValue = const WifiStatus(
        supported: true,
        enabled: true,
        connected: false,
      );
    }
  }

  @override
  Future<void> setEnabled({required bool enabled}) async {
    statusValue = WifiStatus(
      supported: true,
      enabled: enabled,
      connected: enabled && statusValue.connected,
      ssid: enabled ? statusValue.ssid : '',
      ip: enabled ? statusValue.ip : '',
      signal: statusValue.signal,
    );
  }
}

WifiRepository _repo(_FakeWifiClient client) => WifiRepository(client: client);

void main() {
  group('WifiCubit', () {
    blocTest<WifiCubit, WifiState>(
      'load marks unsupported when helper missing',
      build: () => WifiCubit(
        repository: _repo(
          _FakeWifiClient(
            supported: false,
            status: WifiStatus.unsupported,
          ),
        ),
      ),
      act: (cubit) => cubit.load(),
      expect: () => [
        const WifiState(busy: true),
        const WifiState(),
      ],
    );

    blocTest<WifiCubit, WifiState>(
      'scan dedupes by ssid keeping the stronger signal',
      build: () => WifiCubit(
        repository: _repo(
          _FakeWifiClient(
            networks: const [
              WifiNetwork(ssid: 'Cafe', signal: -70, secured: true),
              WifiNetwork(ssid: 'Cafe', signal: -40, secured: true),
              WifiNetwork(ssid: 'OpenNet', signal: -55, secured: false),
            ],
          ),
        ),
      ),
      act: (cubit) async {
        await cubit.load();
        await cubit.scan();
      },
      verify: (cubit) {
        expect(cubit.state.networks.map((n) => n.ssid), ['Cafe', 'OpenNet']);
        expect(cubit.state.networks.first.signal, -40);
      },
    );

    blocTest<WifiCubit, WifiState>(
      'connect updates status',
      build: () => WifiCubit(repository: _repo(_FakeWifiClient())),
      act: (cubit) async {
        await cubit.load();
        await cubit.connect('Home', psk: 'secret');
      },
      verify: (cubit) {
        expect(cubit.state.status.connected, isTrue);
        expect(cubit.state.status.ssid, 'Home');
        expect(cubit.state.connectingSsid, isNull);
        expect(cubit.state.busy, isFalse);
      },
    );

    test('connect exposes connectingSsid while join is in flight', () async {
      final client = _FakeWifiClient()..connectGate = Completer<void>();
      final cubit = WifiCubit(repository: _repo(client));
      addTearDown(cubit.close);

      await cubit.load();
      final pending = cubit.connect('Home', psk: 'secret');
      await pumpEventQueue();
      expect(cubit.state.connectingSsid, 'Home');
      expect(cubit.state.busy, isTrue);

      client.connectGate!.complete();
      await pending;
      expect(cubit.state.connectingSsid, isNull);
      expect(cubit.state.status.ssid, 'Home');
    });

    blocTest<WifiCubit, WifiState>(
      'disconnect clears association',
      build: () => WifiCubit(
        repository: _repo(
          _FakeWifiClient(
            status: const WifiStatus(
              supported: true,
              enabled: true,
              connected: true,
              ssid: 'Home',
              ip: '10.0.0.2',
            ),
          ),
        ),
      ),
      act: (cubit) async {
        await cubit.load();
        await cubit.disconnect();
      },
      verify: (cubit) {
        expect(cubit.state.status.connected, isFalse);
      },
    );

    blocTest<WifiCubit, WifiState>(
      'toggleEnabled flips radio',
      build: () => WifiCubit(repository: _repo(_FakeWifiClient())),
      act: (cubit) async {
        await cubit.load();
        await cubit.toggleEnabled();
      },
      verify: (cubit) {
        expect(cubit.state.status.enabled, isFalse);
      },
    );
  });

  group('the failure is tied to the network it was about', () {
    blocTest<WifiCubit, WifiState>(
      'a refused join records the SSID alongside the message, so a stale '
      'name can never outlive the banner that used it',
      build: () => WifiCubit(
        repository: _repo(_FakeWifiClient(connectFails: true)),
      ),
      act: (cubit) async {
        await cubit.load();
        await cubit.connect('Studio 5G', psk: 'nope');
      },
      verify: (cubit) {
        expect(cubit.state.failedSsid, 'Studio 5G');
        expect(cubit.state.errorMessage, isNotNull);
      },
    );

    blocTest<WifiCubit, WifiState>(
      'the next attempt clears both together',
      build: () {
        final client = _FakeWifiClient(connectFails: true);
        return WifiCubit(repository: _repo(client));
      },
      act: (cubit) async {
        await cubit.load();
        await cubit.connect('Studio 5G', psk: 'nope');
        await cubit.scan();
      },
      verify: (cubit) {
        expect(cubit.state.failedSsid, isNull);
        expect(cubit.state.errorMessage, isNull);
      },
    );

    blocTest<WifiCubit, WifiState>(
      'cancelConnect drops the in-flight marker and disconnects — the only '
      'thing still true once the helper call has been issued',
      build: () => WifiCubit(repository: _repo(_FakeWifiClient())),
      act: (cubit) async {
        await cubit.load();
        final joining = cubit.connect('Studio 5G');
        expect(cubit.state.connectingSsid, 'Studio 5G');
        await joining;
        await cubit.connect('Studio 5G');
        await cubit.cancelConnect();
      },
      verify: (cubit) {
        expect(cubit.state.connectingSsid, isNull);
      },
    );

    blocTest<WifiCubit, WifiState>(
      'cancelConnect with nothing in flight emits nothing',
      build: () => WifiCubit(repository: _repo(_FakeWifiClient())),
      act: (cubit) async {
        await cubit.load();
        final before = cubit.state;
        await cubit.cancelConnect();
        expect(cubit.state, before);
      },
    );
  });
}
