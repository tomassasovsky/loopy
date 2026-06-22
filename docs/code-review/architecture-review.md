# Architecture Review

**Project:** loopy — cross-platform desktop loopstation (Flutter/Dart, VGV layered monorepo)
**Scope:** Full codebase — `lib/` (presentation + business logic) and `packages/` (data + repository layers)
**Standard:** VGV layered architecture (Data → Repository → Business Logic → Presentation, unidirectional)
**Date:** 2026-06-19

---

## Summary

The codebase is a well-organized VGV layered monorepo. State management is exemplary: Bloc/Cubit
throughout, constructor-injected dependencies, immutable `Equatable` states, business logic in the
logic layer, and disciplined stream/subscription disposal. The repository layer mostly does its job
as the single source of truth, and the dependency graph is acyclic.

Two architectural rules are being bent, both deliberate and documented in code, but both still
genuine VGV-standard violations worth recording:

1. **A business-logic unit (`MidiSetupCubit`) drives a data-layer client directly**, bypassing the
   repository layer for MIDI device management.
2. **The repository layer re-exports data-layer (engine) models instead of transforming them into
   domain models**, and the app declares **direct path dependencies on two data-layer packages**
   (`loopy_engine`, `midi_client`).

Neither blocks the app from working, but both erode the layer boundary the architecture exists to
protect. Below, each is reported with file and line.

---

## Layer Separation

The four layers are present and mostly clean:

- **Data layer** (`packages/`): `loopy_engine` (native FFI audio engine), `local_storage_client`
  (shared_preferences), `midi_client` (native USB MIDI). Verified clean: no `package:flutter/material`,
  no repository imports, no `package:loopy/` imports.
- **Repository layer** (`packages/`): `looper_repository`, `controller_repository`,
  `pedal_repository`, `session_repository`, `settings_repository`. No presentation imports.
- **Business logic** (`lib/<feature>/bloc|cubit/`) and **presentation** (`lib/<feature>/view/`):
  cleanly separated per feature.

### Violations found: 2

#### V1 (Important) — Business logic depends on a data-layer client directly

`lib/audio_setup/cubit/midi_setup_cubit.dart:6` — `MidiSetupCubit` (business logic) imports
`package:midi_client/midi_client.dart` and operates `MidiControllerSource` (a data-layer
`ControllerSource`) directly: `_source.enumerate()` (`:42`, `:71`, `:166`), `_source.open(...)`
(`:92`, `:127`, `:187`), `_source.close()` (`:145`), and `_source.activity.listen(...)` (`:39`).

The cubit owns device enumeration, open/close, persistence reconciliation, and hotplug
lost/restored detection — orchestration logic that belongs in the **repository** layer. VGV: a
Bloc/Cubit calls a repository, never a data client. The neighboring audio path does this correctly
(`AudioSetupCubit` → `LooperRepository` → `loopy_engine`); the MIDI path skips the repository.

**Fix:** introduce a `MidiDeviceRepository` (or fold this into `controller_repository`) that wraps
the `MidiControllerSource`, owns enumerate/open/close + hotplug supervision, and exposes a
`Stream<MidiDeviceState>` + commands. `MidiSetupCubit` then depends only on that repository.

#### V2 (Important) — App declares direct dependencies on data-layer packages

`pubspec.yaml:25-28` — the root app lists `loopy_engine` and `midi_client` as direct `path:`
dependencies. VGV is explicit: *"The app never depends on data packages directly. Data packages are
transitive dependencies through repositories."*

In practice the blast radius is limited:
- `loopy_engine` is imported directly **only** in `lib/app/run_loopy.dart:15` (bootstrap wiring),
  which is the one acceptable place to touch a data layer for composition. Everywhere else the engine
  types arrive through the `looper_repository` barrel (see Dependency Direction, D2).
- `midi_client` is imported in five `lib/` files: `app/run_loopy.dart`, `app/view/app.dart`,
  `app/midi_bootstrap.dart`, `app/pedal_bootstrap.dart` (all wiring), plus two non-wiring leaks:
  `lib/audio_setup/cubit/midi_setup_cubit.dart:6` (see V1) and
  `lib/pedal/cubit/pedal_cubit.dart:6` (`show MidiDevice`), and one view:
  `lib/pedal/view/pedal_settings_section.dart:7` (`show MidiDevice`).

`midi_client` cannot become purely transitive until V1 is resolved and `MidiDevice` is re-exported
from a repository (today the presentation/logic layers import the data model `MidiDevice` directly
rather than a domain type).

### Clean files

- All data packages (`loopy_engine`, `local_storage_client`, `midi_client`) — no upward imports
  except the deliberate `ControllerSource` inversion (see D1).
- `routing_graph` (UI toolkit package) — depends on Flutter only; no repository, engine, or bloc
  imports. Correctly portable.
- The looper feature (`looper_bloc` → `looper_repository` → `loopy_engine`) — textbook layering.

---

## State Management Assessment

Stack: `bloc` / `flutter_bloc` with `bloc_lint` enforced, `equatable` states, `bloc_test` +
`mocktail` in dev. Page/View + `BlocProvider`/`RepositoryProvider` wiring via
`MultiRepositoryProvider` + `MultiBlocProvider` in `lib/app/view/app.dart`.

| Unit | Verdict | Notes |
| --- | --- | --- |
| `LooperBloc` | Correct | Commands forwarded to repository; state mirrors `repository.looperState`; clean `close()` cancels both subscriptions. Controller events translated to looper actions in one place. |
| `PedalCubit` | Correct (one leak) | Constructor injection, immutable `PedalState`, looper as single source of truth, disposes subs/timer. Imports data model `MidiDevice` from `midi_client` (`pedal_cubit.dart:6`) — see V2. |
| `AudioSetupCubit` | Correct | Goes through `LooperRepository` — the reference pattern the MIDI path should mirror. |
| `MidiSetupCubit` | **Issue** | Drives a data-layer client directly (V1). State handling itself (immutable `copyWith`, disposal, borrow-not-own discipline on the source) is otherwise correct. |
| `MonitorCubit`, `RecordOptionsCubit`, `QuantizeCubit`, `RefreshRateCubit`, `BigPictureCubit`, `BankCubit`, `WaveformWindowCubit` | Correct | Injected repositories/settings, `load()` hydration, focused responsibilities. |

General observations:
- Naming is descriptive and convention-following (no generic `Manager`/`Handler`).
- States are immutable `Equatable` with `copyWith`; no mutable state fields observed.
- Business logic sits in the logic layer, not in views (views in `lib/**/view/` are presentational;
  e.g. `effect_params_editor.dart` is callback-driven).
- Provider lifecycle is correct: eager (`lazy: false`) only where launch-time side effects require
  it (MIDI reconnect, pedal auto-bind, monitor apply), with the reasons documented inline.

No over- or under-engineering detected — Cubit for simpler flows, Bloc for the event-rich looper.

---

## Dependency Direction

The graph is **acyclic**. Repository → Data path dependencies:

```
looper_repository    → loopy_engine
session_repository   → loopy_engine
settings_repository  → local_storage_client, loopy_engine
controller_repository → (none; defines ControllerSource port)
pedal_repository     → midi_client
midi_client          → controller_repository   ← upward (see D1)
```

### Direction notes: 3

#### D1 (Suggestion) — `midi_client` (data) depends on `controller_repository` (repository)

`packages/midi_client/lib/src/midi_controller_source.dart:4` imports `controller_repository`.
This is **dependency inversion**, not a true violation: `controller_repository` owns the
`ControllerSource` abstract interface (`controller_repository/lib/src/controller_source.dart`), and
`midi_client`'s `MidiControllerSource implements ControllerSource`. The data client depends on an
*interface* the repository defines — a legitimate pattern.

The cost is that `midi_client` is no longer a reusable, repository-free data package (it cannot be
dropped into an unrelated project without dragging `controller_repository`). If strict data-layer
portability matters, move the `ControllerSource` port into a small interface package (or into
`midi_client` itself) so the dependency points downward. Confined to one file; low priority.

#### D2 (Important) — Repository re-exports data-layer models instead of transforming them

`packages/looper_repository/lib/looper_repository.dart:5-24` re-exports ~20 `loopy_engine` types
straight through its barrel: `AudioBackend`, `AudioDevice`, `EngineConfig`, `EngineResult`,
`TrackEffect`, `TrackEffectParam`, `TrackState`, `encodeTrackEffects`, `kTrackEffectMax`, etc.

These engine types then flow into 18 presentation/logic files (e.g.
`audio_setup/view/audio_device_picker.dart`, `common/effect_params_editor.dart`,
`audio_setup/cubit/monitor_cubit.dart`). VGV anti-pattern: *"Transform data models into domain
models — never leak API response shapes upstream."* The repository **does** transform the snapshot
into proper domain models (`LooperState`, `Track`, `Lane`, `EngineStatus` — see
`looper_repository.dart:269` `_project`), but for config/device/effect types it passes the data
layer's own models through unchanged. A change to `loopy_engine`'s `EngineConfig` or `TrackEffect`
shape ripples directly into the UI.

Related: `settings_repository` imports `loopy_engine` (`settings_repository.dart:3`) solely to reuse
the `AudioBackend` enum — a repository coupling to another layer's data package for a single type.

**Fix (incremental):** introduce repository-owned domain equivalents for the leaked types most
likely to churn (`EngineConfig`, `TrackEffect`, device descriptors) and stop re-exporting the raw
engine types. Lower-risk constants (`kTrackEffectMax`) can stay. This also resolves V2 by removing
the need for the app to ever name `loopy_engine`.

#### Clean dependencies

- No circular dependencies anywhere.
- No inter-repository dependencies (each repository is isolated; `pedal_repository` depends on the
  *data* package `midi_client`, not on another repository — correct direction).
- `pedal_repository → midi_client` and all `*_repository → loopy_engine`/`local_storage_client`
  edges point downward as required.

---

## Package Structure

Every package has a `pubspec.yaml` (named, `publish_to: none`), an `analysis_options.yaml`, a
barrel file, a `src/` directory, and a `test/` directory (verified present for all nine). `src/` is
never imported across package boundaries by consumers. Local packages use `path:` dependencies
exclusively (no `git:`/version refs). Responsibilities are single and clear.

### P1 (Suggestion) — Data/repository packages carry an unnecessary Flutter SDK dependency

VGV: *"No Flutter SDK in data or repository packages"* — they should be pure Dart packages so they
remain usable in Dart-only contexts (CLIs, servers, tests without a Flutter binding). Actual Flutter
usage per package:

| Package | Flutter import surface | Needs Flutter SDK? |
| --- | --- | --- |
| `controller_repository` | none | No — drop `flutter` |
| `local_storage_client` | none (uses `shared_preferences`) | No — drop `flutter` |
| `looper_repository` | none | No — drop `flutter` |
| `midi_client` | none | No — drop `flutter` |
| `pedal_repository` | none | No — drop `flutter` |
| `session_repository` | none | No — drop `flutter` |
| `loopy_engine` | `package:flutter/foundation` only | No — swap to `package:meta` |
| `settings_repository` | `package:flutter/foundation` only | No — swap to `package:meta` |
| `routing_graph` | `flutter/material` (UI package) | **Yes** — legitimate |

Six packages import nothing from Flutter yet pin `flutter: ^3.41.0` and depend on `flutter_test`.
Two use only `foundation` (`@immutable`, `debugPrint`) reachable via `package:meta`/`dart:developer`.
Converting these to plain Dart packages (test with `package:test`, not `flutter_test`) restores
portability and speeds their test runs. Note `loopy_engine` declares a Flutter FFI *plugin*
(`pubspec.yaml flutter.plugin.platforms`), so it must remain a Flutter package regardless — only its
`foundation` import is incidental.

### P2 (Suggestion) — `lib/common/` and `lib/setup/` are loose, non-feature buckets

`lib/common/effect_params_editor.dart` and `lib/setup/setup_surface.dart` are single-file
directories holding shared presentational widgets. Harmless, but as shared UI grows these are the
seed of a grab-bag. Consider promoting durable shared widgets into the `routing_graph` UI package or
a dedicated `app_ui`-style package, and keeping `lib/<feature>/` strictly feature-scoped.

### Clean structure

- `routing_graph` is correctly a standalone UI package, separate from business logic, theming via a
  package-local `RoutingGraphTheme` extension.
- Barrel discipline is consistent; `src/` encapsulation is respected at every boundary.
- `controller_repository` imports its own `src/` files via `package:controller_repository/src/...`
  rather than relative paths (4 files). Intra-package only — a style nit, not a boundary violation.

---

## Verdict

**Architecture is sound — fix 3 important issues to fully meet VGV standards.**

The layered structure, acyclic dependency graph, and state-management discipline are strong. The
work to close the gap is well-bounded:

- **Important (3):**
  - V1 — `MidiSetupCubit` bypasses the repository layer to drive `MidiControllerSource` directly;
    introduce a MIDI device repository.
  - V2 — root `pubspec.yaml` declares direct dependencies on data packages `loopy_engine` /
    `midi_client`; route through repositories (largely resolved once V1 + D2 land).
  - D2 — `looper_repository` re-exports raw `loopy_engine` models instead of transforming them into
    domain models, leaking data-layer shapes into 18 UI/logic files.
- **Suggestions (4):** D1 (`ControllerSource` inversion couples `midi_client` to a repository),
  P1 (drop the unnecessary Flutter SDK from six pure-Dart packages), P2 (loose `common/`/`setup/`
  buckets), plus the `settings_repository → loopy_engine` enum coupling folded into D2.

None are merge-blockers for a working build, but V1/V2/D2 are the difference between "follows VGV"
and "mostly follows VGV." Address them at the next opportunity, ideally V1 → D2 → V2 in that order
(each unblocks the next).
