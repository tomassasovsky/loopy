# Host stress / soak harnesses (macOS)

Native test harnesses that drive the **real** VST3 host backend
(`src/host/host_vst3.cpp` + `native_window_controller.mm`) through its full
lifecycle, using the actual plugins installed on the machine. They link the same
translation units the app ships — not copies — so they exercise exactly the
hosting code that runs in production.

These exist because the native host has **no Dart/unit-test coverage** (the FFI
layer can't drive `process()`/editor/threading the way a real session does, and
CI runs no native host job). Run them by hand when changing `host_vst3.cpp`,
`native_window_controller.mm`, or the plugin lifecycle.

macOS only — the VST3 host backend is macOS-only until the Windows/Linux ports.

## Build & run

```sh
./build.sh stress          # burst/churn harness
./build.sh soak            # endurance harness
./build.sh editor_probe    # per-editor-open retention attribution
./build.sh stress asan     # any target, AddressSanitizer-instrumented
```

Each builds a binary next to the script. Binaries are git-ignored.

| Harness | What it stresses | Run |
| --- | --- | --- |
| `stress` | load → process → param-flood → state get/set → editor open/close → unload, sequentially, in an editor open/close storm, and concurrently across 8 threads. Catches refcount/teardown/use-after-free and lifecycle bugs. | `./stress [scale]` |
| `soak` | A realistic long session: N input channels × K live FX, all processing continuously for a fixed duration. Samples RSS + open-fd count over time so a slow leak shows as a slope. Periodic param automation + occasional editor open/close. | `./soak [channels] [fx] [secs] [threads]` (default `8 4 600 4`) |
| `editor_probe` | Opens/closes one plugin's editor N times per plugin and reports MB retained per open and whether unload reclaims it. Attributes editor-window memory growth. | `./editor_probe` |

The soak runs faster than real time, so a few wall-minutes covers many
*instance-audio-hours* — a conservative upper bound on a real-time session (it
does more work per wall-second than real time ever will). For a literal multi-
hour run sized to your session: `./soak 12 6 21600 6` (12×6 FX, 6 h).

## Known characteristics (verified)

- **Audio/processing path is leak-free.** With 32–80 live FX processing
  continuously, steady-state RSS is flat and open-fd count is constant; ASan
  reports zero memory errors across processing + editor + teardown.
- **Each editor *open* retains ~0.6–2.2 MB that is not released on close**, and
  is **not** reclaimed when the plugin instance is unloaded. It is uniform across
  GUI frameworks (worse for OpenGL/DPF GUIs) and coincides with the OS
  "Context leak detected, CoreAnalytics" messages — i.e. macOS window-server /
  CoreAnimation / GL-driver resource accrual from creating+destroying top-level
  editor windows, **not** host-side logic. Confirmed identical under ARC and
  non-ARC builds, so it is not a harness artifact and not an ownership bug in the
  window shim. Only matters under heavy repeated editor toggling; bounded and
  OS-reclaimable. A possible mitigation (reuse one editor window instead of
  recreating per open) is a separate follow-up.

The harnesses compile the Objective-C window shim without ARC; the app builds it
with ARC. The `editor_probe` was run both ways and the results match, so the
non-ARC build faithfully represents production for these measurements.
