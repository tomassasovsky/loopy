import 'package:pedal_repository/pedal_repository.dart';

/// The canonical set of [PedalStateFrame]s captured as golden SysEx fixtures.
///
/// These are the **shared contract** between loopy's codec and the pedal
/// firmware: the committed `test/fixtures/<name>.syx` bytes are regenerated
/// from this catalog (see `tool/generate_golden_fixtures.dart`) and asserted by
/// `test/pedal_codec_golden_test.dart`. The firmware's host-compiled test links
/// the same `.syx` files. Keep names stable; append rather than renumber.
Map<String, PedalStateFrame> goldenFrames() {
  List<PedalTrackLed> leds(List<PedalTrackLed> values) => [
    ...values,
    ...List<PedalTrackLed>.filled(
      PedalStateFrame.trackCount - values.length,
      PedalTrackLed.off,
    ),
  ];

  return {
    // The all-off shutdown frame (isGoodbye set).
    'blank_goodbye': PedalStateFrame.blank(goodbye: true),

    // An all-off but live frame (e.g. fresh bind, nothing recorded yet).
    'idle_rec': PedalStateFrame(
      globalColor: GlobalColor.green,
      trackLeds: leds(const []),
      activeBank: 0,
      selectedTrack: 0,
      mode: PedalMode.rec,
      loopLengthMicros: 0,
      clearFadeActive: false,
    ),

    // Recording track 1, Rec mode, bank A, no loop yet.
    'recording_track1': PedalStateFrame(
      globalColor: GlobalColor.red,
      trackLeds: leds(const [PedalTrackLed.red]),
      activeBank: 0,
      selectedTrack: 0,
      mode: PedalMode.rec,
      loopLengthMicros: 0,
      clearFadeActive: false,
    ),

    // Play mode, bank B, tracks 1-4 playing, a 1.5 s loop, armed track 5.
    // masterGain 153/255 (~0.6) exercises the gain byte at a non-unity value;
    // n/255 keeps the double round-trip exact for the golden decode assertion.
    'playing_bankb': PedalStateFrame(
      globalColor: GlobalColor.amber,
      trackLeds: leds(const [
        PedalTrackLed.green,
        PedalTrackLed.green,
        PedalTrackLed.green,
        PedalTrackLed.green,
      ]),
      activeBank: 1,
      selectedTrack: 4,
      mode: PedalMode.play,
      loopLengthMicros: 1500000,
      clearFadeActive: false,
      masterGain: 153 / 255,
    ),

    // Clear fade in progress — exercises the clearFadeActive flag and a long
    // (near-max) loop length to stress the 32-bit little-endian field.
    'clear_fade': PedalStateFrame(
      globalColor: GlobalColor.blue,
      trackLeds: leds(const [
        PedalTrackLed.green,
        PedalTrackLed.red,
        PedalTrackLed.off,
        PedalTrackLed.green,
      ]),
      activeBank: 0,
      selectedTrack: 3,
      mode: PedalMode.rec,
      loopLengthMicros: 0xFEDCBA98,
      clearFadeActive: true,
    ),

    // Performance recording armed (D-PEDAL) — exercises the new flags bit3
    // alongside an otherwise-ordinary Rec-mode, bank A frame.
    'performance_armed': PedalStateFrame(
      globalColor: GlobalColor.green,
      trackLeds: leds(const [PedalTrackLed.red]),
      activeBank: 0,
      selectedTrack: 0,
      mode: PedalMode.rec,
      loopLengthMicros: 0,
      clearFadeActive: false,
      performanceArmed: true,
    ),
  };
}
