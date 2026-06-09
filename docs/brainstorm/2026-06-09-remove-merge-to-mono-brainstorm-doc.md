---
date: 2026-06-09
topic: remove-merge-to-mono
---

# Remove the "merge to mono" feature

## What We're Building

Delete the **merge to mono** feature end to end. It was a global mode that
summed all hardware inputs and fed the result to every output. With the new
per-track I/O routing (each track has a mono buffer, an `inputMask` of the
hardware inputs it records — averaged to mono — and an `outputMask` of the
hardware outputs it plays to), the concept is redundant for recording and
playback, and only lingered as a monitoring hack. We remove the config flag,
the engine field, the two persisted/UI surfaces, and revert live monitoring to
a plain channel-matched passthrough (input channel `c` → output channel `c`).

## Why This Approach

A track is **mono by construction** and "mono vs stereo" is now purely a
**routing outcome**, not a mode:

- **Recording:** the track records the average of its `inputMask` channels into
  a mono buffer. "Merge to mono" added nothing — it only *bypassed* the mask
  (the bug just fixed where an unselected input still recorded the bus).
- **Playback:** the mono track plays to every channel in its `outputMask`
  (default `0x3` = both). A mono instrument on input 1 is already heard on L&R
  on the recorded loop, with no switch.
- **Monitoring (live passthrough):** the only place the flag still did anything.
  It summed inputs to all outputs so a mono source wasn't stuck on L. We
  considered making monitoring follow the selected track's routing instead, but
  the user opted to drop the feature entirely: interfaces commonly provide
  zero-latency hardware direct monitoring, and routing already covers the
  recorded result. Monitoring reverts to channel-matched passthrough.

Alternatives considered and rejected: (a) keep the switch — rejected, it
conflates input-folding with mono→stereo spread, which routing already
expresses; (b) make monitoring follow the selected track's input→output routing
— principled, but more machinery than the user wants right now (left as a
possible future enhancement, not built).

## Key Decisions

- **Delete the feature across all layers**, not just hide the toggle: native
  `le_config.merge_to_mono` + `mono_input`, FFI bindings (ffigen regen),
  `EngineConfig.mergeToMono`, `StoredAudioConfig.mergeToMono` (+ the
  `audio.merge_to_mono` persisted key), `AudioSetupState/Cubit.setMergeToMono`,
  the setup toggle + "Ready" summary row, and `audio_bootstrap` wiring.
- **Monitoring becomes channel-matched passthrough.** In `engine.c` the
  monitor line drops the `mono_input ? mono : …` branch to just route input `c`
  → output `c` for shared channels (excluded/loopback still skipped). Remove the
  now-unused per-frame `mono` fold if nothing else uses it.
- **Mono→stereo is a routing outcome.** Documented expectation: a mono source
  on input 1 reaches L&R via the track's output mask (default both); a true
  stereo source uses two tracks (in1→out1, in2→out2). Tracks stay mono — no
  stereo-buffer work.
- **Persistence is backward-compatible.** Dropping `audio.merge_to_mono` means
  an old stored bool is simply ignored on load; no migration needed.
- **Keep the input-monitoring on/off toggle** (`monitorInput`) — that is a
  separate, still-meaningful control and is out of scope for this removal.

## Affected files (for planning)

Native: `packages/loopy_engine/src/engine.c`,
`packages/loopy_engine/src/loopy_engine_api.h`,
`packages/loopy_engine/lib/src/generated/loopy_engine_bindings.dart` (regen),
`packages/loopy_engine/src/test/test_engine_core.c`.
Dart libs: `packages/loopy_engine/lib/src/engine_config.dart`,
`packages/settings_repository/lib/src/settings_repository.dart`,
`lib/app/audio_bootstrap.dart`, `lib/audio_setup/cubit/audio_setup_state.dart`,
`lib/audio_setup/cubit/audio_setup_cubit.dart`,
`lib/audio_setup/view/audio_setup_steps.dart`.
Tests: `packages/loopy_engine/test/engine_config_test.dart`,
`packages/settings_repository/test/settings_repository_test.dart`,
`test/app/audio_bootstrap_test.dart`,
`test/audio_setup/cubit/audio_setup_cubit_test.dart`,
`test/audio_setup/view/audio_setup_view_test.dart`.

Gates: native `ALL PASSED`, ffigen regen + struct agreement, `flutter analyze`,
app suite, macOS build.

## Open Questions

- Does removing `merge_to_mono` from `le_config` (an FFI struct field) need any
  coordination with a persisted/last-config restore path, or is regen + rebuild
  sufficient? (Expected: sufficient — the field is not stored on the native
  side.)
- Should the future "monitoring follows track routing" idea be captured as a
  backlog item, or dropped entirely?
