# Code Simplicity Review

**Project**: loopy (Flutter/Dart multi-package monorepo)
**Date**: 2026-06-19
**Scope**: Full codebase — Dart packages, app layer, C engine, build tooling

---

## Simplification Analysis

### Core Purpose

loopy is a real-time multi-track looper. Its Dart layer owns UI state management (BLoC/cubit), device selection, MIDI controller mapping, bidirectional foot-pedal protocol, settings persistence, and session save/restore. A native C audio engine does all DSP. FFI bridges these two worlds. The app layer wires everything together.

---

### Unnecessary Complexity Found

#### 1. `_listEquals` defined three times — no shared utility

- `packages/loopy_engine/lib/src/engine_snapshot.dart` lines 553–558: file-private `bool _listEquals<T>(List<T> a, List<T> b)`
- `packages/loopy_engine/lib/src/track_effect.dart` lines 227–232: class-private `static bool _listEquals(List<double> a, List<double> b)` on `TrackEffect`
- `packages/session_repository/lib/src/models/session.dart` lines 150–155: file-private `bool _listEquals(List<SessionTrack> a, List<SessionTrack> b)`

All three implement the identical element-wise comparison. Flutter's `foundation.dart` already ships `listEquals` — the Dart SDK ships `const ListEquality().equals`. The custom implementations exist because neither `loopy_engine` nor `session_repository` currently imports `flutter/foundation.dart`, and the authors did not reach for `package:collection`. Each copy is four lines of logic that could be replaced by a single `listEquals(a, b)` call from `package:collection` (already a transitive dependency via `equatable`).

**Suggested simplification**: add `package:collection` as an explicit dependency in both packages and replace all three private implementations with `ListEquality().equals` or the top-level `listEquals` from `package:collection/collection.dart`.

#### 2. `_resolveAsioDriver` duplicated verbatim in two files

- `lib/app/audio_bootstrap.dart` lines 241–244: free function `String _resolveAsioDriver(String saved, List<AudioDevice> drivers)`
- `lib/audio_setup/cubit/audio_setup_cubit.dart` lines 454–457: private method `String _resolveAsioDriver(String saved, List<AudioDevice> drivers)` on `AudioSetupCubit`

The bootstrap file itself acknowledges the duplication in a comment ("Mirrors `AudioSetupCubit._resolveAsioDriver`"). The bodies are character-for-character identical. Any future change to the fallback logic must be applied in two places. The function is four lines and belongs in one location — `audio_bootstrap.dart` is the most appropriate since it is already the declared "single source of OS rule" for ASIO availability.

**Suggested simplification**: promote the function from `audio_bootstrap.dart` to a package-internal export (or keep it in `audio_bootstrap.dart` and have `AudioSetupCubit` call it), removing the copy from the cubit.

#### 3. Back-compat single-track accessors on `EngineSnapshot` — dead production code

`packages/loopy_engine/lib/src/engine_snapshot.dart` lines 470–489 define seven getters:
`trackState`, `trackVolume`, `trackMuted`, `trackLengthFrames`, `trackUndoDepth`, `trackRms`, `trackPeak`.

A codebase-wide grep confirms these are only referenced in `packages/loopy_engine/test/engine_snapshot_test.dart`. No production file consumes them. They are labelled "back-compat single-track accessor" in every doc-comment, but the single-track era is over and the tests that kept them alive can be updated to use `tracks.first.*` directly.

**Suggested simplification**: remove all seven getters and update `engine_snapshot_test.dart` to reference `snapshot.tracks.first.*` instead. Estimated removal: ~20 lines (getters + private `_track0` helper + test assertions).

#### 4. `Track` carries lane-0 scalar mirrors alongside `lanes: List<Lane>`

`packages/looper_repository/lib/src/models/track.dart` lines 37–73: `volume`, `muted`, `inputMask`, `outputMask`, `rms`, `peak` are scalar fields that mirror lane 0. The class doc-comment says "mirror lane 0 so existing single-lane callers keep working". The `lanes` list exists in parallel, making the full lane-0 state available twice.

This is an intentional migration shim, but it adds surface area to every `Track` construction site and makes `props` (the Equatable list) 14 entries instead of 8. Any caller that still uses the scalar fields is a potential source of divergence if lane-0 values ever disagree between the mirror and `lanes.first`.

**Suggested simplification**: audit which callers actually use the scalar mirrors. If the channel strip and routing graph are the only ones, give them a `Lane get lane0 => lanes.isNotEmpty ? lanes.first : const Lane()` computed property and remove the six redundant constructor parameters. This collapses to a single truth source and shrinks the `props` list.

#### 5. `EngineStatus` manually replicates `EngineSnapshot` fields — brittle projection layer

`packages/looper_repository/lib/src/models/engine_status.dart` defines 13 fields that are a manual projection of `EngineSnapshot`. The `LooperRepository` projection code must copy each new snapshot field into `EngineStatus` explicitly. The computed getter `fxAddedLatencyMs` is duplicated between `EngineSnapshot` (line ~448) and `EngineStatus` (lines 75–76).

The projection creates two parallel classes where one would do. Because `EngineSnapshot` is in the `loopy_engine` package and `EngineStatus` is in `looper_repository`, the separation does prevent the app layer from depending on `loopy_engine` directly — a valid package-boundary argument. However, the `fxAddedLatencyMs` duplication is a pure YAGNI violation: `EngineStatus` could store `fxAddedLatencyFrames` and `sampleRate` and expose the same getter, as it already does, without duplicating the formula.

**Suggested simplification**: the structural separation is justified. However, `fxAddedLatencyMs` is defined twice with identical formulae. If one changes the other will not. Consider a shared helper or document the invariant explicitly.

#### 6. `LooperRepository.withNativeEngine()` factory — unused in production

`packages/looper_repository/lib/src/looper_repository.dart` line 42–43:

```dart
factory LooperRepository.withNativeEngine() =>
    LooperRepository(engine: NativeAudioEngine());
```

A grep of the entire codebase (excluding `docs/`) finds no call site for this factory in production code. `lib/app/run_loopy.dart` and the flavors construct `LooperRepository(engine: NativeAudioEngine())` directly or use the primary constructor. The factory exists only in planning documents (`docs/PROGRESS.md`, `docs/plan/`) as a future API goal.

**Suggested simplification**: remove the factory (5 lines). Callers that need it can use the primary constructor; the factory adds no abstraction that the constructor does not already provide. If it is intended as a convenience for future app-layer isolation, document that intent instead of shipping dead code.

#### 7. `openLoopyEngineLibrary()` in `midi_client` duplicates `_openLibrary()` in `loopy_engine`

- `packages/midi_client/lib/src/native_library.dart`: `openLoopyEngineLibrary()` — public top-level function
- `packages/loopy_engine/lib/src/native_audio_engine.dart`: `_openLibrary()` — private static method on `NativeAudioEngine`

Both functions perform the same platform dispatch: `DynamicLibrary.process()` on Apple, `.open('loopy_engine.dll')` on Windows, `.open('libloopy_engine.so')` elsewhere. The `midi_client` package needed its own copy because it cannot depend on `loopy_engine` (circular dependency). This is a genuine structural constraint, not a gratuitous copy.

**Suggested simplification**: extract the platform dispatch into a new micro-package (`loopy_engine_loader` or similar) that both `loopy_engine` and `midi_client` can depend on. This is non-trivial to do without creating a new package; the current duplication is low-risk (2 functions, 6 lines each) but the comment in `native_library.dart` already documents the intent. Acceptable to leave as-is for now — flag for the next package restructure.

---

### Code to Remove

| Location | Description | Estimated LOC |
|---|---|---|
| `packages/loopy_engine/lib/src/engine_snapshot.dart:467–489` | 7 back-compat single-track getters + `_track0` helper | ~25 |
| `packages/loopy_engine/test/engine_snapshot_test.dart` | Test assertions using the removed accessors (update, not removal) | ~15 updated |
| `packages/loopy_engine/lib/src/engine_snapshot.dart:553–558` | Private `_listEquals` (replace with `package:collection`) | 6 |
| `packages/loopy_engine/lib/src/track_effect.dart:227–232` | Private `static _listEquals` on `TrackEffect` | 6 |
| `packages/session_repository/lib/src/models/session.dart:150–155` | Private `_listEquals` in session model | 6 |
| `packages/looper_repository/lib/src/looper_repository.dart:39–43` | `withNativeEngine()` factory — no production callers | 5 |
| `lib/audio_setup/cubit/audio_setup_cubit.dart:454–457` | Duplicate `_resolveAsioDriver` (keep one in `audio_bootstrap.dart`) | 4 |

**Total estimated removals**: ~52 lines of dead/duplicate Dart code.

---

### Simplification Recommendations

#### 1. Consolidate `_listEquals` — replace with `package:collection`

- **Current**: three private implementations of element-wise list equality scattered across `engine_snapshot.dart`, `track_effect.dart`, and `session.dart`.
- **Proposed**: add `package:collection` to `loopy_engine` and `session_repository` pubspecs; replace all three usages with `const ListEquality().equals(a, b)` or the top-level `listEquals`.
- **Impact**: -18 LOC, eliminates a class of future divergence bugs.

#### 2. Remove back-compat `EngineSnapshot` single-track accessors

- **Current**: 7 getters + 1 private helper compute track-0 values from `tracks.first`; only used in one test file.
- **Proposed**: delete the accessors and update the single test file to use `snapshot.tracks.first.fieldName`.
- **Impact**: -25 LOC production, test file becomes clearer about what it is actually testing.

#### 3. Deduplicate `_resolveAsioDriver`

- **Current**: identical 4-line function defined privately in `audio_bootstrap.dart` and as a private method in `AudioSetupCubit`; the comment in `audio_bootstrap.dart` acknowledges the duplication.
- **Proposed**: keep one canonical copy in `audio_bootstrap.dart` (already marked as the "single source of OS rules"), have `AudioSetupCubit` import and call it.
- **Impact**: -4 LOC, eliminates risk of the two implementations diverging.

#### 4. Remove `LooperRepository.withNativeEngine()` factory

- **Current**: a named factory constructor that wraps `LooperRepository(engine: NativeAudioEngine())`, present only in planning documents as a future convenience API, never called in production.
- **Proposed**: delete the factory. Production callers already pass `NativeAudioEngine()` to the primary constructor directly.
- **Impact**: -5 LOC, no production change.

#### 5. Audit and collapse `Track` lane-0 scalar mirrors

- **Current**: `Track` carries `volume`, `muted`, `inputMask`, `outputMask`, `rms`, `peak` as direct fields alongside `lanes: List<Lane>`, doubling track-0 state.
- **Proposed**: replace scalar fields with computed getters (`double get volume => lanes.firstOrNull?.volume ?? 1.0`) so there is one truth source, or document an explicit plan and timeline for when the mirrors will be removed.
- **Impact**: -6 constructor parameters, -6 entries in `props`, eliminates possible divergence between mirrors and `lanes.first`.

---

### YAGNI Violations

#### `LooperRepository.withNativeEngine()` factory
No production caller exists. The factory was written for a future isolation pattern described in planning documents. Ship the abstraction when you need it.

#### Back-compat `EngineSnapshot` single-track accessors
The single-track era is over; multi-track is the current reality. The accessors exist "in case" old callers need them, but no production caller does. Every retained dead accessor is a surface the reader must understand before discarding.

#### `Track` lane-0 scalar mirrors
Six fields exist to support callers that have not yet migrated to `lanes[0].*`. If those callers have been migrated, the mirrors are YAGNI. If they have not, a migration deadline should be set and the comment updated to reflect it.

---

### Final Assessment

**Total potential LOC reduction**: ~52 lines Dart (across packages and app layer). The C engine, CocoaPods/SPM forwarders, generated FFI bindings, and the BLoC event/state hierarchies are all justified by their requirements and have no meaningful simplification opportunity.

**Complexity score**: Low — the codebase is well-structured and the FFI boundary is clean. The issues found are isolated duplication and migration residue rather than architectural problems.

**Recommended action**: Proceed with simplifications — the changes are mechanical and low-risk. Items 1–4 in the recommendations above can be done independently in any order. Item 5 (lane-0 mirrors) requires a brief audit of callers before acting.
