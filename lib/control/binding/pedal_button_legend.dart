import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/pedal_binding.dart';
import 'package:segno/l10n/l10n.dart';

/// The legend on [button]'s cap — the one place the app names a footswitch.
///
/// Not localised, and deliberately so: these are the silkscreen legends on a
/// physical plate, which say the same thing in every locale. Translating them
/// would leave the console calling a switch something its cap does not, which
/// is exactly the disagreement this function exists to prevent.
///
/// **Asserts against the four track caps**, which have no fixed legend to
/// return: a track cap prints the CHANNEL it currently drives on its face, so
/// the same four caps read `1 2 3 4` in bank A and `5 6 7 8` in bank B. Naming
/// them `TRACK 1`-`TRACK 4` in both banks names four tracks that already
/// exist and are not the ones the switch reaches. Use [pedalSwitchLabel] or
/// [pedalSwitchLegend], which take the bank; the assert is here so the next
/// caller cannot make that mistake quietly.
String pedalButtonLegend(PedalButton button) {
  assert(
    !PedalBindingKey.isBankKeyed(button),
    'a track cap is named by the channel its bank drives — '
    'use pedalSwitchLabel/pedalSwitchLegend',
  );
  return switch (button) {
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
}

/// The channel a track [button] drives in [bank] (both zero-based), or `null`
/// for a switch that is not bank-keyed.
///
/// Four caps, eight channels. That IS what Bank is for — it is the only way to
/// reach the other four track switches — so the second bank's caps drive
/// tracks 5-8, and a surface that calls them Track 1-4 there is naming them
/// after four different tracks that already exist.
int? pedalTrackChannel(PedalButton button, int bank) {
  final index = kTrackSwitches.indexOf(button);
  if (index < 0) return null;
  return bank * kTrackSwitches.length + index;
}

/// What a list row calls [button] in [bank] — `REC / PLAY`, or `Track 5`.
///
/// Sentence case for the track switches: a column of list items shouting in
/// upper case reads as four headings rather than four rows.
String pedalSwitchLabel(
  AppLocalizations l10n,
  PedalButton button,
  int bank,
) {
  final channel = pedalTrackChannel(button, bank);
  if (channel == null) return pedalButtonLegend(button);
  return l10n.controlTrackSwitchName(channel + 1);
}

/// What a caption calls [button] in [bank] — the upper-case form of
/// [pedalSwitchLabel], since it sits among other upper-case captions.
///
/// A second string rather than `toUpperCase()` on the first: a locale where a
/// caption is not upper-cased has to be able to say so, and casing a
/// translated string in code takes that away.
String pedalSwitchLegend(
  AppLocalizations l10n,
  PedalButton button,
  int bank,
) {
  final channel = pedalTrackChannel(button, bank);
  if (channel == null) return pedalButtonLegend(button);
  return l10n.controlTrackSwitchLegend(channel + 1);
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
/// (A3), so these four caps carry eight assignable slots — and drive eight
/// different channels; see [pedalTrackChannel].
const List<PedalButton> kTrackSwitches = [
  PedalButton.track1,
  PedalButton.track2,
  PedalButton.track3,
  PedalButton.track4,
];
