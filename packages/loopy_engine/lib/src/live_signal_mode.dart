/// Per-track Live Signal mode (native `le_live_signal_mode`).
///
/// Off: no track FX in the monitor mix (Input Post still follows input-monitor
/// enable). On: always monitor Track Pre→Post of the track's assigned input.
/// Auto: same as On only while [AudioEngine.setLiveSignalFocus] equals that
/// track (distinct from the Sync/Band primary crown).
enum LiveSignalMode {
  /// No track FX into the Live Signal monitor mix.
  off(0),

  /// Monitor Pre→Post only when this track is the Live Signal focus.
  auto(1),

  /// Always monitor Pre→Post for this track's assigned input.
  on(2);

  const LiveSignalMode(this.code);

  /// Native `le_live_signal_mode` integer.
  final int code;

  /// Maps a native code back to a [LiveSignalMode]; unknown values → [off].
  static LiveSignalMode fromCode(int code) =>
      values.firstWhere((m) => m.code == code, orElse: () => off);
}
