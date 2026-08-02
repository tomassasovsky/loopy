import 'package:flutter/foundation.dart';

/// One visible wireless network.
@immutable
class WifiNetwork {
  /// Creates a [WifiNetwork].
  const WifiNetwork({
    required this.ssid,
    required this.signal,
    required this.secured,
    this.active = false,
    this.saved = false,
  });

  /// The network name. Never empty — hidden networks are dropped, since there
  /// is nothing for the user to tap.
  final String ssid;

  /// Signal strength, 0-100.
  final int signal;

  /// Whether joining needs a password.
  final bool secured;

  /// Whether this is the network currently connected.
  final bool active;

  /// Whether a saved profile for it already exists, so joining needs no
  /// password.
  final bool saved;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WifiNetwork &&
          runtimeType == other.runtimeType &&
          ssid == other.ssid &&
          signal == other.signal &&
          secured == other.secured &&
          active == other.active &&
          saved == other.saved;

  @override
  int get hashCode => Object.hash(ssid, signal, secured, active, saved);

  @override
  String toString() =>
      'WifiNetwork($ssid, $signal%, secured: $secured, active: $active)';
}

/// The operating-system boundary the Wi-Fi feature depends on, injected so the
/// cubit is testable without a radio, a NetworkManager, or root.
///
/// The production implementation is `SystemWifiEnv`, which drives `nmcli`.
abstract interface class WifiEnv {
  /// Whether this platform manages Wi-Fi through us at all. `false` on desktop,
  /// where the host OS owns the radio and a second UI would fight it.
  bool get isSupported;

  /// Visible networks, strongest first. Never throws: an unreachable or absent
  /// NetworkManager yields an empty list rather than an error state the user
  /// cannot act on.
  Future<List<WifiNetwork>> scan();

  /// Joins [ssid], supplying [password] when the network is secured and no
  /// saved profile exists. Returns `null` on success, or a message to show.
  Future<String?> connect({required String ssid, String? password});

  /// Deletes the saved profile for [ssid]. Returns `null` on success, or a
  /// message to show.
  Future<String?> forget(String ssid);
}

/// Splits one line of `nmcli --terse` output on unescaped colons.
///
/// nmcli escapes a literal colon inside a field as `\:`, so a naive
/// `split(':')` tears SSIDs containing one into pieces and shifts every
/// following column — silently mislabelling security and signal.
List<String> parseNmcliFields(String line) {
  final fields = <String>[];
  final buffer = StringBuffer();
  var escaped = false;
  for (final rune in line.runes) {
    final char = String.fromCharCode(rune);
    if (escaped) {
      buffer.write(char);
      escaped = false;
      continue;
    }
    if (char == r'\') {
      escaped = true;
      continue;
    }
    if (char == ':') {
      fields.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  fields.add(buffer.toString());
  return fields;
}

/// Parses `nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY device wifi list`.
///
/// [savedSsids] marks networks that already have a profile, so the UI can join
/// them without asking for a password again.
List<WifiNetwork> parseWifiList(
  String output, {
  Set<String> savedSsids = const {},
}) {
  final byId = <String, WifiNetwork>{};
  for (final line in output.split('\n')) {
    if (line.trim().isEmpty) continue;
    final fields = parseNmcliFields(line);
    if (fields.length < 4) continue;
    final ssid = fields[1];
    // A hidden network reports an empty SSID; there is nothing tappable about
    // it, and joining one needs a name the user would have to type anyway.
    if (ssid.isEmpty) continue;
    final signal = int.tryParse(fields[2].trim()) ?? 0;
    final security = fields[3].trim();
    final network = WifiNetwork(
      ssid: ssid,
      signal: signal.clamp(0, 100),
      // nmcli prints an empty security column, or a literal "--", for open
      // networks.
      secured: security.isNotEmpty && security != '--',
      active: fields[0].trim() == '*',
      saved: savedSsids.contains(ssid),
    );
    // The same SSID appears once per band and per access point. Keep the
    // strongest, and never let a weaker duplicate erase the active flag.
    final existing = byId[ssid];
    if (existing == null) {
      byId[ssid] = network;
    } else {
      byId[ssid] = WifiNetwork(
        ssid: ssid,
        signal: network.signal > existing.signal
            ? network.signal
            : existing.signal,
        secured: existing.secured || network.secured,
        active: existing.active || network.active,
        saved: existing.saved || network.saved,
      );
    }
  }
  final networks = byId.values.toList()
    ..sort((a, b) {
      // The connected network pins to the top; everything else by strength.
      if (a.active != b.active) return a.active ? -1 : 1;
      return b.signal.compareTo(a.signal);
    });
  return networks;
}

/// Parses saved connection names from `nmcli -t -f NAME connection show`.
Set<String> parseSavedConnections(String output) => {
  for (final line in output.split('\n'))
    if (line.trim().isNotEmpty) parseNmcliFields(line).first,
};
