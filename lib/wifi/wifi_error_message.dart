import 'package:loopy/l10n/l10n.dart';

/// Maps raw helper / [ProcessException] text to a short operator-facing string.
String wifiErrorMessage(AppLocalizations l10n, String? raw) {
  if (raw == null || raw.isEmpty) return '';
  final lower = raw.toLowerCase();
  if (lower.contains('authentication failed') ||
      lower.contains('wrong password') ||
      lower.contains('invalid passphrase')) {
    return l10n.wifiConnectFailedPassword;
  }
  if (lower.contains('timed out waiting')) {
    return l10n.wifiConnectFailedTimeout;
  }
  if (lower.contains('loopy-wifi-ctl') || lower.contains('processexception')) {
    return l10n.wifiConnectFailedGeneric;
  }
  return raw;
}
