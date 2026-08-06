import 'package:pedal_repository/pedal_repository.dart';

/// The legend on [button]'s cap — the one place the app names a footswitch.
///
/// Not localised, and deliberately so: these are the silkscreen legends on a
/// physical plate, which say the same thing in every locale. Translating them
/// would leave the console calling a switch something its cap does not, which
/// is exactly the disagreement this function exists to prevent — the Control
/// face, the full-screen plate and the assignment captions all read from here.
String pedalButtonLegend(PedalButton button) => switch (button) {
  PedalButton.recPlay => 'REC / PLAY',
  PedalButton.stop => 'STOP',
  PedalButton.undo => 'UNDO',
  PedalButton.clear => 'CLEAR',
  PedalButton.mode => 'MODE',
  PedalButton.bank => 'BANK',
  PedalButton.track1 => 'TRACK 1',
  PedalButton.track2 => 'TRACK 2',
  PedalButton.track3 => 'TRACK 3',
  PedalButton.track4 => 'TRACK 4',
};

/// The same legend in the sentence case a list row is set in — `Track 1`.
///
/// The Control face's track switches are rows rather than caps, and a row of
/// list items shouting in upper case reads as four headings.
String pedalButtonRowLabel(PedalButton button) {
  final legend = pedalButtonLegend(button);
  if (!legend.startsWith('TRACK ')) return legend;
  return 'Track ${legend.substring('TRACK '.length)}';
}

/// The four transport switches, in plate order.
///
/// MODE and Bank are absent by rule, not by oversight: neither can ever hold a
/// binding (B12), so neither gets a card offering one.
const List<PedalButton> kTransportSwitches = [
  PedalButton.recPlay,
  PedalButton.stop,
  PedalButton.undo,
  PedalButton.clear,
];

/// The four track switches, in plate order. Each holds a binding **per bank**
/// (A3), so these four caps carry eight assignable slots.
const List<PedalButton> kTrackSwitches = [
  PedalButton.track1,
  PedalButton.track2,
  PedalButton.track3,
  PedalButton.track4,
];
