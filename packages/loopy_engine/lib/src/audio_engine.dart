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

/// Device lifecycle + identity.
///
/// One role of the [AudioEngine] data-layer boundary. Consumers that only need
/// to open/close the device (or read its name/version) can depend on this slice
/// rather than the whole engine.
abstract interface class EngineLifecycle {
  /// A human-readable engine + miniaudio version string.
  String get version;

  /// The name of the active audio device, or an empty string when stopped.
  String get deviceName;

  /// Opens the default duplex device with [config] and starts the audio
  /// callback. Returns [EngineResult.ok] or an error code.
  EngineResult start(EngineConfig config);

  /// Stops and closes the audio device.
  EngineResult stop();

  /// Releases the native engine. The instance must not be used afterwards.
  void dispose();
}

/// Read-only state: snapshots, metering, visualization, and device/latency
/// discovery. Everything here only reads engine state (the latency measurement
/// is triggered here but its result surfaces via [snapshot]).
abstract interface class EngineMetering {
  /// Reads the current lock-free [EngineSnapshot] published by the engine.
  EngineSnapshot snapshot();

  /// Detects a cable-free loopback capture path (PulseAudio monitor / virtual
  /// driver / backend built-in loopback) for auto-measuring latency. The result
  /// captures the digital round-trip only (see [LoopbackInfo]).
  LoopbackInfo detectLoopback();

  /// Enumerates the host's audio devices — playback (output) and capture
  /// (input) — each tagged with [AudioDevice.isInput] and
  /// [AudioDevice.isDefault]. Safe to call while the engine is running. Returns
  /// an empty list when enumeration fails.
  List<AudioDevice> enumerateDevices();

  /// Enumerates the installed ASIO drivers, each as a single **duplex**
  /// [AudioDevice] (`isInput: false`) carrying its probed
  /// [AudioDevice.inputChannels] / [AudioDevice.outputChannels] so the picker
  /// can show "18 in / 20 out" before the device is opened. One ASIO driver
  /// drives all I/O, so these are never partitioned by direction like
  /// [enumerateDevices]. Returns an empty list off Windows, on the default
  /// (non-ASIO) build, or when no ASIO driver is installed.
  ///
  /// RE-ENTRANCY: the ASIO host SDK loads a single process-global driver, so
  /// this must NOT be called while the engine is running on the ASIO backend —
  /// probing would tear down the live stream. Call only while stopped or while
  /// running on the miniaudio backend (the presentation layer enforces this).
  List<AudioDevice> enumerateAsioDrivers();

  /// Triggers a single loopback round-trip latency measurement. The result is
  /// surfaced asynchronously via [snapshot]'s latency fields.
  ///
  /// Requires a loopback path: a physical cable, or a detected loopback device
  /// when the engine was started with [EngineConfig.useLoopbackCapture].
  EngineResult measureLatency();

  /// Reads the loop waveform: peaks of the mixed output indexed by position
  /// across one master loop (index 0 = loop start), each in `0..1`. Pair with
  /// [EngineSnapshot.masterPositionFrames]/[EngineSnapshot.masterLengthFrames]
  /// for the playhead. Empty until a loop exists.
  Float32List readVisual();

  /// Like [readVisual] but for a single track's own contribution (its active
  /// lanes summed), for per-track waveform thumbnails. Per-lane waveforms are
  /// not exposed yet.
  Float32List readTrackVisual(int channel);
}

/// Per-track looper transport + recording-behaviour settings.
abstract interface class LooperTransport {
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

  /// Sets the overdub [feedback] coefficient (clamped by the engine to `0..1`,
  /// default `1.0`). While a track is overdubbing, its existing content is
  /// scaled by this before the new layer is summed in: `1.0` is the classic
  /// additive overdub (layers persist and can build toward clipping); below
  /// `1.0` decays older layers each pass so the loop self-limits. Plain
  /// playback is untouched.
  EngineResult setOverdubFeedback(double feedback);

  /// Enables sound-activated recording: a record press on an empty track waits
  /// and begins capturing once the input level crosses the threshold.
  EngineResult setAutoRecord({required bool enabled});
}

/// Per-lane channel routing, volume, and mute (a track's recordable lanes).
abstract interface class EngineRouting {
  /// Sets track [channel]'s active lane count to [count] (clamped by the engine
  /// to `1..` the native lane ceiling) on the control thread, lazily allocating
  /// the loop buffers for any newly added lanes before the audio thread reads
  /// them. Shrinking leaves dropped lanes' buffers allocated for reuse but
  /// stops playing/recording them.
  EngineResult setLaneCount({required int channel, required int count});

  /// Sets lane [lane] of track [channel]'s playback gain, clamped to `0..1`.
  EngineResult setLaneVolume(
    double volume, {
    int channel = 0,
    int lane = 0,
  });

  /// Mutes or unmutes lane [lane] of track [channel].
  EngineResult setLaneMute({
    required bool muted,
    int channel = 0,
    int lane = 0,
  });

  /// Routes lane [lane] of track [channel] to record from hardware input
  /// [inputChannel] (`-1` = record nothing). Each lane records exactly one
  /// input into its own clean mono buffer (no averaging). Inputs beyond the
  /// negotiated range or loopback-excluded record silence.
  EngineResult setLaneInput({
    required int channel,
    required int lane,
    required int inputChannel,
  });

  /// Routes lane [lane] of track [channel]'s playback to the output channels
  /// set in [mask] (a bitmask; bit c => hardware output channel c). Bits beyond
  /// the negotiated output-channel range are ignored.
  EngineResult setLaneOutput({
    required int channel,
    required int lane,
    required int mask,
  });
}

/// Global master-output bus: post-mix gain and the peak limiter.
abstract interface class MasterBusControl {
  /// Sets the global master output [gain] (clamped by the engine to `0..1`),
  /// applied post-mix to the final output after all tracks, lanes, and monitor
  /// lanes have summed in. Unity (`1.0`) by default and after every fresh
  /// start; the current value is published in [EngineSnapshot.masterGain].
  EngineResult setMasterGain(double gain);

  /// Enables/disables the master peak limiter and sets its [ceiling] (clamped
  /// by the engine to `(0, 1]`, default `0.99`). Applied post master-gain, it
  /// keeps the summed output of all tracks, overdub layers, and monitoring from
  /// exceeding the ceiling and hard-clipping in the driver; below the ceiling
  /// it is transparent. Off by default and after every fresh start.
  EngineResult setLimiter({required bool enabled, double ceiling = 0.99});
}

/// Per-lane (record-route) effect chains.
abstract interface class EffectsControl {
  /// Sets chain entry [index] (`0..kTrackEffectMax-1`) on lane [lane] of track
  /// [channel] to [type]. Changing the type resets that entry's DSP state and
  /// seeds the type's default parameters. The chain is non-destructive and
  /// stageless — every active entry colors playback in order. This sets the
  /// entry's value only; use [setLaneFxCount] to control how many are active.
  EngineResult setLaneFx({
    required int channel,
    required int lane,
    required int index,
    required TrackEffectType type,
  });

  /// Sets the active chain length on lane [lane] of track [channel] to [count]
  /// (`0..kTrackEffectMax`): only entries `[0, count)` are processed, in order.
  EngineResult setLaneFxCount({
    required int channel,
    required int lane,
    required int count,
  });

  /// Sets parameter [param] (`0..kTrackEffectParams-1`) of chain entry [index]
  /// on lane [lane] of track [channel] to [value] (clamped to `0..1`). The
  /// parameter's meaning depends on the entry's effect type.
  EngineResult setLaneFxParam({
    required int channel,
    required int lane,
    required int index,
    required int param,
    required double value,
  });
}

/// Per-input live monitoring: enable plus per-lane routing/volume/mute/effects.
abstract interface class MonitorControl {
  /// Enables or disables live monitoring of hardware input [input]. When
  /// enabled, the input's active monitor lanes each route the live signal per
  /// their own output mask, volume, mute, and effect chain. The monitored
  /// signal is never recorded and is independent of any track's record/playback
  /// state;
  /// a loopback-excluded input is never monitored.
  EngineResult setMonitorInputEnabled({
    required int input,
    required bool enabled,
  });

  /// Sets monitor input [input]'s active lane count to [count] (clamped
  /// `1..kMaxLanes`). New lanes default to full stereo output, unity volume,
  /// unmuted, and an empty (clean) effect chain — the clean (dry) path.
  EngineResult setMonitorLaneCount({
    required int input,
    required int count,
  });

  /// Routes monitor input [input]'s lane [lane] to the output channels set in
  /// [mask] (bit c => hardware output channel c).
  EngineResult setMonitorLaneOutput({
    required int input,
    required int lane,
    required int mask,
  });

  /// Sets monitor input [input]'s lane [lane] output gain ([volume], clamped to
  /// `0..1`). Defaults to `1.0` (unity).
  EngineResult setMonitorLaneVolume({
    required int input,
    required int lane,
    required double volume,
  });

  /// Mutes or unmutes monitor input [input]'s lane [lane].
  EngineResult setMonitorLaneMute({
    required int input,
    required int lane,
    required bool muted,
  });

  /// Sets chain entry [index] (`0..kTrackEffectMax-1`) on monitor input
  /// [input]'s lane [lane] to [type]. Changing the type resets that entry's DSP
  /// state and seeds the type's default parameters; use [setMonitorLaneFxCount]
  /// to control how many entries are active.
  EngineResult setMonitorLaneFx({
    required int input,
    required int lane,
    required int index,
    required TrackEffectType type,
  });

  /// Sets monitor input [input]'s lane [lane] active chain length to [count]
  /// (`0..kTrackEffectMax`): only entries `[0, count)` are processed, in order.
  EngineResult setMonitorLaneFxCount({
    required int input,
    required int lane,
    required int count,
  });

  /// Sets parameter [param] (`0..kTrackEffectParams-1`) of monitor input
  /// [input]'s lane [lane] chain entry [index] to [value] (clamped to `0..1`).
  /// Its meaning depends on the entry's effect type.
  EngineResult setMonitorLaneFxParam({
    required int input,
    required int lane,
    required int index,
    required int param,
    required double value,
  });
}

/// Session persistence: stem export/import and committing a restored session.
abstract interface class SessionIo {
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
}

/// The data-layer boundary over the native audio engine, composed from the
/// role interfaces above (interface-segregation: a consumer can depend on the
/// slice it needs — [SessionIo], [EngineMetering], … — instead of the whole
/// surface).
///
/// Repositories depend on this interface (or a role slice) and inject a fake in
/// tests; the production implementation is `NativeAudioEngine`, which drives
/// the native engine over FFI.
abstract interface class AudioEngine
    implements
        EngineLifecycle,
        EngineMetering,
        LooperTransport,
        EngineRouting,
        MasterBusControl,
        EffectsControl,
        MonitorControl,
        SessionIo {}
