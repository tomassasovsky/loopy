# VGV Code Review — Loopy

Reviewed: full codebase (app + 9 packages, ~14k LOC of Dart in `lib/`, plus
firmware/hardware). Stack detected: Flutter desktop app scaffolded by Very Good
CLI; state management via `bloc`/`flutter_bloc` (v9); `very_good_analysis`
^10.2.0 + `bloc_lint` recommended; `mocktail` + `bloc_test` for tests; a layered
monorepo of path-dependency packages under `packages/`.

## Summary

This is an exemplary VGV-style codebase — among the cleanest a reviewer is
likely to see against this rubric. Layer separation (data `loopy_engine` →
repository `looper_repository`/others → presentation `lib/`) is rigorous and
deliberately enforced: the engine's generated FFI bindings are *not* exported,
repositories own the engine and project snapshots into domain models, and the
bloc layer depends only on repositories. Every cubit and bloc has a colocated
test; package barrels use `show` clauses to publish a curated public API;
`very_good_analysis` is applied uniformly with only one justified override
(generated FFI bindings). No `print`/`debugPrint` in production, no empty catch
blocks, six null-assertions (all guarded), one tracked TODO, two `ignore`
comments (both on generated code). Resource disposal (timers, subscriptions,
stream controllers, native handles) is consistently handled.

**Verdict: Ready to merge.** No critical issues. A small number of important
findings concern an isolated layer-separation deviation in one settings page and
a couple of convention inconsistencies. The rest are minor suggestions. The
quality bar here is high enough that the findings are refinements, not blockers.

---

## Pass 1 — Regressions & Breaking Changes

No regressions identified. This was reviewed as a whole-codebase audit rather
than a diff, but the relevant health signals are all green:

- Public repository APIs are cohesive and internally consistent; convenience
  methods (`setVolume`, `setMute`, `setInputMask`) delegate to the general
  lane-based methods rather than duplicating logic.
- `pubspec.yaml` constraints are sane: caret ranges on pub deps, path deps for
  local packages, SDK pinned to `^3.11.0` / Flutter `^3.41.0`. CI pins Flutter
  `3.44.x` consistently across all jobs (build, windows, linux) with a comment
  explaining the intent — no silent matrix drift.
- No deleted/weakened tests observed; coverage gate is enforced at 90% in CI.

---

## Pass 2 — VGV Architecture & Conventions

### What is exemplary

- **Layer separation is real, not aspirational.** `LooperRepository` owns the
  `AudioEngine`, polls snapshots on an injectable ticker, and projects them into
  `LooperState`/`Track`/`Lane` domain models. The bloc never touches the engine.
  `loopy_engine.dart` deliberately withholds the generated bindings from its
  public surface ("depend on `AudioEngine` and the value objects instead").
- **State immutability.** All 8 `*_state.dart` files use `Equatable`; states are
  immutable with `copyWith`.
- **No business logic in UI.** A scan for repository command calls
  (`record`/`clear`/`setLane*`/`setMonitor*`) inside view files came back empty
  except for the one settings-page case below. UI dispatches bloc events.
- **Disposal discipline.** `PedalCubit.close`, `LooperBloc.close`,
  `LooperRepository.dispose`, and `_AppViewState.dispose` all cancel timers /
  subscriptions / controllers and release native resources. `NativeAudioEngine`
  guards every call with `_checkAlive()` and frees its `calloc` pointers.
- **Naming passes the 5-second rule throughout**: `LooperRepository`,
  `MidiControllerSource`, `WaveformWindowService`, `PedalStateFrame`,
  `AudioSetupCubit`. No `Manager`/`Handler`/`Utils` offenders.
- **Reconnect/supervision logic** in `LooperRepository` is genuinely
  sophisticated (device-loss supervision, attempt-signature debouncing to avoid
  engine thrash) and is well-commented and unit-tested.

### 🟡 Important

- **`lib/looper/view/big_picture_settings_page.dart:187-229`
  (`_routingSection`)** — The settings page reads `LooperRepository` and
  `SettingsRepository` directly from the widget, subscribes to
  `repository.looperState` via a `StreamBuilder`, and on edit calls
  `repository.setInputMask(...)` / `repository.setOutputMask(...)` *and*
  `settings.saveLaneInput(...)` / `settings.saveLaneOutput(...)` inline. This is
  the one place presentation reaches past the bloc into the repository + data
  persistence, and it duplicates the exact "forward to repository, then persist
  to settings" pairing that `LooperBloc` already implements for
  `LooperLaneInputChanged` / `LooperLaneOutputChanged`.
  - Why: It is the sole layer-separation deviation in the app and it duplicates
    bloc logic, so the two paths can drift (e.g. if persistence semantics
    change, only one path gets updated). The in-code comment correctly explains
    the *cause* — the settings page is pushed above the `LooperBloc` provider —
    but the cause is a wiring choice, not a constraint.
  - Fix: Provide the existing `LooperBloc` to the settings route (as
    `track_routing_dialog.dart` already does via `BlocProvider.value(value:
    bloc)`), then dispatch `LooperLaneInputChanged` / `LooperLaneOutputChanged`
    instead of calling the repository and settings directly. That removes the
    `StreamBuilder`-on-repository and the duplicated persistence, and makes the
    settings routing controls testable at the bloc level like the in-view ones.

- **`lib/pedal/cubit/pedal_cubit.dart:112-118`** — `availableOutputs()` and
  `boundOutputId` are public cubit members that pass repository data straight
  through, each suppressing `prefer_void_public_cubit_methods` from `bloc_lint`.
  - Why: A cubit exposing imperative read-through accessors to its repository
    blurs the "UI reads state, not the cubit's collaborators" boundary, which is
    exactly what the lint guards against. The settings picker that consumes these
    could instead read them off `PedalState`.
  - Fix: Surface the available outputs and bound-output id as fields on
    `PedalState` (the cubit already emits an `outputsTick` when the set changes —
    fold the list/id into state at the same point), and delete the two
    pass-through members and their `ignore` comments. If they must remain for
    pragmatic reasons, that is defensible, but it should be a conscious call, not
    silently lint-suppressed.

### 🔵 Suggestions

- **`packages/pedal_repository/lib/pedal_repository.dart`** exports its `src/`
  files with no `show` clauses, unlike `loopy_engine`, `looper_repository`,
  `midi_client`, and `routing_graph`, which all curate their public API with
  `show`. Tighten the pedal barrel to publish only the intended types
  (transports, codec, event/frame/button models, repository) for consistency and
  to keep internal helpers encapsulated.
- **`packages/routing_graph/lib/routing_graph.dart:12`** re-exports
  `package:flutter/material.dart`. This is a common UI-package convenience but it
  leaks the entire Material API through the package's surface; consider dropping
  it so consumers import Material explicitly.
- **`analysis_options.yaml:9`** disables `public_member_api_docs` at the app
  root while the packages keep it on (and are well-documented). That is the
  conventional split for an app vs. publishable packages, so this is fine — noted
  only for completeness.

---

## Pass 3 — Testing Quality

### Coverage map

- **Every** state-management unit has a colocated test: all 12 app cubits/blocs
  (`audio_setup`, `midi_setup`, `monitor`, `looper_bloc`, `bank`, `big_picture`,
  `quantize`, `record_options`, `refresh_rate`, `pedal`, `session`,
  `waveform_window`) map 1:1 to a `*_test.dart`.
- Package test ratios are healthy: `routing_graph` 11 src / 10 tests,
  `pedal_repository` 9/7, `loopy_engine` 12/7, `midi_client` 6/4,
  `session_repository` 4/3, `looper_repository` 8/3 (with a 1033-line test file
  plus a `fake_audio_engine` helper).
- CI enforces `min_coverage: 90` via the VGV `flutter_package` workflow, with a
  documented, defensible exclusion list (window chrome, the
  `desktop_multi_window` sub-window, bootstrap/entrypoint glue — none of which is
  meaningfully unit-testable).

### Quality

- Tests use idiomatic `blocTest` with `verify:` blocks asserting side effects on
  mocked repositories (e.g. `session_cubit_test` verifies `repository.save`,
  `load`, `exportStems` each called once) — these read as "0 expect" to a naive
  grep but are correct VGV style.
- Failure/edge paths are covered, not just happy paths:
  `midi_looper_integration_test` asserts `verifyNever(() => repository.record())`
  / `verifyNever(() => repository.clear())` for the negative case alongside the
  positive `called(1)` cases.
- No tautologies (`expect(true, isTrue)`), no assertion-free tests, no
  mock-everything-test-nothing patterns found.
- Golden/screenshot tests are gated behind a `screenshots` tag with a documented
  self-skip on machines lacking the Material fonts/goldens — a pragmatic, honest
  approach that does not block CI.

### 🔵 Suggestions

- Two pass-through members on `PedalCubit` (see Pass 2) are exercised only
  indirectly; if they are folded into `PedalState` as suggested, the picker's
  output-list behavior becomes directly bloc-testable.

---

## Pass 4 — Simplicity & YAGNI Audit

This codebase is already close to minimal for the problem it solves (a
multi-track, multi-lane, multi-input looper with effects, MIDI, a hardware
pedal, and latency compensation). The abstractions earn their keep:

- `AudioEngine` has two real implementations (`NativeAudioEngine`,
  `MockAudioEngine`) — the interface is justified, not premature.
- `PedalTransport` has `NativePedalTransport` and `NoopPedalTransport` (the
  no-op substitutes when no MIDI backend exists, keeping the cubit always
  present) — justified.
- Convenience methods on `LooperRepository` (`setVolume`, `setInputMask`, …)
  delegate to general lane methods; they are thin and reduce caller noise rather
  than obscure.

### Observations

- **`LooperRepository` carries a large set of `_lane*` / `_monitor*` maps**
  (~12 maps) that mirror engine state so it can be re-applied on every
  device restart/reconnect. This is essential complexity (a fresh engine start
  resets all engine state), it is thoroughly commented, and the re-apply ordering
  is correct (counts before per-lane routing). Not a YAGNI violation — but it is
  the single densest class (907 LOC) and a candidate for future extraction of the
  "remembered engine state" into a dedicated value object if it grows further.
  No action needed now.
- No commented-out code, no speculative configuration options, no
  `BaseRepository<T>` generics-for-one-impl, no dead extensibility points found.

### Complexity verdict: **Already minimal.** Minor tweaks only (the dedup in
`big_picture_settings_page.dart` would *remove* lines, not add structure).

---

## Repository Hygiene (non-blocking)

- `.gitignore` correctly excludes `build/`, `coverage/`, `logs/`, and
  `.history` — confirmed `git ls-files` tracks 0 files under those paths. The
  editor-history `.history/.git` directory seen in the working tree is untracked.
  Good.
- `hardware/` and `firmware/` carry KiCad fab outputs (Gerbers), an Arduino
  sketch, and a C protocol implementation shared with `pedal_repository`'s codec
  as a single contract — out of scope for Dart conventions, but the firmware has
  its own `test/test_pedal_protocol.c`, which is a nice touch.

---

## Findings Index

| Severity | Location | Issue |
| --- | --- | --- |
| 🟡 Important | `lib/looper/view/big_picture_settings_page.dart:187-229` | Settings routing section bypasses `LooperBloc`, calling repository + settings directly and duplicating bloc persist/forward logic |
| 🟡 Important | `lib/pedal/cubit/pedal_cubit.dart:112-118` | Public read-through cubit members (`availableOutputs`, `boundOutputId`) with `bloc_lint` suppressions; prefer exposing via `PedalState` |
| 🔵 Suggestion | `packages/pedal_repository/lib/pedal_repository.dart` | Barrel exports `src/` without `show` clauses, inconsistent with sibling packages |
| 🔵 Suggestion | `packages/routing_graph/lib/routing_graph.dart:12` | Re-exports all of `package:flutter/material.dart` |
| 🔵 Suggestion | `packages/looper_repository/lib/src/looper_repository.dart` | Consider extracting the ~12 remembered-engine-state maps into a value object if the class grows |
