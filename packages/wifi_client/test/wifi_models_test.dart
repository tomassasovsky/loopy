import 'package:test/test.dart';
import 'package:wifi_client/wifi_client.dart';

void main() {
  group('WifiStatus.fromJson', () {
    test('parses enabled and connected', () {
      const status = WifiStatus(
        supported: true,
        enabled: true,
        connected: true,
        ssid: 'Studio',
        ip: '10.0.0.2',
        signal: -40,
      );
      final parsed = WifiStatus.fromJson(const {
        'supported': true,
        'enabled': true,
        'connected': true,
        'ssid': 'Studio',
        'ip': '10.0.0.2',
        'signal': -40,
      });
      expect(parsed, status);
      expect(parsed.enabled, isTrue);
      expect(parsed.connected, isTrue);
    });

    test('allows enabled without connected', () {
      final status = WifiStatus.fromJson(const {
        'supported': true,
        'enabled': true,
        'connected': false,
        'ssid': '',
        'ip': '',
        'signal': 0,
      });
      expect(status.enabled, isTrue);
      expect(status.connected, isFalse);
    });
  });
}
