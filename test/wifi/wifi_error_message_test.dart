import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/wifi/wifi_error_message.dart';

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  test('maps authentication failures to the password hint', () {
    expect(
      wifiErrorMessage(
        l10n,
        'loopy-wifi-ctl: authentication failed for network 0 (wrong password?)',
      ),
      l10n.wifiConnectFailedPassword,
    );
  });

  test('maps association timeouts', () {
    expect(
      wifiErrorMessage(
        l10n,
        'loopy-wifi-ctl: timed out waiting for association (state=ASSOCIATED)',
      ),
      l10n.wifiConnectFailedTimeout,
    );
  });

  test('maps generic helper process failures', () {
    expect(
      wifiErrorMessage(
        l10n,
        "ProcessException: loopy-wifi-ctl failed",
      ),
      l10n.wifiConnectFailedGeneric,
    );
  });
}
