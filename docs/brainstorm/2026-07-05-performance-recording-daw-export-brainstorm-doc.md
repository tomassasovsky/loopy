---
date: 2026-07-05
topic: performance-recording-daw-export
---

# Performance Recording & DAW Export

## What We're Building

A **performance recorder** that captures a full live-looping session as high-quality audio, plus a **DAW export pipeline** that turns that session into editable material for Ableton Live. Today Loopy can only export a single dry mono loop cycle per track; there is no way to record a whole performance (loops starting/stopping, overdubs, mutes, FX tweaks, live playing over the top) for a video, and nothing that lands cleanly in a DAW.

The recorder is armed/disarmed from a UI button and a bindable pedal/MIDI action. While armed, the engine captures two real-time streams — the post-limiter **master output** (the exact audio for video sync, filmed separately with a camera/phone) and the **live monitor input** (playing/singing over loops that never becomes a loop) — alongside a sample-accurate **event log** of every looper action (record/play/stop/mute/volume/FX changes, overdub layers). After the performance, an offline render pass replays the log against snapshotted dry loop buffers to produce **full-length per-track stems in both wet (FX baked) and dry variants**, plus **loop-cycle stems** for all lanes (not just lane 0). The same event log drives an **Ableton Live (`.als`) project generator**: one track per Loopy track plus the live-input stem, clips placed on the timeline where they actually played, volume/mute automation, loop-cycle clips in session-view slots, and FX chains documented as track annotations.

## Why This Approach

Three architectures were considered for producing full-length performance stems:

- **A. Brute-force live capture of every bus** — tap master + 8 track buses + live input continuously. Rejected: 10+ parallel capture streams add real-time cost and disk pressure during the performance, only yield wet stems, and still don't provide the structural data an `.als` generator needs.
- **B. Pure event log + offline render** — record nothing live, reconstruct everything offline. Rejected: it cannot reconstruct the live monitored input (never stored in a loop buffer), which the user explicitly wants captured; offline-rendering the master also risks drift from what was actually heard.
- **C. Hybrid (chosen)** — live-capture only the two streams that cannot be reconstructed (master output, live input) via one lock-free ring drained on a control thread; render everything else offline from the event log + dry loop buffers. Video audio is bit-exact with minimal real-time cost; wet *and* dry stems come from one render mechanism (with/without FX); the event log doubles as the backbone for the `.als` exporter.

This fits Loopy's existing architecture: the engine already keeps recordings dry with non-destructive playback FX, exposes a post-limiter master bus (`master_bus_frame` in `engine_process.c`), enforces RT-safety via SPSC rings, retains overdub layers in an undo pool (usable as layer snapshots), and has a WAV writer (`WavCodec`) and export directory conventions (`{documents}/exports/`) to reuse.

## Key Decisions

- **Audio-only capture for video**: the user films with a separate camera and syncs in post; no screen/camera capture in the app. Deliverable is a master WAV at device sample rate, 32-bit float.
- **Hybrid capture architecture (Approach C)**: live real-time capture of master output + live monitor input only; all per-track stems rendered offline from a sample-timestamped event log + dry loop buffer snapshots.
- **Live monitor input is included and gets its own stem**: it is part of the master capture and also captured separately so it lands as its own track in the DAW.
- **Both wet and dry full-length stems**: wet (playback FX baked) so stems sound like the performance; dry for re-processing in the DAW. Rendered offline by running the log replay with and without the FX chains.
- **Both stem kinds**: full-length performance stems *and* short loop-cycle stems (extending the existing export beyond lane 0 to all lanes) for session-view arranging.
- **Ableton Live (`.als`) first**: `.als` is gzipped XML and can be generated directly. The exporter is structured so other formats (Reaper `.rpp`, `.dawproject`) can be added later, but only Ableton is in scope now.
- **FX are not recreated as Ableton devices in this feature**: wet stems carry the sound; FX chains are documented (track annotations / sidecar text). Recreating Loopy's built-in FX (drive, filter, delay, tremolo, octaver, echo, reverb) as a **VST3/CLAP plugin is a deliberate follow-up feature** — the export design should keep FX chain metadata rich enough (effect types + normalized params per lane) that a future exporter can insert the plugin with correct settings. Third-party VST3/CLAP plugins used in chains are recorded by identity in the metadata.
- **Record control via UI + pedal**: a transport-level record button plus a bindable action through the existing `ControlCubit` intent path, same as other pedal actions.
- **RT-safety rules respected**: capture taps write into pre-allocated lock-free rings inside the audio callback; file I/O happens on a control/drain thread only, consistent with the engine's existing command/snapshot boundary.
- **Correctness guardrail**: the offline renderer must mirror the engine's playback mixing; golden tests should compare an offline-rendered master against the live-captured master for the same log.

## Open Questions

- **Overdub layer snapshots**: the undo pool (`LE_POOL_SLOTS`) retains layers, but its depth is bounded — confirm whether long performances with many overdubs need the event log to persist evicted layers to disk (control-thread drain) or whether pool depth suffices.
- **Event log location**: engine-side (C, sample-accurate at the callback) vs repository-side (Dart, command timestamps)? Engine-side is more accurate; needs a small ring for log events alongside the audio rings.
- **`.als` schema validation**: generate against which Ableton Live version's XML schema (Live 11 vs 12)? Need a sample project corpus to reverse-engineer/verify.
- **Disk format while recording**: stream directly to WAV (header patched on stop) vs raw PCM temp file finalized on stop — decide during planning based on crash-safety preferences.
- **Where deliverables land**: proposed `{documents}/exports/<performance-slug>/` bundle containing `master.wav`, `live-input.wav`, `stems/wet/`, `stems/dry/`, `loops/`, `project.als`, `fx-chains.txt` — naming/structure to confirm in planning.
- **Sample-rate targets**: exports stay at device rate (no resampling) for now; confirm Ableton import ergonomics are acceptable (Live resamples on import, so likely fine).
