import 'dart:typed_data';

import 'package:equatable/equatable.dart';

/// The colour of a single per-track indicator LED.
enum LedTrackColor {
  /// LED off (empty / inactive track).
  off,

  /// Green (playing).
  green,

  /// Red (recording).
  red,

  /// Amber (overdubbing).
  amber,
}

/// The colour of the global status / ring LED.
enum LedGlobalColor {
  /// Off (idle, no loop).
  off,

  /// Green (playing).
  green,

  /// Red (recording).
  red,

  /// Amber (overdub / mixed record+play).
  amber,
}

/// One snapshot of console LED state sent to the WS2812 driver MCU.
///
/// The frame carries the *loop length* (not a live playhead) and the [running]
/// flag: the driver animates the position ring locally from its own clock and
/// resyncs on each frame, so frames are pushed only on state changes (transport
/// cadence), never at audio rate.
///
/// [toBytes] serialises to the wire format documented in
/// `firmware/led_driver/README.md`.
class LedFrame extends Equatable {
  /// Creates a [LedFrame].
  const LedFrame({
    this.running = false,
    this.global = LedGlobalColor.off,
    this.loopLengthUs = 0,
    this.tracks = const [],
  });

  /// Whether the master loop is running (the ring animates when true).
  final bool running;

  /// The global status / ring LED colour.
  final LedGlobalColor global;

  /// The master loop length in microseconds (0 when there is no loop).
  final int loopLengthUs;

  /// Per-track indicator colours.
  final List<LedTrackColor> tracks;

  /// The 0xA5 start-of-frame sync byte.
  static const int sync = 0xA5;

  /// Frame type for a state update.
  static const int typeState = 0x01;

  /// Frame type for a health ping (Pi → MCU).
  static const int typePing = 0x02;

  /// Frame type for a ping acknowledgement (MCU → Pi).
  static const int typeAck = 0x82;

  /// Serialises this frame to the wire format
  /// `[sync][typeState][len][flags][global][len32 LE][n][tracks][xor]`, where
  /// the checksum is the XOR of every byte from `typeState` through the last
  /// track byte.
  Uint8List toBytes() {
    final flags = running ? 0x1 : 0x0;
    final body = <int>[
      flags,
      global.index,
      loopLengthUs & 0xFF,
      (loopLengthUs >> 8) & 0xFF,
      (loopLengthUs >> 16) & 0xFF,
      (loopLengthUs >> 24) & 0xFF,
      tracks.length & 0xFF,
      for (final track in tracks) track.index,
    ];
    final framed = <int>[typeState, body.length, ...body];
    var checksum = 0;
    for (final byte in framed) {
      checksum ^= byte;
    }
    return Uint8List.fromList([sync, ...framed, checksum & 0xFF]);
  }

  /// The fixed bytes of a health ping: `[sync][typePing][0][xor]`.
  static Uint8List pingBytes() {
    const checksum = typePing ^ 0;
    return Uint8List.fromList([sync, typePing, 0, checksum]);
  }

  @override
  List<Object?> get props => [running, global, loopLengthUs, tracks];
}
