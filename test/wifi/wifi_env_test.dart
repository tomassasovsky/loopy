import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/wifi/wifi_env.dart';

void main() {
  group('parseNmcliFields', () {
    test('splits on colons', () {
      expect(parseNmcliFields('a:b:c'), ['a', 'b', 'c']);
    });

    test('keeps an escaped colon inside a field', () {
      // nmcli escapes a literal colon as \:. Splitting naively tears the SSID
      // apart and shifts every following column, so signal and security get
      // read off the wrong fields entirely.
      expect(parseNmcliFields(r'*:my\:net:70:WPA2'), [
        '*',
        'my:net',
        '70',
        'WPA2',
      ]);
    });

    test('keeps an escaped backslash', () {
      expect(parseNmcliFields(r'a:b\\c'), ['a', r'b\c']);
    });

    test('preserves empty fields', () {
      expect(parseNmcliFields('::70:'), ['', '', '70', '']);
    });
  });

  group('parseWifiList', () {
    test('parses a typical listing', () {
      final networks = parseWifiList('''
*:HomeNet:82:WPA2
:Cafe:55:
:Neighbour:31:WPA1 WPA2
''');

      expect(networks.map((n) => n.ssid), ['HomeNet', 'Cafe', 'Neighbour']);
      expect(networks.first.active, isTrue);
      expect(networks.first.signal, 82);
      expect(networks[1].secured, isFalse, reason: 'empty security is open');
      expect(networks[2].secured, isTrue);
    });

    test('treats -- as an open network', () {
      final networks = parseWifiList(':Cafe:55:--');
      expect(networks.single.secured, isFalse);
    });

    test('drops hidden networks', () {
      // An empty SSID is not tappable, and joining one needs a name typed by
      // hand anyway.
      final networks = parseWifiList('''
::64:WPA2
:Real:20:WPA2
''');
      expect(networks.map((n) => n.ssid), ['Real']);
    });

    test('collapses duplicate SSIDs, keeping the strongest', () {
      // The same network appears once per band and per access point.
      final networks = parseWifiList('''
:HomeNet:40:WPA2
:HomeNet:88:WPA2
''');
      expect(networks, hasLength(1));
      expect(networks.single.signal, 88);
    });

    test('a weaker duplicate never erases the active flag', () {
      final networks = parseWifiList('''
*:HomeNet:40:WPA2
:HomeNet:88:WPA2
''');
      expect(networks.single.active, isTrue);
      expect(networks.single.signal, 88);
    });

    test('sorts connected first, then by signal', () {
      final networks = parseWifiList('''
:Weak:10:WPA2
*:Mine:45:WPA2
:Strong:90:WPA2
''');
      expect(networks.map((n) => n.ssid), ['Mine', 'Strong', 'Weak']);
    });

    test('marks saved networks', () {
      final networks = parseWifiList(
        ':HomeNet:80:WPA2',
        savedSsids: {'HomeNet'},
      );
      expect(networks.single.saved, isTrue);
    });

    test('survives junk and short lines', () {
      final networks = parseWifiList('''

garbage
:OK:50:WPA2
''');
      expect(networks.map((n) => n.ssid), ['OK']);
    });

    test('clamps an out-of-range signal', () {
      expect(parseWifiList(':A:900:WPA2').single.signal, 100);
      expect(parseWifiList(':A:not a number:WPA2').single.signal, 0);
    });

    test('handles an SSID containing a colon end to end', () {
      final networks = parseWifiList(r':my\:net:70:WPA2');
      expect(networks.single.ssid, 'my:net');
      expect(networks.single.signal, 70);
      expect(networks.single.secured, isTrue);
    });
  });

  group('parseSavedConnections', () {
    test('reads names, ignoring blanks', () {
      expect(parseSavedConnections('HomeNet\n\nCafe\n'), {'HomeNet', 'Cafe'});
    });

    test('unescapes a colon in a saved name', () {
      expect(parseSavedConnections(r'my\:net'), {'my:net'});
    });
  });
}
