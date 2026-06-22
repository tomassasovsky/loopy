---
title: "refactor: enforce repository-layer boundaries (V1 → D2 → V2)"
type: refactor
date: 2026-06-19
---

> **Note:** This plan has been split into parts. See the `-part-N` files in this directory:
> [part-1 (V1)](2026-06-19-refactor-enforce-repository-layer-boundaries-part-1-plan.md) ·
> [part-2 (D2 effects)](2026-06-19-refactor-enforce-repository-layer-boundaries-part-2-plan.md) ·
> [part-3 (D2 audio-config + pedal output)](2026-06-19-refactor-enforce-repository-layer-boundaries-part-3-plan.md) ·
> [part-4 (V2)](2026-06-19-refactor-enforce-repository-layer-boundaries-part-4-plan.md).
> This file remains the architectural overview; build from the part files in order.

## Enforce repository-layer boundaries (V1 → D2 → V2) - Extensive

## Overview

The loopy codebase is a VGV layered monorepo (Data → Repository → Business Logic →
Presentation). The architecture review ([docs/code-review/architecture-review.md](../code-review/architecture-review.md))
found the layering is **mostly** clean, with three deliberate, documented, but genuine
violations where the data layer leaks upward past the repository boundary. None breaks
the running app; all three erode the boundary the architecture exists to protect.

This plan sequences the fix as **four independently-mergeable PRs** that must land in
strict order, because each unblocks the next (the technical review confirmed both the
4-PR boundary and the ordering as non-negotiable):

| PR | Code | Violation | One-line fix |
|----|------|-----------|--------------|
| **PR 1** | **V1** | `MidiSetupCubit` (business logic) drives the data-layer `MidiControllerSource` (input path) directly | Introduce a `midi_device_repository`; the cubit depends only on it |
| **PR 2a** | **D2** (effects) | `looper_repository` re-exports raw `loopy_engine` effect/track types into the effect/routing/monitor UI | Domain models for the effects cluster; stop re-exporting them |
| **PR 2b** | **D2** (audio-config + pedal output) | `looper_repository` leaks audio-config types; `pedal_repository` leaks `midi_client.MidiDevice` (output path) | Domain models for the audio-config cluster + a pedal output-device domain model in `pedal_repository` |
| **PR 3** | **V2** | Root `pubspec.yaml` declares direct `path` deps on data packages `loopy_engine` + `midi_client` | Engine factory behind `LooperRepository` + a `main_mock.dart` flavor entrypoint; drop the direct deps |

**Order rationale:** V1 removes the `midi_client` **input**-path leak (`midi_setup_cubit`).
D2a removes the `loopy_engine` effect-model leaks; D2b removes the audio-config leaks **and**
the `midi_client` **output**-path leak (the pedal's `show MidiDevice`, which originates from
`PedalRepository.availableOutputs()` — a separate path from V1, corrected after technical
review). Only once V1+D2a+D2b have eliminated **every** `lib/` import of both data packages
can V2 drop the direct dependencies and move engine construction behind the repository.

> **Correction (technical review):** an earlier draft claimed V1's domain `MidiDevice` would
> "preempt" the pedal's `show MidiDevice` leaks. That is wrong — the pedal uses `MidiDevice`
> as an **output** device returned by `pedal_repository`, not the input source V1 owns. Giving
> `midi_device_repository` a type that `pedal_repository` then imports would create a
> repository→repository dependency, which VGV forbids. The pedal output-device domain model
> therefore lives in `pedal_repository` and is handled in PR 2b.

This is a **behavior-preserving refactor**. The acceptance bar for every PR is: the full
existing test suite (358 app tests + all package tests) stays green, `flutter analyze` and
`bloc_lint` stay clean, and no user-observable behavior changes.

## Problem Statement

### V1 — Business logic drives a data-layer client directly

`lib/audio_setup/cubit/midi_setup_cubit.dart` imports `package:midi_client/midi_client.dart`
and operates a `MidiControllerSource` (a data-layer `ControllerSource`) directly:

- `_source.enumerate()` ([midi_setup_cubit.dart:42](../../lib/audio_setup/cubit/midi_setup_cubit.dart), `:71`, `:166`)
- `_source.open(id)` (`:92`, `:127`, `:187`)
- `_source.close()` (`:145`)
- `_source.activity.listen(...)` (`:39`)

The cubit owns device enumeration, open/close, persistence reconciliation, and hotplug
lost/restored detection — orchestration that belongs in the **repository** layer. The
neighboring audio path does this correctly (`AudioSetupCubit` → `LooperRepository` →
`loopy_engine`); the MIDI path skips the repository. VGV rule: a Bloc/Cubit calls a
repository, never a data client.

### D2 — Repository re-exports data-layer models instead of transforming them

`packages/looper_repository/lib/looper_repository.dart:5-24` re-exports 20 `loopy_engine`
types straight through its barrel. They then flow into **18** presentation/logic files.
The repository *does* transform the snapshot into proper domain models (`LooperState`,
`Track`, `Lane`, `EngineStatus`), but for config/device/effect types it passes the engine's
own models through unchanged. A change to `loopy_engine`'s `EngineConfig` or `TrackEffect`
shape ripples directly into the UI.

Leak inventory (from a full-tree search), ranked by extraction friction:

| Symbol | Friction | Primary leak points |
|--------|----------|---------------------|
| `AudioBackend` (enum) | **High** | `audio_setup_cubit`, `audio_setup_state`, `audio_bootstrap`, `run_loopy`; also `settings_repository` |
| `AudioDevice` | **High** | `audio_setup_state/cubit`, `audio_device_picker`, `audio_settings_section`, `audio_bootstrap`, `app.dart`, `run_loopy` |
| `EngineConfig` | **High** | `audio_bootstrap`, `audio_setup_cubit` |
| `TrackEffect` | **High** | `effect_params_editor`, `looper_event/bloc`, `track_routing_dialog`, `monitor_cubit`, monitor graph views |
| `TrackEffectType` (enum) | **High** | effect editors, `lane_graph_view`, `track_routing_dialog`, `monitor_cubit`, `localized` |
| `TrackState` (enum) | **High** | `big_picture_view`, `pedal_cubit`, `looper_theme`, `localized` |
| `LatencyState`, `LoopbackInfo`, `ParamReadout` | **Med** | localized to audio-setup / effect-editor |
| `LoopbackKind`, `TrackEffectParam` | **Low** | `localized` / `effect_params_editor` only |

**Keepers (stay re-exported, documented exception — engine wire-format / constants, not
shapes that churn):**

- `encodeTrackEffects` / `decodeTrackEffects` — pure serializers to the engine's byte
  format. Wrapping them in domain equivalents hides the coupling without removing it, so
  they stay as re-exported functions (corrected after technical review).
- `kTrackEffectMax`, `kMaxInputs`, **`kMaxLanes`, `kTrackEffectParams`** — all four *are*
  referenced in `lib/` (`monitor_cubit`, `track_routing_dialog`, lane/monitor panels); they
  are stable native constants, not data shapes, and stay re-exported. (An earlier draft
  wrongly listed `kMaxLanes`/`kTrackEffectParams` as unused — corrected.)
- `EngineResult` — never reaches the presentation layer (the repository exposes only
  `.isOk`); it stays an internal/repository concern and may be dropped from the barrel if
  no `lib/` reference exists, else kept as a documented exception.

**`TrackState`** is already surfaced through the existing `Track` / `LooperState` domain
models. It needs **no new mapping pass** — keep it as a `show` re-export from the barrel (or
expose it as a field on `Track`), not a freshly-defined domain enum. (Clarified after review.)

Related: `packages/settings_repository/lib/src/settings_repository.dart:7` imports
`loopy_engine` solely to reuse the `AudioBackend` enum. Fix in PR 2b by giving
`settings_repository` **its own** domain `AudioBackend` enum (round-trip-tested) — **not** by
importing `looper_repository`'s, since VGV forbids repository→repository dependencies.

### V2 — App declares direct dependencies on data packages

`pubspec.yaml:25-28` lists `loopy_engine` and `midi_client` as direct `path` deps. VGV:
*"The app never depends on data packages directly. Data packages are transitive
dependencies through repositories."*

- `loopy_engine` is imported directly only in `lib/app/run_loopy.dart:15` — but it uses
  `AudioEngine` (`:24`), `NativeAudioEngine` (`:41`), `MockAudioEngine` (`:69`), and
  `AudioDevice` (`:68`). The engine **construction** is the real blocker: the composition
  root instantiates `NativeAudioEngine()` / checks `is MockAudioEngine`.
- `midi_client` is imported in 6 `lib/` files: clean wiring (`app.dart`, `midi_bootstrap.dart`,
  `pedal_bootstrap.dart`) plus the leaks resolved by V1 (`midi_setup_cubit.dart`) and the
  pedal's `show MidiDevice` usages (`pedal_cubit.dart`, `pedal_settings_section.dart`).

## Proposed Solution

Three sequential PRs, each green on its own.

### PR 1 (V1): `midi_device_repository`

Introduce a new repository package `packages/midi_device_repository` that wraps the
`MidiControllerSource` and owns the MIDI **input** device lifecycle:

- **Owns:** enumerate, open, close, hotplug poll + lost/restored supervision (the exact
  logic currently in `MidiSetupCubit._hydrate` / `refresh` / `select` / `selectNone`).
- **Exposes:** a `Stream<MidiDeviceState>` (devices + connection status + connectivity
  transitions + activity tick) and imperative commands (`select(id)`, `selectNone()`,
  `refresh()`), plus persistence via `SettingsRepository`.
- **Domain model:** a repository-owned input `MidiDevice` (id + name) so the cubit/UI never
  name the `midi_client` data type. **Scope note:** this covers only the MIDI **input**
  (controller) path. The pedal's **output** device `MidiDevice` is a distinct leak handled in
  PR 2b inside `pedal_repository` (see correction above).
- **Disposal:** the repository **borrows** the `MidiControllerSource` — `ControllerRepository`
  still owns disposal (`controller_repository.dart:92-98`). Add an explicit test asserting the
  repository does **not** dispose the source.

`MidiSetupCubit` becomes a thin projector over the repository stream (mirroring how
`AudioSetupCubit` projects `LooperRepository.looperState`). Keep a thin cubit test (verify it
forwards commands + mirrors the stream) so the cubit's own contract stays covered.

> **Decision — new package vs. fold into `controller_repository`:** Recommend a **new
> package**. `controller_repository`'s single responsibility is *mapping raw inputs to
> looper actions* (it owns the `ControllerSource` port + MIDI-learn). Device **selection/
> lifecycle** is a distinct concern; folding it in would give `controller_repository` two
> jobs. A dedicated `midi_device_repository` mirrors the one-repository-one-concern shape of
> the other packages. (The plan-technical-review / plan-splitting agent should confirm.)

### PR 2a + PR 2b (D2): repository-owned domain models for engine types

Stop re-exporting the churn-prone raw `loopy_engine` types from the `looper_repository`
barrel; introduce domain equivalents, transform at the repository boundary, and update the
leaking files. D2 touches 18 files across two type clusters, so it **splits into two
mandatory sub-PRs** (not optional):

- **PR 2a (effects cluster):** domain `TrackEffect` / `TrackEffectType` / `TrackEffectParam` /
  `ParamReadout`; update the effect/routing/monitor/theme files. `TrackState` stays a
  `show` re-export (or a field on `Track`) — no new enum. `encode/decodeTrackEffects` and the
  effect constants stay re-exported (see Keepers above).
- **PR 2b (audio-config + pedal output):** domain `AudioBackend` / `AudioDevice` /
  `EngineConfig` / `LatencyState` / `LoopbackInfo` / `LoopbackKind`; update the
  audio-setup/bootstrap/app files; give `settings_repository` its **own** `AudioBackend`
  enum. **Also (corrected scope):** add a pedal **output**-device domain model inside
  `pedal_repository` and change `PedalRepository.availableOutputs()` / `bind()` to use it, so
  `pedal_cubit` and `pedal_settings_section` stop importing `midi_client`.

### PR 3 (V2): make data packages transitive

The blocker is engine **construction + start branching** in the composition root, not just a
factory: `run_loopy.dart:69` branches on `engine is MockAudioEngine` and reads
`engine.defaultConfig`, then `:41` constructs `NativeAudioEngine()`.

- **Native path:** add `LooperRepository.native()` (constructs `NativeAudioEngine` internally)
  so shared `run_loopy.dart` no longer names the engine type.
- **Mock flavor (decided):** move the mock-engine composition into a dedicated
  **`lib/main_mock.dart` flavor entrypoint** that *is* allowed to import `loopy_engine`
  (matching VGV's `main_<flavor>.dart` convention) — it constructs the mock and calls the
  shared `runLoopy`. The shared `runLoopy` loses its `createEngine`/`is MockAudioEngine`/
  `defaultConfig` branch (today's `createEngine` injection is unused by production flavors and
  tests, so this is a clean removal). This keeps the shared app code free of `loopy_engine`
  while honoring the "a flavor entrypoint may touch the data layer for composition" rule.
- With D2b done, `AudioDevice` in `run_loopy.dart` is the domain type from `looper_repository`.
- With V1 + D2b done, no `lib/` file under the shared tree imports `midi_client`.
- Remove `loopy_engine` and `midi_client` from the root `pubspec.yaml` dependencies. They
  remain transitive via the repositories. (`lib/main_mock.dart`, if it needs `loopy_engine`,
  keeps a dev/flavor-scoped path dep — confirm whether a flavor entrypoint warrants its own
  declared dep or resolves transitively.)

## Technical Approach

### Architecture

Target dependency graph (all edges point downward; no `lib/` → data-package edges):

```
Presentation (lib/**/view)      ─┐
Business logic (lib/**/cubit|bloc)│→ Repository packages ─→ Data packages
Composition root (lib/app/*)     ─┘   looper_repository       loopy_engine
                                       midi_device_repository  midi_client
                                       pedal_repository        local_storage_client
                                       settings_repository
                                       controller_repository
                                       session_repository
```

### Implementation Phases

#### Phase 1 — PR 1 (V1): MIDI device repository

- Scaffold `packages/midi_device_repository` (pubspec `publish_to: none`, `analysis_options`,
  barrel, `src/`, `test/`). Pure Dart where possible (no Flutter SDK).
- Define domain `MidiDevice` + `MidiDeviceState` (devices, status, connectivity, activity).
- Move enumerate/open/close/hotplug-supervision/persistence out of `MidiSetupCubit` into the
  repository; expose `Stream<MidiDeviceState>` + commands. Repository **owns** the
  `MidiControllerSource` borrow contract (does not dispose it — the `ControllerRepository`
  still owns disposal, mirror today's note at `midi_setup_cubit.dart:214`).
- Rewrite `MidiSetupCubit` to subscribe to the repository stream and forward commands;
  delete its `midi_client` import.
- Wire the repository in `run_loopy.dart` / `app.dart` (construct once, inject; `RepositoryProvider`).
- **Tests:** port `midi_setup_cubit_test.dart`'s 11 scenarios into a new
  `midi_device_repository_test.dart` (enumerate, null source, activity tick, select/switch/
  failed-open/selectNone, launch auto-reconnect, hotplug lost→restored, audio independence);
  shrink the cubit test to projection + command-forwarding.
- **Success:** `MidiSetupCubit` imports no data package; `bloc_lint` + analyze clean; MIDI
  device selection/hotplug behavior unchanged; ≥90% coverage on the new package.

#### Phase 2 — PR 2a + PR 2b (D2): domain models for engine types

**Two mandatory sub-PRs** (2b depends on 2a — both edit the barrel and the shared
`localized.dart` / `app.dart` / `run_loopy.dart`, so land them in sequence to avoid a
three-way merge on those files):

- **PR 2a — Effects cluster:** domain `TrackEffect` / `TrackEffectType` / `TrackEffectParam` /
  `ParamReadout` owned by `looper_repository`. `TrackState` stays a `show` re-export (or a
  field on `Track`) — **no new enum, no mapping pass**. `encode/decodeTrackEffects` stay
  re-exported (engine wire-format keepers). Update `effect_params_editor`,
  `track_routing_dialog`, `lane_graph_view`, `monitor_cubit`, monitor graph views,
  `looper_event/bloc`, `localized` (effects portion), `looper_theme`. Drop the transformed
  effect types from the barrel; keep the documented constant/keeper exceptions.
- **PR 2b — Audio-config + pedal output:** domain `AudioBackend` / `AudioDevice` /
  `EngineConfig` / `LatencyState` / `LoopbackInfo` / `LoopbackKind`; update
  `audio_setup_cubit/state`, `audio_bootstrap`, `audio_settings_section`,
  `audio_device_picker`, `app.dart`, `run_loopy` (audio portions). Give `settings_repository`
  its **own** `AudioBackend` enum (no repo→repo import) and drop its `loopy_engine` import.
  **Pedal output (corrected scope):** add a domain output-device model in `pedal_repository`,
  change `availableOutputs()`/`bind()` to use it, and update `pedal_cubit` +
  `pedal_settings_section` so they stop importing `midi_client`.
- **Tests:** existing tests updated to domain types; add **round-trip mapping tests** at each
  repository boundary asserting effect-param **ordering** and enum-value parity (the top risk),
  not just field equality.
- **Success:** after 2b, `grep "package:loopy_engine" lib/` returns only `run_loopy.dart:15`,
  and no `lib/` file imports `midi_client`; `flutter analyze` clean; full suite green.

#### Phase 3 — PR 3 (V2): transitive data packages

- Add `LooperRepository.native()` hiding `NativeAudioEngine` construction.
- Move the mock-engine composition (`is MockAudioEngine` + `engine.defaultConfig` start
  branch) into a new **`lib/main_mock.dart`** flavor entrypoint that may import `loopy_engine`;
  remove the `createEngine`/mock branch from the shared `runLoopy`.
- Replace `run_loopy.dart`'s `NativeAudioEngine()` / `is MockAudioEngine` / `AudioEngine` /
  `AudioDevice` usages with the repository factory + the D2b domain `AudioDevice`.
- Remove `loopy_engine` and `midi_client` from the root `pubspec.yaml`; run `flutter pub get`;
  confirm transitive resolution.
- **Success:** `grep -r "package:loopy_engine\|package:midi_client" lib/` returns zero matches
  (excluding the flavor entrypoint `lib/main_mock.dart`); app builds and runs on every flavor;
  full suite green.

## Alternative Approaches Considered

- **One big PR.** Rejected — 20+ files across new package + barrel + app wiring; unreviewable
  and high blast radius. Sequenced PRs keep each green and revertable.
- **Fold the MIDI repository into `controller_repository`.** Viable (the review allowed it),
  but doubles that package's responsibility; a dedicated package is cleaner. Flagged for the
  plan-splitting review to confirm.
- **Keep re-exporting `loopy_engine` types (do V1/V2 only).** Rejected — D2 is the leak that
  actually couples the UI to the engine's shapes; skipping it leaves the highest-churn risk
  and blocks a clean V2 (`run_loopy` still needs the engine's `AudioDevice`).
- **Re-introduce a `LooperRepository.withNativeEngine()` factory** (the one removed in the
  prior review pass) — now with a real V2 purpose. Acceptable, but name/scope it for the
  mock-flavor seam too so the app never imports `loopy_engine`.

## Acceptance Criteria

### Functional Requirements

- [ ] **V1:** MIDI input device enumeration, selection, persistence, failed-open recovery,
      and hotplug lost/restored banners behave exactly as today.
- [ ] **V1:** Switching/losing a MIDI device never restarts audio (engine independence
      preserved).
- [ ] **D2:** Effect editing, routing graphs, monitor lanes, track-state colors, and ASIO/
      device pickers behave exactly as today.
- [ ] **V2:** All flavors (native + mock) build, launch, and auto-start the engine as today.

### Non-Functional Requirements

- [ ] No new runtime work on the audio thread or hotplug poll (pure boundary refactor).
- [ ] New repository packages are pure Dart (no Flutter SDK) where feasible.
- [ ] Accessibility/UX unchanged (no widget-behavior changes).

### Quality Gates

- [ ] Full suite green: 358 app tests + all package tests; new packages ≥90% coverage (CI gate).
- [ ] `flutter analyze` + `bloc_lint` clean across app and all packages.
- [ ] After PR 3: `grep -r "package:loopy_engine\|package:midi_client" lib/` returns zero
      matches **except** the flavor entrypoint `lib/main_mock.dart`.
- [ ] `MidiSetupCubit` imports no data package (after PR 1); `pedal_cubit` /
      `pedal_settings_section` import no data package (after PR 2b).
- [ ] PR 1 includes a test asserting the repository does **not** dispose the borrowed
      `MidiControllerSource`; D2 includes round-trip mapping tests (param ordering + enum parity).
- [ ] Each PR passes `plan-technical-review` scope expectations (independently mergeable).

## Success Metrics

- Direct data-package deps in root `pubspec.yaml`: **2 → 0**.
- `lib/` files importing a data package directly: **7 → 0**.
- Raw `loopy_engine` types re-exported by the `looper_repository` barrel: **~20 → constants-only**.
- Architecture-review "Important" findings closed: **3/3**.

## Dependencies & Prerequisites

- **Strict order:** PR 1 → PR 2a → PR 2b → PR 3 (confirmed by the plan-splitting review).
  PR 3's `pubspec` removals are only safe once PRs 1–2b have eliminated every `lib/` import of
  `midi_client` / `loopy_engine` (the pedal output leak clears in PR 2b, not PR 1).
- No external/package dependencies; no API or schema changes; persisted settings formats
  unchanged (domain↔engine mapping is internal).
- Prerequisite landed: the prior review-fix PR (8 bounded findings) including the removal of
  the now-unused `LooperRepository.withNativeEngine()` factory — PR 3 reintroduces a factory
  deliberately, for V2.

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| D2 domain↔engine mapping drifts (e.g. effect param ordering, enum value mismatch) | Med | High | Round-trip mapping tests at the repository boundary; land 2a/2b separately |
| V1 changes MIDI hotplug timing/semantics | Low | Med | Port the cubit's 11 scenarios verbatim into the repository test; keep poll cadence + borrow-not-own disposal identical |
| V2 mock-flavor seam forces an `loopy_engine` import back into `lib/` | Med | Med | Design the mock seam as a repository factory or a flavor-only entrypoint that legitimately depends on the data package, keeping the shared app code clean |
| Settings serialization couples to engine enum during D2 | Low | Med | Give `settings_repository` its own domain `AudioBackend`; assert round-trip persistence |
| Scope creep turns D2 into one giant PR | Med | Med | Enforce the 2a/2b split; run `plan-splitting-agent` |

## Resource Requirements

- Single engineer; estimated 3–5 focused PRs (PR1, PR2a, PR2b, PR3) over the refactor window.
- No infrastructure or CI changes beyond the new packages joining the existing per-package
  VGV workflow (analyze + test + 90% coverage gate).

## Future Considerations

- Once boundaries are clean, the data packages (`loopy_engine`, `midi_client`) become
  drop-in-replaceable and independently testable in pure-Dart contexts.
- Sets up the related suggestions from the review (drop the unnecessary Flutter SDK from the
  six pure-Dart packages; move the `ControllerSource` port to break `midi_client →
  controller_repository`) as easy follow-ups.
- A shared engine/MIDI native-loader micro-package (today duplicated between `loopy_engine`
  and `midi_client`) becomes a natural next step.

## Documentation Plan

- New package READMEs / library doc comments for `midi_device_repository` and any new domain
  models, following the existing repositories' doc style.
- Update `docs/code-review/architecture-review.md` status (or note closure in each PR body).
- Each PR body references this plan and the specific finding (V1/D2/V2).

## References & Research

### Internal References

- Architecture review (source of findings): [docs/code-review/architecture-review.md](../code-review/architecture-review.md)
- V1 target file: [lib/audio_setup/cubit/midi_setup_cubit.dart](../../lib/audio_setup/cubit/midi_setup_cubit.dart)
- Reference pattern to mirror: `AudioSetupCubit` → [lib/audio_setup/cubit/audio_setup_cubit.dart](../../lib/audio_setup/cubit/audio_setup_cubit.dart) → `LooperRepository`
- D2 barrel: [packages/looper_repository/lib/looper_repository.dart:5-24](../../packages/looper_repository/lib/looper_repository.dart)
- `ControllerSource` port owner: [packages/controller_repository/lib/controller_repository.dart](../../packages/controller_repository/lib/controller_repository.dart)
- V2 composition root: [lib/app/run_loopy.dart:15,41,68,69](../../lib/app/run_loopy.dart)
- Settings coupling: [packages/settings_repository/lib/src/settings_repository.dart:3](../../packages/settings_repository/lib/src/settings_repository.dart)

### Related Work

- Brainstorm context: [docs/brainstorm/2026-06-14-midi-usb-device-selection-brainstorm-doc.md](../brainstorm/2026-06-14-midi-usb-device-selection-brainstorm-doc.md)
- Prior plan (native MIDI device selection): [docs/plan/2026-06-14-feat-native-midi-device-selection-plan.md](2026-06-14-feat-native-midi-device-selection-plan.md)
- Preceding review-fix pass (closed the 8 bounded findings; removed the old
  `withNativeEngine` factory that PR 3 reintroduces with purpose).
