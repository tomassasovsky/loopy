import 'dart:typed_data';

import 'package:loopy_engine/src/audio_device.dart';
import 'package:loopy_engine/src/engine_config.dart';
import 'package:loopy_engine/src/engine_snapshot.dart';
import 'package:loopy_engine/src/loopback_info.dart';
import 'package:loopy_engine/src/track_effect.dart';

/// Result of an [AudioEngine] lifecycle call.
///
/// Mirrors the native `le_result` enum.
enum EngineResult {
  /// The call succeeded.
  ok,

  /// A null handle or invalid argument was supplied.
  invalid,

  /// [AudioEngine.start] was called while already running.
  alreadyRunning,

  /// A call required a running engine but it was stopped.
  notRunning,

  /// The audio device failed to initialise or start.
  device;

  /// Maps a native `le_result` integer to an [EngineResult].
  ///
  /// Unknown values map to [EngineResult.invalid].
  static EngineResult fromCode(int code) => switch (code) {
    0 => EngineResult.ok,
    -1 => EngineResult.invalid,
    -2 => EngineResult.alreadyRunning,
    -3 => EngineResult.notRunning,
    -4 => EngineResult.device,
    _ => EngineResult.invalid,
  };

  /// Whether this result represents success.
  bool get isOk => this == EngineResult.ok;
}

/// Thrown when an [AudioEngine] operation fails.
class EngineException implements Exception {
  /// Creates an [EngineException] from a failing [result].
  const EngineException(this.result, [this.message]);

  /// The failing result code.
  final EngineResult result;

  /// An optional human-readable detail.
  final String? message;

  @override
  String toString() =>
      'EngineException(${result.name}${message != null ? ': $message' : ''})';
}

/// The data-layer boundary over the native audio engine.
///
/// Repositories depend on this interface and inject a fake in tests; the
/// production implementation is `NativeAudioEngine`, which drives the native
/// engine over FFI.
abstract interface class AudioEngine {
  /// A human-readable engine + miniaudio version string.
  String get version;

  /// The name of the active audio device, or an empty string when stopped.
  String get deviceName;

  /// Opens the default duplex device with [config] and starts the audio
  /// callback. Returns [EngineResult.ok] or an error code.
  EngineResult start(EngineConfig config);

  /// Stops and closes the audio device.
  EngineResult stop();

  /// Reads the current lock-free [EngineSnapshot] published by the engine.
  EngineSnapshot snapshot();

  /// Detects a cable-free loopback capture path (PulseAudio monitor / virtual
  /// driver / WASAPI) for auto-measuring latency. The result captures the
  /// digital round-trip only (see [LoopbackInfo]).
  LoopbackInfo detectLoopback();

  /// Enumerates the host's audio devices — playback (output) and capture
  /// (input) — each tagged with [AudioDevice.isInput] and
  /// [AudioDevice.isDefault]. Safe to call while the engine is running. Returns
  /// an empty list when enumeration fails.
  List<AudioDevice> enumerateDevices();

  /// Triggers a single loopback round-trip latency measurement. The result is
  /// surfaced asynchronously via [snapshot]'s latency fields.
  ///
  /// Requires a loopback path: a physical cable, or a detected loopback device
  /// when the engine was started with [EngineConfig.useLoopbackCapture].
  EngineResult measureLatency();

  /// Advances track [channel]: start recording, finalize the master loop, or
  /// toggle overdub depending on the current track state. When it begins an
  /// overdub it also captures the one-level undo snapshot.
  EngineResult record({int channel = 0});

  /// Halts track [channel]'s playback, retaining the loop buffer.
  EngineResult stopTrack({int channel = 0});

  /// Resumes playback of track [channel].
  EngineResult play({int channel = 0});

  /// Erases track [channel] (and resets the master loop if all tracks empty).
  EngineResult clear({int channel = 0});

  /// Removes the most recent overdub layer on track [channel] (multi-level).
  EngineResult undo({int channel = 0});

  /// Re-applies the most recently undone overdub layer on track [channel].
  EngineResult redo({int channel = 0});

  /// Sets track [channel]'s playback gain, clamped to `0..1`.
  EngineResult setTrackVolume(double volume, {int channel = 0});

  /// Mutes or unmutes track [channel].
  EngineResult setTrackMute({required bool muted, int channel = 0});

  /// Routes track [channel]'s record sources to the input channels set in
  /// [mask] (a bitmask; bit c => hardware input channel c). Selected inputs are
  /// averaged into the track's mono buffer. Bits beyond the negotiated
  /// input-channel range are ignored.
  EngineResult setInputMask({required int channel, required int mask});

  /// Routes track [channel]'s playback to the output channels set in [mask] (a
  /// bitmask; bit c => hardware output channel c). Bits beyond the negotiated
  /// output-channel range are ignored.
  EngineResult setOutputMask({required int channel, required int mask});

  /// Sets the record-offset latency compensation in frames (clamped `>= 0`).
  EngineResult setRecordOffset(int frames);

  /// Enables or disables quantized recording. When enabled, a record/overdub
  /// press over an existing master loop is deferred to the next loop top so
  /// captures align to the grid; a second press before the boundary cancels the
  /// pending action. The defining recording (no master yet) always acts
  /// immediately.
  EngineResult setQuantize({required bool enabled});

  /// Sets track [channel]'s quantize override: `null` inherits the global
  /// [setQuantize] default, `false` forces quantize off for the track, and
  /// `true` forces it on.
  EngineResult setTrackQuantize({required int channel, required bool? enabled});

  /// Fixes track [channel]'s loop length to [multiple] whole base loops, or `0`
  /// to inherit the global default ([setDefaultMultiple]). Applies to the next
  /// recording.
  EngineResult setTrackMultiple({required int channel, required int multiple});

  /// Sets the global default loop length (used by tracks that inherit):
  /// [multiple] whole base loops, or `0` to auto-round-up on stop.
  EngineResult setDefaultMultiple({required int multiple});

  /// Sets the second-press "rec/dub" mode: when enabled, finalizing a recording
  /// with a record press continues into overdub instead of playback.
  EngineResult setRecDub({required bool enabled});

  /// Enables sound-activated recording: a record press on an empty track waits
  /// and begins capturing once the input level crosses the threshold.
  EngineResult setAutoRecord({required bool enabled});

  /// Sets the monitor input mask: which input channels are averaged (mono) into
  /// the live monitor signal (a bitmask; bit c => hardware input channel c).
  /// Bits beyond the input range or loopback-excluded are ignored.
  EngineResult setMonitorInputMask({required int mask});

  /// Sets the monitor output mask: which output channels the monitored signal
  /// is routed to (a bitmask; bit c => hardware output channel c). Bits beyond
  /// the output range are ignored.
  EngineResult setMonitorOutputMask({required int mask});

  /// Makes the monitor follow track [track]: the monitored signal becomes that
  /// track's pre-stage-processed input (its masked input run through its
  /// before-track effects), so those effects are heard live. Pass `-1` to stop
  /// following and monitor the raw masked inputs (the default).
  EngineResult setMonitorFxTrack({required int track});

  /// Sets chain entry [index] (`0..kTrackEffectMax-1`) on track [channel] to
  /// [type] at [stage]. Changing the type resets that entry's DSP state and
  /// seeds the type's default parameters. This sets the entry's value only; use
  /// [setTrackFxCount] to control how many entries are active.
  EngineResult setTrackFx({
    required int channel,
    required int index,
    required TrackEffectType type,
    required TrackEffectStage stage,
  });

  /// Sets the active chain length on track [channel] to [count]
  /// (`0..kTrackEffectMax`): only entries `[0, count)` are processed, in order.
  EngineResult setTrackFxCount({required int channel, required int count});

  /// Sets parameter [param] (`0..kTrackEffectParams-1`) of chain entry [index]
  /// on track [channel] to [value] (clamped to `0..1`). The parameter's meaning
  /// depends on the entry's effect type.
  EngineResult setTrackFxParam({
    required int channel,
    required int index,
    required int param,
    required double value,
  });

  /// Sets monitor-bus chain entry [index] (`0..kTrackEffectMax-1`) to [type].
  /// The monitor bus is a single global chain applied to the live monitored
  /// signal in every mode (it has no pre/post). Changing the type resets that
  /// entry's DSP state and seeds the type's default parameters; use
  /// [setMonitorFxCount] to control how many entries are active.
  EngineResult setMonitorFx({
    required int index,
    required TrackEffectType type,
  });

  /// Sets the monitor bus's active chain length to [count]
  /// (`0..kTrackEffectMax`): only entries `[0, count)` are processed, in order.
  EngineResult setMonitorFxCount({required int count});

  /// Sets parameter [param] (`0..kTrackEffectParams-1`) of monitor-bus entry
  /// [index] to [value] (clamped to `0..1`). Its meaning depends on the entry's
  /// effect type.
  EngineResult setMonitorFxParam({
    required int index,
    required int param,
    required double value,
  });

  /// Reads the loop waveform: peaks of the mixed output indexed by position
  /// across one master loop (index 0 = loop start), each in `0..1`. Pair with
  /// [EngineSnapshot.masterPositionFrames]/[EngineSnapshot.masterLengthFrames]
  /// for the playhead. Empty until a loop exists.
  Float32List readVisual();

  /// Like [readVisual] but for a single track's own contribution, for
  /// per-track waveform thumbnails.
  Float32List readTrackVisual(int channel);

  /// Copies track [channel]'s recorded mono loop PCM out for session export, or
  /// an empty list when the track is empty. Read-only — call when not
  /// capturing.
  Float32List exportTrack(int channel);

  /// Loads mono [pcm] into the EMPTY track [channel] for a session restore.
  /// Pair with [commitSession] to establish the master and play. Returns
  /// [EngineResult.invalid] if the track is not empty.
  EngineResult importTrack(int channel, Float32List pcm);

  /// Establishes the master loop at [baseFrames] and starts every imported
  /// track playing at its whole-loop multiple.
  EngineResult commitSession(int baseFrames);

  /// Releases the native engine. The instance must not be used afterwards.
  void dispose();
}
