import 'package:segno/common/console_mode.dart';

/// Every USB product string a Segno pedal is known to advertise, newest first.
///
/// Set at build time via `build.usb_product` (see
/// `hardware/firmware/segno_pedal_32u4/README.md`); it is also what the custom
/// PID `0x7D00` keeps stable in CoreMIDI's name cache, so the OS-reported MIDI
/// label is built from this string.
///
/// **Renaming the product adds an entry here, it does not replace one.** A
/// rename ships with new firmware, but every pedal already in the field keeps
/// advertising the old string until someone reflashes it — and on a console
/// there is no picker to bind it manually in the meantime. Drop an old name
/// only once no pedal can still be running that firmware.
const kPedalUsbProductNames = <String>[
  'Segno Loopstation',
  // Pre-rename field units — keep until every console pedal has been
  // reflashed. OTA flash-pedal finds the board by the same legacy string
  // (see segno-update-ctl PEDAL_PRODUCT_GLOBS); drop both together.
  'VAMP Loopstation',
];

/// The product names pedal auto-detect matches on, or `null` when auto-detect
/// is off for this build.
///
/// On the floor console the Pro Micro is fixed, wired-in hardware and the
/// device pickers are hidden (#343), so nothing else can bind it — the app
/// adopts it by name. On desktop this stays `null`: any of several MIDI devices
/// may be the pedal, and the user picks from the dropdown.
///
/// Name matching is deliberately the *only* rule: adopting "the only device on
/// the bus" would bind an unrelated USB-MIDI keyboard as if it were the pedal.
/// The cost is that a Pro Micro flashed before the `build.usb_product` rename
/// enumerates as `Arduino Leonardo` and will never auto-bind — and the console
/// has no picker to fall back on. Recovery is reflashing it from a desktop
/// build.
const List<String>? kPedalAutoBindProductNames = kConsoleMode
    ? kPedalUsbProductNames
    : null;
