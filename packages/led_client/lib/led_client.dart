/// Console LED output for Loopy's Raspberry Pi floor console.
///
/// Serialises transport-state snapshots (`LedFrame`) and pushes them over a
/// serial `LedTransport` (on a Pi, `UartLedTransport` → the RP2040 WS2812
/// driver MCU; elsewhere a `NoopLedTransport`). `LedRepository` owns the link
/// and the boot-time ping/ack health handshake; `createNativeLedChannel` builds
/// the real one on a Pi and returns `null` everywhere else.
library;

export 'src/led_frame.dart' show LedFrame, LedGlobalColor, LedTrackColor;
export 'src/led_repository.dart' show LedRepository;
export 'src/led_transport.dart' show LedHealth, LedTransport, NoopLedTransport;
export 'src/native_led_channel.dart' show createNativeLedChannel;
export 'src/uart_led_transport.dart' show UartLedTransport;
