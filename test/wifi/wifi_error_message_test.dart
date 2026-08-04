import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/wifi/wifi_error_message.dart';

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  test('maps authentication failures to the password hint', () {
    expect(
      wifiErrorMessage(
        l10n,
        'segno-wifi-ctl: authentication failed for network 0 (wrong password?)',
      ),
      l10n.wifiConnectFailedPassword,
    );
  });

  test('maps association timeouts', () {
    expect(
      wifiErrorMessage(
        l10n,
        'segno-wifi-ctl: timed out waiting for association (state=ASSOCIATED)',
      ),
      l10n.wifiConnectFailedTimeout,
    );
  });

  test('maps generic helper process failures', () {
    expect(
      wifiErrorMessage(
        l10n,
        'ProcessException: segno-wifi-ctl failed',
      ),
      l10n.wifiConnectFailedGeneric,
    );
  });

  test('maps NetworkManager secrets errors to the password hint', () {
    expect(
      wifiErrorMessage(
        l10n,
        'Error: Connection activation failed: (7) Secrets were required, '
        'but not provided.',
      ),
      l10n.wifiConnectFailedPassword,
    );
  });
}
