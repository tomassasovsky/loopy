/// Whether the OS-reported MIDI device label [deviceName] identifies a device
/// advertising any of the USB product strings in [productNames].
///
/// A **list**, not one string, because the product name is not stable across
/// the product's life: a rename ships new firmware, but pedals already in the
/// field keep advertising the old string until someone reflashes them. Both
/// generations have to be recognised, so retiring a name is a deliberate act
/// (drop it from the list) rather than a side effect of renaming.
///
/// Case-insensitive **substring**, deliberately — the reported label is not the
/// bare product string on every platform. CoreMIDI reports it verbatim
/// (`Segno Loopstation`), but ALSA (the floor console's backend) decorates it
/// with the port: `Segno Loopstation MIDI 1`, or
/// `Segno Loopstation:Segno Loopstation MIDI 1 20:0`. An equality test would
/// match on macOS and silently never match on the one platform that needs it.
///
/// Empty and whitespace-only entries never match. `contains('')` is true for
/// every string, so the natural reading would turn a stray blank entry into
/// "adopt the first device on the bus" — the precise failure an opt-in,
/// name-matched auto-bind exists to avoid. An empty list matches nothing.
bool midiDeviceNameMatches(String deviceName, Iterable<String> productNames) {
  final haystack = deviceName.toLowerCase();
  for (final productName in productNames) {
    final needle = productName.trim().toLowerCase();
    if (needle.isEmpty) continue;
    if (haystack.contains(needle)) return true;
  }
  return false;
}
