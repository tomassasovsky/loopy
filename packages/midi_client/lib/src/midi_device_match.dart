/// Whether the OS-reported MIDI device label [deviceName] identifies the device
/// whose USB product string is [productName].
///
/// Case-insensitive **substring**, deliberately — the reported label is not the
/// bare product string on every platform. CoreMIDI reports it verbatim
/// (`VAMP Loopstation`), but ALSA (the floor console's backend) decorates it
/// with the port: `VAMP Loopstation MIDI 1`, or
/// `VAMP Loopstation:VAMP Loopstation MIDI 1 20:0`. An equality test would
/// match on macOS and silently never match on the one platform that needs it.
///
/// An empty [productName] matches nothing. `contains('')` is true for every
/// string, so the natural reading would turn "no product configured" into
/// "adopt the first device on the bus" — the precise failure an opt-in,
/// name-matched auto-bind exists to avoid.
bool midiDeviceNameMatches(String deviceName, String productName) {
  final needle = productName.trim().toLowerCase();
  if (needle.isEmpty) return false;
  return deviceName.toLowerCase().contains(needle);
}
