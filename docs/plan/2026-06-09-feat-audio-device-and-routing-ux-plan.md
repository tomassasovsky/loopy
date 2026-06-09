# feat: audio device management, loopback exclusion, settings UX, and routing visualizer

Type: **feat** · Status: **planned (follow-up)** · Created: 2026-06-09

A follow-up bundle of UX + device-management features requested after the
multichannel per-track I/O routing work. Split into focused PRs so each is
independently reviewable and mergeable.

> **Note:** After technical review, **PR A was sub-split** into two standalone
> plans (it touched every layer at ~600–850 LOC):
> - **A1 — native device enumeration + presence + FFI:**
>   [part-a1 plan](2026-06-09-feat-audio-device-selection-part-a1-native-ffi-plan.md)
> - **A2 — reconnect supervisor + selection/persistence + banner UI:**
>   [part-a2 plan](2026-06-09-feat-audio-device-selection-part-a2-supervisor-ui-plan.md)
>
> The "PR A" section below is retained for context; build from the A1/A2 files.

---

## Sequencing & dependencies (read first)

This work must NOT start until two things have landed, to avoid colliding with
in-flight changes:

1. **The multichannel routing PR** (`feat/multichannel-routing`) — these
   features build on `input_mask` / `output_mask`, `EngineStatus`
   `inputChannels`/`outputChannels`, the `TrackRoutingPanel`, and the routing
   bloc events.
2. **The concurrent Big-Picture / settings rework** currently uncommitted in the
   tree — it restructures `lib/looper/view/big_picture_view.dart`
   (`_TrackColumn` / `_PeakBar`) and rebuilds `big_picture_settings_page.dart`
   around `lib/setup/SetupSurface*`. PRs **C** (settings tabs/escape) and **D**
   (play-mode visuals/shadow) edit exactly those files, so they must rebase onto
   the reworked versions, not the current `HEAD`.

Recommended order: **A1 → {A2, B}** (native/device, independent of the UI
rework) can start as soon as the multichannel PR merges; **C, D** wait for the BP
rework; **E** (visualizer) depends on **A1 + B** — it needs `inputMask`/
`outputMask` (A1's enumeration is not enough on its own) and the
`excluded_input_mask` from **B** to mark loopback channels, so it must follow B,
not merely "A/B in parallel".

```
multichannel PR ─► A1 ─┬─► A2 (supervisor + cubit + UI)
                       ├─► B  (loopback exclusion) ─► E (routing visualizer)
BP/settings rework ────┴─► C, D  (independent of each other)
```

## Decisions (locked by the user)

- **Audio device selection:** default to **System default**; allow pinning a
  specific device. On disconnect, show an **in-app banner/snackbar**; keep
  trying to reopen the pinned device and notify (banner) when it comes back.
- **Loopback exclusion is per-channel:** the user's interface labels individual
  channels (e.g. "Loopback 1/2"). Detect those channel **labels** and exclude
  them from recording, monitoring, and the routing UI — they must never be a
  record source or monitored. (miniaudio does not expose channel labels;
  query Core Audio `kAudioObjectPropertyElementName` directly on macOS — the
  engine already links CoreAudio/AudioToolbox. Other platforms: no-op.)
- **Settings page gets tabs** (one per section) and **Escape pops** the page.
- **Play-mode track bars:** every track shows at least `0.01` bar height;
  a track armed/selected to play is **green**; a muted track is **white**.
- **Remove the green/red record/overdub/mute drop shadow** on track tiles —
  replace with a cleaner state treatment (border/ring + icon, no glow).
- **Routing visualizer** defaults to a **read-only `CustomPaint` diagram** (no
  new dependency); only reach for a node-flow package (`vyuh_node_flow` /
  `graph_edit`) if a concrete need exceeds what `CustomPaint` can do.

## Codebase context & conventions

VGV layered monorepo. Native engine in `packages/loopy_engine/src/` (RT-safe
audio callback; control→audio via the SPSC ring; audio→control via per-field
`_Atomic` snapshots). FFI bindings are regenerated with
`dart run ffigen --config ffigen.yaml` after any `loopy_engine_api.h` change.
Native tests: `clang … src/test/test_engine_core.c …` (device-free). Dart/Flutter
tests via the absolute `/Users/Tomas/development/flutter/bin/flutter`. App reaches
the engine only through `package:looper_repository` (no `loopy_engine` import in
`lib/`). Keep every PR green: native `ALL PASSED`, `flutter analyze`, app suite,
macOS build.

---

## PR A — Audio device selection + disconnect/reconnect  *(superseded — see A1/A2)*

> **Superseded.** This section is split into
> [A1](2026-06-09-feat-audio-device-selection-part-a1-native-ffi-plan.md) (native
> + FFI) and
> [A2](2026-06-09-feat-audio-device-selection-part-a2-supervisor-ui-plan.md)
> (supervisor + UI). Two review-driven changes were folded into those plans:
> device IDs persist inside **`StoredAudioConfig`** (not loose
> `audio.*_device_id` keys), and lost/restored events are **derived from
> `EngineStatus.devicePresent`** in the cubit (no separate repository stream).
> The original detail is kept below for context.

Goal: choose the output/input device (default = system); detect disconnects;
auto-recover a pinned device; surface it all through the repository.

Native (`loopy_engine_api.h` / `engine.c`):
- Device enumeration: `le_device_info { char id[256]; char name[256]; int32_t
  is_default; }` and `le_enumerate_playback_devices` /
  `le_enumerate_capture_devices(le_device_info* out, int32_t max, int32_t*
  count)` using a `ma_context` (`ma_context_get_devices`).
- `le_config`: add `char playback_device_id[256]` / `char capture_device_id[256]`
  (empty => system default). In `le_engine_start`, when set, resolve the id and
  set `cfg.playback.pDeviceID` / `cfg.capture.pDeviceID` (reuse the existing
  explicit-context path used for loopback capture).
- Disconnect detection: set `cfg.notificationCallback`; on a `stopped` /
  `rerouted` / device-lost notification, publish an atomic
  `a_device_state` (running / lost) into `le_snapshot` (e.g.
  `device_present`). The callback is RT-adjacent — only store an atomic, no
  work. **No reconnection logic in native** (RT contract): recovery is driven
  from Dart.
- Snapshot: add `device_present` (0/1) and keep `running`.

FFI regen.

Dart (`loopy_engine`):
- `EngineConfig`: `playbackDeviceId` / `captureDeviceId` (default `''`).
- New value object `AudioDevice { id, name, isDefault, isInput }` +
  `AudioEngine.enumerateDevices()` (returns inputs+outputs).
- `EngineSnapshot.devicePresent`.

Repository (`looper_repository`):
- Surface `devices()` and `EngineStatus.devicePresent`.
- **Reconnect supervisor** (control thread / Dart): when a pinned device goes
  absent then reappears in enumeration, stop+restart the engine on it. Expose a
  stream of device events (`DeviceLost(name)`, `DeviceRestored(name)`).

App:
- `AudioSetupCubit`/state: `deviceId` selection (System default + the enumerated
  list); persist via `settings_repository` (`audio.playback_device_id`,
  `audio.capture_device_id`; empty = system). Restore on launch in
  `tryAutoStartEngine`.
- Device picker UI in the audio-setup section.
- **In-app banner/snackbar** on `DeviceLost` ("… disconnected — trying to
  reconnect") and `DeviceRestored` ("… reconnected"). Use a `ScaffoldMessenger`
  / `MaterialBanner` at the app shell so it shows in both layouts.

Tests: native enumeration smoke + config id plumbing; repository reconnect
supervisor (fake engine emitting lost/restored); cubit selection + persistence;
banner widget test.

Acceptance: pick a device and it opens; unplug → banner + engine marked
not-present; replug → auto-reopens the same device + banner; "System default"
still works; native `ALL PASSED`; analyze clean; macOS builds.

## PR B — Per-channel loopback exclusion (macOS Core Audio)

Goal: channels whose Core Audio label contains "loopback" (case-insensitive) are
never recordable/monitorable and are hidden/disabled in routing. Match on a plain
`contains("loopback")` — do **not** pre-build a synonym list; add synonyms only
if a real driver is found that needs them.

Native:
- New macOS-only source (e.g. `engine_channel_labels.m` or C using
  `<CoreAudio/CoreAudio.h>`): given a capture `ma_device_id`/AudioObjectID,
  query each input channel's `kAudioObjectPropertyElementName` and build a
  bitmask of channels whose name matches "loopback"/synonyms. Non-macOS: return
  0 (nothing excluded).
- `engine.c`: at device open, compute `a_excluded_input_mask`; publish it in
  `le_snapshot` (`excluded_input_mask`). In the capture average, **skip excluded
  channels**; in monitoring passthrough, skip excluded channels; in
  `LE_CMD_SET_INPUT_MASK`, clamp out excluded bits so a track can never select
  one.
- Pure helper `le_label_is_loopback(const char*)` for a device-free unit test.

FFI regen.

Dart/repository: `EngineStatus.excludedInputMask`; expose to the routing UI.

App: in `TrackRoutingPanel`, render excluded input chips disabled with a
"(loopback)" tag (or omit them); never include excluded bits when toggling.

Tests: `le_label_is_loopback` unit cases; native test that an excluded channel
is dropped from the input average and rejected by `SET_INPUT_MASK`; widget test
that excluded input chips are disabled.

Acceptance: a "Loopback" input channel cannot be recorded or monitored and is
disabled in the UI; everything else unchanged; native `ALL PASSED`.

## PR C — Settings page tabs + Escape-to-pop  *(rebase onto BP/settings rework)*

Goal: tabbed sections in `BigPictureSettingsPage`; `Esc` closes it.

- Wrap the settings body in a tab layout (Material `TabBar`/`TabBarView` or a
  `NavigationRail`, matching the new `SetupSurface` styling) — one tab per
  section: **View · Audio · Tracks · Routing** (and **Devices** from PR A).
- Add a `Focus`/`Shortcuts` (or `CallbackShortcuts`) handler so
  `LogicalKeyboardKey.escape` calls `Navigator.maybePop()`. Confirm it does not
  swallow Esc from text fields (rename dialog).

Tests: widget tests — switching tabs shows the right section; pressing Esc pops.

Acceptance: sections are tabs; Esc closes settings; analyze clean; app suite
green. **Must be authored against the reworked `big_picture_settings_page.dart`.**

## PR D — Play-mode track visuals + shadow redesign  *(rebase onto BP rework)*

Goal: clearer play-mode meters; no glow.

In the reworked `_TrackColumn` / `_PeakBar`:
- Bar height floor: `heightFactor` clamps to a min of `0.01` for every track in
  **play** mode (so empty/idle tracks still show a sliver).
- Color rules in play mode: a track armed/selected to play → **green**; a muted
  track → **white**; otherwise the track accent. (Define semantic colors in
  `LooperTheme` rather than hard-coding.)
- Remove the `boxShadow` glow on record/overdub/mute. Replace the "active" cue
  with a crisp border/ring (+ existing REC indicator), no colored blur.

Tests: widget tests asserting min-height in play mode, the green/white/accent
mapping, and absence of the `boxShadow` — assert `BoxDecoration` properties
directly rather than goldens (goldens are pixel-brittle across Flutter
versions). Add a `LooperTheme` test for the new semantic play-mode colors
(`test/theme/looper_theme_test.dart`).

Acceptance: play-mode bars never fully collapse; selected=green, muted=white;
no glow; desktop + big-picture both updated; analyze clean.

## PR E — Routing visualizer (node-flow)

Goal: a visual graph of how audio is routed: **hardware inputs → tracks →
hardware outputs**, reflecting per-track `inputMask` / `outputMask`, with
excluded loopback channels marked.

- **Default to a `CustomPaint` diagram.** A read-only three-column graph is
  ~50 lines with zero new dependencies, no null-safety unknowns, and no
  maintenance/license risk. Only evaluate `vyuh_node_flow` / `graph_edit` if a
  concrete need (interactivity, layout) emerges that `CustomPaint` can't meet;
  if so, vet null-safety, desktop/macOS support, maintenance, and license, then
  pin one and note the decision.
- Build a `RoutingGraphView`: input nodes (left), track nodes (middle), output
  nodes (right); edges from each selected input→track and track→each masked
  output. Live-updates from `LooperBloc` state. **Read-only.** (Drag-to-connect
  editing is explicitly out of scope — do not carry it as a "later iteration"
  note here.)
- Reach it from a Settings "Routing" tab (PR C) and/or a button in the views.

Tests: widget test that the graph renders the expected node/edge counts for a
known routing state; a dependency-vetting note in the PR.

Acceptance: the visualizer shows current routing and updates as masks change;
dependency vetted; analyze clean; macOS builds.

---

## Risks / notes

- **Concurrent-rework collision (C, D):** do not author against current `HEAD` —
  rebase onto the merged BP/settings rework or conflicts are guaranteed.
- **Core Audio channel labels (B)** are macOS-only and some drivers leave them
  blank; treat "no label" as not-loopback. Add the `.m`/C source to the SPM
  `Package.swift` and the CocoaPods fallback (see the FFI macOS build notes).
- **Device hot-plug (A)** is the fiddliest path; keep all reconnection logic on
  the Dart side (poll enumeration), never in the audio callback. Test the
  supervisor with a fake engine.
- **FFI struct changes (A, B)** mean ffigen regen + a macOS rebuild to confirm
  native/Dart struct agreement.
- Each PR ships its own tests + green gates; keep them small and focused rather
  than one mega-branch.
