import 'dart:typed_data';

import 'package:loopy_engine/src/audio_device.dart';
import 'package:loopy_engine/src/engine_config.dart';
import 'package:loopy_engine/src/engine_snapshot.dart';
import 'package:loopy_engine/src/loopback_info.dart';
import 'package:loopy_engine/src/performance_render_progress.dart';
import 'package:loopy_engine/src/plugin_descriptor.dart';
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
  device,

  /// A plugin's bus topology is not a stereo (or mono-adaptable) effect —
  /// instrument / multi-bus / sidechain / wrong channel count (D-BUS). The
  /// insert is rejected with no partial slot created.
  unsupported;

  /// Maps a native `le_result` integer to an [EngineResult].
  ///
  /// Unknown values map to [EngineResult.invalid].
  static EngineResult fromCode(int code) => switch (code) {
    0 => EngineResult.ok,
    -1 => EngineResult.invalid,
    -2 => EngineResult.alreadyRunning,
    -3 => EngineResult.notRunning,
    -4 => EngineResult.device,
    -5 => EngineResult.unsupported,
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

  /// Sets lane [lane] of track [channel]'s playback gain, clamped to
  /// `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above unity).
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

  /// Turns hardware output [output] on/off as a routing target (the structural
  /// output gate). A disabled output is skipped in the mix fan-out regardless
  /// of any lane/monitor mask pointing at it, while the stored masks are left
  /// untouched — re-enabling restores the routing. Distinct from a level mute:
  /// it changes the routing graph, not a gain. All outputs are enabled by
  /// default; the current gate is in [EngineSnapshot.outputEnabledMask].
  EngineResult setOutputEnabled({required int output, required bool enabled});
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

  /// An order-sensitive 64-bit fingerprint of lane [lane] of track [channel]'s
  /// PUBLISHED effect chain — its active entries' types plus (for built-ins)
  /// their parameter bits. For divergence detection only: the repository owns
  /// the chain and computes the identical hash over its cache, so a mismatch
  /// flags a cache-vs-engine drift. An empty / out-of-range chain hashes to the
  /// FNV-1a offset basis.
  int laneFxFingerprint({required int channel, required int lane});
}

/// Per-input live monitoring: a single chain per hardware input — enable plus
/// the chain's routing/volume/mute/effects. The chain you monitor live is the
/// chain snapshot-copied onto a track lane when you record into that input.
abstract interface class MonitorControl {
  /// Enables or disables live monitoring of hardware input [input]. When
  /// enabled, the input's single chain routes the live signal per its output
  /// mask, volume, mute, and effects. The monitored signal is never recorded
  /// and is independent of any track's record/playback state; a loopback-
  /// excluded input is never monitored.
  EngineResult setMonitorInputEnabled({
    required int input,
    required bool enabled,
  });

  /// Routes monitor input [input]'s chain to the output channels set in [mask]
  /// (bit c => hardware output channel c).
  EngineResult setMonitorInputOutput({required int input, required int mask});

  /// Sets monitor input [input]'s output gain ([volume], clamped to
  /// `0..LE_MAX_GAIN`, i.e. 2.0/+6.02 dB headroom above unity). Defaults to
  /// `1.0` (unity).
  EngineResult setMonitorInputVolume({
    required int input,
    required double volume,
  });

  /// Mutes or unmutes monitor input [input]'s chain.
  EngineResult setMonitorInputMute({required int input, required bool muted});

  /// Sets chain entry [index] (`0..kTrackEffectMax-1`) on monitor input
  /// [input]'s chain to [type]. Changing the type resets that entry's DSP state
  /// and seeds the type's default parameters; use [setMonitorInputFxCount] to
  /// control how many entries are active.
  EngineResult setMonitorInputFx({
    required int input,
    required int index,
    required TrackEffectType type,
  });

  /// Sets monitor input [input]'s active chain length to [count]
  /// (`0..kTrackEffectMax`): only entries `[0, count)` are processed, in order.
  EngineResult setMonitorInputFxCount({required int input, required int count});

  /// Sets parameter [param] (`0..kTrackEffectParams-1`) of monitor input
  /// [input]'s chain entry [index] to [value] (clamped to `0..1`). Its meaning
  /// depends on the entry's effect type.
  EngineResult setMonitorInputFxParam({
    required int input,
    required int index,
    required int param,
    required double value,
  });

  /// An order-sensitive 64-bit fingerprint of monitor input [input]'s PUBLISHED
  /// effect chain (see [EffectsControl.laneFxFingerprint]). For cache-vs-engine
  /// divergence detection only.
  int monitorFxFingerprint({required int input});
}

/// Session persistence: stem export/import and committing a restored session.
abstract interface class SessionIo {
  /// Copies track [channel]'s recorded mono loop PCM out for session export, or
  /// an empty list when the track is empty. Read-only — call when not
  /// capturing.
  Float32List exportTrack(int channel);

  /// Copies track [channel]'s lane [lane] recorded mono loop PCM out for
  /// session export, or an empty list for an empty lane or an out-of-range
  /// [channel]/[lane]. Equivalent to [exportTrack] for `lane == 0`, but reads
  /// any lane — read-only, call when not capturing.
  Float32List exportTrackLane(int channel, int lane);

  /// Loads mono [pcm] into the EMPTY track [channel] for a session restore.
  /// Pair with [commitSession] to establish the master and play. Returns
  /// [EngineResult.invalid] if the track is not empty. Equivalent to
  /// [importTrackLane] with `lane == 0`.
  EngineResult importTrack(int channel, Float32List pcm);

  /// Loads mono [pcm] into lane [lane] of the EMPTY track [channel] for a
  /// multi-lane session restore — the import counterpart of [exportTrackLane].
  /// Importing a lane beyond the current active count activates it for
  /// playback. Import lane 0 first (it resets the track's redo/empty state),
  /// then each further lane, then [commitSession]. Returns
  /// [EngineResult.invalid] if the track is not empty.
  EngineResult importTrackLane(int channel, int lane, Float32List pcm);

  /// Copies track [channel]'s lane [lane] overdub layer at [ordinal] out for
  /// session export, or an empty list for an empty layer / out-of-range
  /// argument. Ordinals run oldest→newest: `[0, undoDepth)` are the undo
  /// snapshots, `undoDepth` is the live buffer, then the redo snapshots.
  /// Read-only — call when not capturing.
  Float32List exportLayer(int channel, int lane, int ordinal);

  /// Stages [pcm] as track [channel]'s lane [lane] layer at [ordinal] into an
  /// EMPTY track (the ordinal is the pool slot). Call once per `(lane,
  /// ordinal)` with ordinals contiguous from 0, then [finalizeLayers], then
  /// [commitSession]. Returns [EngineResult.invalid] for a non-empty track or
  /// an out-of-range ordinal.
  EngineResult importLayer(int channel, int lane, int ordinal, Float32List pcm);

  /// Publishes a track reconstructed via [importLayer]: rebuilds the undo/redo
  /// stacks and points playback at the live buffer (layer [undoCount]), every
  /// active lane in lockstep. `undoCount + 1 + redoCount` layers must already
  /// be staged on every active lane. Returns [EngineResult.invalid] for a
  /// non-empty track, a layer count past the pool cap, or a torn (missing-slot
  /// or mismatched-length) reconstruction.
  EngineResult finalizeLayers(int channel, int undoCount, int redoCount);

  /// Establishes the master loop at [baseFrames] and starts every imported
  /// track playing at its whole-loop multiple.
  EngineResult commitSession(int baseFrames);
}

/// Discovery of installed VST3 / CLAP plugins (umbrella D-SCAN).
///
/// The whole surface runs on the control thread and an engine-owned dedicated
/// scan thread — never the audio callback — so a scan is safe while the engine
/// is running. A scan is asynchronous: [scanBegin] launches it, the caller
/// polls [scanPoll] for progress and reads finished entries with [scanResults],
/// and [scanCancel] stops it. Loading a plugin into the FX graph is a later
/// slice.
abstract interface class EnginePluginHosting {
  /// Starts an asynchronous scan of the installed plugins. Returns
  /// [EngineResult.ok] once the scan thread is launched,
  /// [EngineResult.alreadyRunning] if a scan is already in progress. Pass
  /// [rescan] to hint that any native cache should be ignored.
  EngineResult scanBegin({bool rescan = false});

  /// Reads the current scan progress. Safe to call repeatedly on a timer.
  PluginScanProgress scanPoll();

  /// Reads every descriptor discovered so far (growing while the scan runs,
  /// complete once [PluginScanProgress.done]). Includes failed entries
  /// ([PluginDescriptor.isAvailable] is `false` for those).
  List<PluginDescriptor> scanResults();

  /// Cancels an in-progress scan and joins the scan thread. Idempotent and safe
  /// to call when no scan is running.
  EngineResult scanCancel();

  /// Loads the scanned plugin [pluginId] into lane FX chain slot [index] of
  /// (channel, lane), at the plugin's default state (umbrella D-LIFE). The load
  /// + activate happen on the control thread; the audio thread renders dry
  /// passthrough until the slot is published. Returns a [PluginSlotHandle] on
  /// success, or `null` on failure (unknown id / load error / unsupported
  /// build). Activate the entry in the chain with the matching
  /// `setLaneFxCount`, as for a built-in effect.
  PluginSlotHandle? setLanePlugin({
    required int channel,
    required int lane,
    required int index,
    required String pluginId,
  });

  /// Like [setLanePlugin] but for monitor input [input]'s chain slot [index].
  PluginSlotHandle? setMonitorPlugin({
    required int input,
    required int index,
    required String pluginId,
  });

  /// Clears the plugin in lane FX slot [index] of (channel, lane): the audio
  /// thread stops forwarding to it, then the host is destroyed after a
  /// quiescent handshake (no audio-thread free). The entry returns to empty.
  EngineResult clearLanePlugin({
    required int channel,
    required int lane,
    required int index,
  });

  /// Like [clearLanePlugin] but for monitor input [input]'s chain slot [index].
  EngineResult clearMonitorPlugin({required int input, required int index});

  /// The metadata for every parameter the plugin in [slot] exposes, in index
  /// order (umbrella D-PARAM). Empty if [slot] is not a live plugin slot.
  List<PluginParamInfo> pluginParamInfos(PluginSlotHandle slot);

  /// The current plain value of parameter [paramId] of the plugin in [slot].
  double pluginParamGet(PluginSlotHandle slot, int paramId);

  /// The plugin's own display string for parameter [paramId] at the plain
  /// [value] (e.g. `-6.0 dB`, `Lowpass`), or null when the plugin offers no
  /// text for it. Lets the UI label discrete params and read out continuous
  /// ones in their real units.
  String? pluginParamValueText(
    PluginSlotHandle slot,
    int paramId,
    double value,
  );

  /// Queues parameter [paramId] of the plugin in [slot] to the plain [value].
  /// Thread-safe: enqueued and applied via the SDK's event mechanism on the
  /// next process block — never a direct audio-thread store. Returns
  /// [EngineResult.ok] or [EngineResult.invalid].
  EngineResult pluginParamSet(PluginSlotHandle slot, int paramId, double value);

  /// Opens the plugin in [slot]'s own native editor in a host-owned top-level
  /// window (umbrella D-WIN; macOS + Windows — Linux/X11 is not yet
  /// implemented). Idempotent. Returns [EngineResult.ok],
  /// [EngineResult.invalid] for a non-live slot, or [EngineResult.unsupported]
  /// when there is no editor / the platform is not supported.
  EngineResult pluginEditorOpen(PluginSlotHandle slot);

  /// Force-closes the plugin in [slot]'s editor window (D-WIN teardown).
  /// Idempotent. Returns [EngineResult.ok] or [EngineResult.invalid].
  EngineResult pluginEditorClose(PluginSlotHandle slot);

  /// Whether the plugin in [slot]'s editor window is currently open.
  bool pluginEditorIsOpen(PluginSlotHandle slot);

  /// Captures the plugin in [slot]'s opaque state for session persistence
  /// (umbrella D-P1). Empty when the plugin exposes no state or capture failed
  /// — the dry-recording invariant never depends on success.
  Uint8List pluginStateGet(PluginSlotHandle slot);

  /// Restores the plugin in [slot] from a blob captured by [pluginStateGet].
  /// Returns [EngineResult.ok], [EngineResult.invalid] for a non-live slot, or
  /// [EngineResult.unsupported] when the plugin rejects it.
  EngineResult pluginStateSet(PluginSlotHandle slot, Uint8List state);
}

/// Performance-recording capture (parts 1-2 of the DAW-export stack): arming
/// and disarming the RT-safe audio-thread taps that copy the post-limiter
/// master output and each actively-monitored input into lock-free capture
/// rings, and the background drain thread that empties those rings into raw
/// PCM files plus a `performance.json` sidecar under [perfArm]'s capture
/// directory.
///
/// Status is read back via [EngineSnapshot] ([EngineSnapshot.isPerfArmed] /
/// [EngineSnapshot.perfFrames] / [EngineSnapshot.perfOverruns]), the same way
/// every other engine status surfaces. WAV headers are written only at
/// finalize (a later part) — the raw PCM + sidecar left on disk here are
/// already crash-salvageable.
abstract interface class EnginePerformanceCapture {
  /// Arms performance-recording capture: allocates the master + per-monitor
  /// rings, freezes the set of captured inputs to whichever are currently
  /// monitored, publishes them to the audio thread, and starts the drain
  /// thread writing into [captureDir] (created if it does not already exist).
  /// Idempotent — calling this while already armed is a no-op success (the
  /// armed session's original [captureDir] keeps draining; a non-empty
  /// [captureDir] is still required on the repeat call, but otherwise
  /// unused). Returns [EngineResult.notRunning] if the engine is not
  /// configured, [EngineResult.invalid] when [captureDir] is empty, nothing
  /// is enabled to capture (every output disabled), or the rings could not
  /// be allocated, or [EngineResult.device] if the drain thread could not be
  /// started (e.g. the directory could not be created) or a previous
  /// disarm's quiescent wait bailed out and left a stale drain session live.
  EngineResult perfArm(String captureDir);

  /// Disarms performance-recording capture: signals the audio thread to stop
  /// writing, waits for a quiescent handshake to confirm it has (never a
  /// use-after-free / audio-thread free), then stops and joins the drain
  /// thread — which runs one final drain-and-flush pass — before freeing the
  /// rings. Idempotent — calling this while already disarmed is a no-op
  /// success. Returns [EngineResult.device] if the callback could not be
  /// confirmed quiescent (a stalled device); the rings and drain thread are
  /// left retracted-but-running and are reclaimed by a later retry or when
  /// the engine is disposed.
  EngineResult perfDisarm();

  /// Starts an offline render of the finalized capture at [captureDir]: a
  /// worker thread reconstructs each non-empty track's full-length DRY stem
  /// (part 7 — wet stems are part 8) by replaying `events.log` against the
  /// capture's snapshots and retired-layer files, and writes
  /// `stems/dry/track<channel>.wav`. Reads only from disk — no live-engine
  /// dependency, so a render runs correctly whether or not this engine is
  /// currently armed or looping. Returns [EngineResult.ok] once the worker
  /// thread is launched (this call never blocks on the render itself),
  /// [EngineResult.invalid] for an empty [captureDir], or
  /// [EngineResult.alreadyRunning] if a render is already active.
  EngineResult renderBegin(String captureDir);

  /// Reads the current render's progress. Safe to call repeatedly (e.g. on a
  /// timer) whether or not a render is active — [PerformanceRenderProgress.
  /// empty] when none is.
  PerformanceRenderProgress renderPoll();

  /// Reads every track's render outcome discovered so far (growing
  /// progressively as each stem completes, not only once
  /// [PerformanceRenderProgress.done]). A per-track failure
  /// ([PerformanceRenderTrackStatus.succeeded] `false`) does not abort the
  /// render — the umbrella's partial-success posture.
  List<PerformanceRenderTrackStatus> renderTrackStatuses();

  /// Cancels an in-progress render and joins the worker thread; a no-op when
  /// no render is active. Cancellation is checked once per per-track work
  /// chunk (never mid-stem), so this only returns once the worker has
  /// actually stopped, leaving no partial stem file for whichever track was
  /// in flight.
  EngineResult renderCancel();
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
        EnginePluginHosting,
        EnginePerformanceCapture,
        SessionIo {}
