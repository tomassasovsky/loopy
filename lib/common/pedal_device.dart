import 'package:loopy/common/console_mode.dart';

/// The USB product string the 32U4 pedal firmware advertises, set at build time
/// via `build.usb_product` (see `hardware/firmware/loopy_pedal_32u4/README.md`).
/// It is also what the custom PID `0x7D00` keeps stable in CoreMIDI's name
/// cache, so the OS-reported MIDI label is built from this string.
const kPedalUsbProductName = 'VAMP Loopstation';

/// The product name pedal auto-detect matches on, or `null` when auto-detect is
/// off for this build.
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
const String? kPedalAutoBindProductName = kConsoleMode
    ? kPedalUsbProductName
    : null;
