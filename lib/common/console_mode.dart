/// Compile-time flag: is this build running as the physical VAMP floor console
/// (Raspberry Pi kiosk, fixed 16″ + 7″ panels, driven by the foot pedals)
/// rather than a desktop dev/user build?
///
/// Enable at build/run time with `--dart-define=LOOPY_CONSOLE=true`. It is set
/// for the Pi kiosk bundle (`deploy/rpi`) and for the main-window screenshot
/// generator, so the captured decal artwork matches what the console shows.
///
/// In console mode the on-screen tracks toolbar chrome is hidden (the foot
/// pedals own transport/mode/clear), the tracks layout tightens for the fixed
/// panel, per-track readiness indicators default off, channel numbers centre,
/// and the on-screen undo/redo buttons are removed. Default (false) keeps the
/// full on-screen chrome.
const kConsoleMode = bool.fromEnvironment('LOOPY_CONSOLE');
