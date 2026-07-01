import 'package:equatable/equatable.dart';
import 'package:pedal_repository/src/pedal_mode.dart';

/// The render state of a single track LED on the pedal ring.
///
/// loopy owns all looper logic; the firmware renders these colors verbatim.
/// Encoded as the enum [index] in the state frame — do not reorder.
enum PedalTrackLed {
  /// Track is empty or muted — LED dark.
  off,

  /// Track has a loop that is playing — LED green.
  green,

  /// Track is recording / overdubbing or armed — LED red.
  red,
}

/// The global status color shown by the pedal (e.g. the center / mode LED).
///
/// Semantic colors chosen by loopy and rendered verbatim by the firmware.
/// Encoded as the enum [index] in the state frame — do not reorder.
enum GlobalColor {
  /// No global indication — LED dark.
  off,

  /// Idle / ready in Rec mode — green.
  green,

  /// Recording or armed — red.
  red,

  /// Play mode — amber.
  amber,

  /// Transient / busy (e.g. clear fade) — blue.
  blue,
}

/// An immutable snapshot of everything the pedal needs to render its LEDs.
///
/// loopy projects looper state into a [PedalStateFrame], the codec serializes
/// it to SysEx, and the firmware renders the last good frame. It carries LED
/// state for **all 8 tracks** so a bank switch renders with no round-trip.
class PedalStateFrame extends Equatable {
  /// Creates a [PedalStateFrame].
  const PedalStateFrame({
    required this.globalColor,
    required this.trackLeds,
    required this.activeBank,
    required this.armedTrack,
    required this.mode,
    required this.loopLengthMicros,
    required this.clearFadeActive,
    this.isGoodbye = false,
  }) : assert(
         trackLeds.length == trackCount,
         'a frame must carry exactly $trackCount track LEDs',
       ),
       assert(
         activeBank == 0 || activeBank == 1,
         'activeBank must be 0 (A) or 1 (B)',
       ),
       assert(
         armedTrack >= 0 && armedTrack < trackCount,
         'armedTrack must be in 0..${trackCount - 1}',
       ),
       assert(
         loopLengthMicros >= 0 && loopLengthMicros <= maxLoopLengthMicros,
         'loopLengthMicros out of range',
       );

  /// A blank, all-off frame.
  ///
  /// With [goodbye] set this is the shutdown frame loopy sends on close; the
  /// firmware darkens its LEDs on receipt.
  factory PedalStateFrame.blank({bool goodbye = false}) => PedalStateFrame(
    globalColor: GlobalColor.off,
    trackLeds: List<PedalTrackLed>.filled(trackCount, PedalTrackLed.off),
    activeBank: 0,
    armedTrack: 0,
    mode: PedalMode.rec,
    loopLengthMicros: 0,
    clearFadeActive: false,
    isGoodbye: goodbye,
  );

  /// The number of tracks carried in every frame (2 banks of 4).
  static const trackCount = 8;

  /// The maximum encodable loop length (unsigned 32-bit microseconds).
  static const maxLoopLengthMicros = 0xFFFFFFFF;

  /// The center / mode status color.
  final GlobalColor globalColor;

  /// Per-track LED state for all [trackCount] tracks, track 0 first.
  final List<PedalTrackLed> trackLeds;

  /// The active bank: `0` = A, `1` = B.
  final int activeBank;

  /// The cursor / armed track index shown by the pedal, `0`..[trackCount] - 1.
  ///
  /// In Rec mode this is the selected track; in Play mode the armed *set* is
  /// carried by [trackLeds] (green), and this stays the last cursor.
  final int armedTrack;

  /// Which behavior set the footswitches drive (Rec vs Play).
  final PedalMode mode;

  /// The active loop length in microseconds (`0` when there is no loop).
  final int loopLengthMicros;

  /// Whether a clear fade is currently in progress (lights the Clear LED).
  final bool clearFadeActive;

  /// Whether this is the shutdown frame — all LEDs off, sent so the pedal
  /// darkens when loopy quits while the USB stays powered.
  final bool isGoodbye;

  /// Returns a copy with the given fields replaced.
  PedalStateFrame copyWith({
    GlobalColor? globalColor,
    List<PedalTrackLed>? trackLeds,
    int? activeBank,
    int? armedTrack,
    PedalMode? mode,
    int? loopLengthMicros,
    bool? clearFadeActive,
    bool? isGoodbye,
  }) {
    return PedalStateFrame(
      globalColor: globalColor ?? this.globalColor,
      trackLeds: trackLeds ?? this.trackLeds,
      activeBank: activeBank ?? this.activeBank,
      armedTrack: armedTrack ?? this.armedTrack,
      mode: mode ?? this.mode,
      loopLengthMicros: loopLengthMicros ?? this.loopLengthMicros,
      clearFadeActive: clearFadeActive ?? this.clearFadeActive,
      isGoodbye: isGoodbye ?? this.isGoodbye,
    );
  }

  @override
  List<Object?> get props => [
    globalColor,
    trackLeds,
    activeBank,
    armedTrack,
    mode,
    loopLengthMicros,
    clearFadeActive,
    isGoodbye,
  ];

  @override
  String toString() =>
      'PedalStateFrame(global: ${globalColor.name}, '
      'tracks: ${trackLeds.map((l) => l.name).join(",")}, '
      'bank: $activeBank, armed: $armedTrack, '
      'mode: ${mode.name}, loopUs: $loopLengthMicros, '
      'clearFade: $clearFadeActive, goodbye: $isGoodbye)';
}
