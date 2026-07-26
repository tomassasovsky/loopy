import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/wifi/wifi_cubit.dart';
import 'package:wifi_repository/wifi_repository.dart';

class _FakeWifiClient implements WifiClient {
  _FakeWifiClient({
    this.supported = true,
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
}
