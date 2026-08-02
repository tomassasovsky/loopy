import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/wifi/cubit/wifi_cubit.dart';
import 'package:loopy/wifi/wifi_env.dart';

class _FakeWifiEnv implements WifiEnv {
  _FakeWifiEnv({
    this.supported = true,
    List<WifiNetwork>? networks,
    this.connectError,
    this.forgetError,
  }) : networks = networks ?? const [];

  final bool supported;
  List<WifiNetwork> networks;
  String? connectError;
  String? forgetError;

  int scans = 0;
  String? connectedSsid;
  String? connectedPassword;
  String? forgotten;

  @override
  bool get isSupported => supported;

  @override
  Future<List<WifiNetwork>> scan() async {
    scans++;
    return networks;
  }

  @override
  Future<String?> connect({required String ssid, String? password}) async {
    connectedSsid = ssid;
    connectedPassword = password;
    return connectError;
  }

  @override
  Future<String?> forget(String ssid) async {
    forgotten = ssid;
    return forgetError;
  }
}

const _home = WifiNetwork(ssid: 'HomeNet', signal: 80, secured: true);
const _open = WifiNetwork(ssid: 'Cafe', signal: 50, secured: false);

void main() {
  group('WifiCubit', () {
    test('an unsupported platform reports so and never scans', () async {
      // Desktop: the host OS owns the radio.
      final env = _FakeWifiEnv(supported: false);
      final cubit = WifiCubit(env: env);

      await cubit.refresh();

      expect(cubit.state.supported, isFalse);
      expect(env.scans, 0);
      await cubit.close();
    });

    test('refresh publishes the scan and clears busy', () async {
      final env = _FakeWifiEnv(networks: const [_home, _open]);
      final cubit = WifiCubit(env: env);

      await cubit.refresh();

      expect(cubit.state.supported, isTrue);
      expect(cubit.state.networks, const [_home, _open]);
      expect(cubit.state.busy, isFalse);
      await cubit.close();
    });

    test('connect passes the password through and re-scans', () async {
      final env = _FakeWifiEnv(networks: const [_home]);
      final cubit = WifiCubit(env: env);
      await cubit.refresh();
      final scansBefore = env.scans;

      await cubit.connect(_home, password: 'hunter2');

      expect(env.connectedSsid, 'HomeNet');
      expect(env.connectedPassword, 'hunter2');
      expect(env.scans, greaterThan(scansBefore));
      expect(cubit.state.message, isNull);
      await cubit.close();
    });

    test('a failed join keeps its reason through the re-scan', () async {
      // The re-scan that follows a failure must not wipe the only explanation
      // the user gets.
      final env = _FakeWifiEnv(
        networks: const [_home],
        connectError: 'Secrets were required, but not provided',
      );
      final cubit = WifiCubit(env: env);
      await cubit.refresh();

      await cubit.connect(_home, password: 'wrong');

      expect(cubit.state.message, 'Secrets were required, but not provided');
      expect(cubit.state.busy, isFalse);
      await cubit.close();
    });

    test('a later success clears the previous failure', () async {
      final env = _FakeWifiEnv(networks: const [_home], connectError: 'nope');
      final cubit = WifiCubit(env: env);
      await cubit.refresh();
      await cubit.connect(_home, password: 'wrong');
      expect(cubit.state.message, isNotNull);

      env.connectError = null;
      await cubit.connect(_home, password: 'right');

      expect(cubit.state.message, isNull);
      await cubit.close();
    });

    test('forget deletes the profile and re-scans', () async {
      final env = _FakeWifiEnv(networks: const [_home]);
      final cubit = WifiCubit(env: env);
      await cubit.refresh();
      final scansBefore = env.scans;

      await cubit.forget(_home);

      expect(env.forgotten, 'HomeNet');
      expect(env.scans, greaterThan(scansBefore));
      await cubit.close();
    });

    test('a failed forget surfaces its reason', () async {
      final env = _FakeWifiEnv(
        networks: const [_home],
        forgetError: 'Unknown connection',
      );
      final cubit = WifiCubit(env: env);

      await cubit.forget(_home);

      expect(cubit.state.message, 'Unknown connection');
      await cubit.close();
    });

    test('active reports the connected network', () async {
      const connected = WifiNetwork(
        ssid: 'HomeNet',
        signal: 80,
        secured: true,
        active: true,
      );
      final env = _FakeWifiEnv(networks: const [connected, _open]);
      final cubit = WifiCubit(env: env);

      await cubit.refresh();

      expect(cubit.state.active, connected);
      await cubit.close();
    });

    test('active is null with nothing connected', () async {
      final env = _FakeWifiEnv(networks: const [_home, _open]);
      final cubit = WifiCubit(env: env);

      await cubit.refresh();

      expect(cubit.state.active, isNull);
      await cubit.close();
    });
  });
}
