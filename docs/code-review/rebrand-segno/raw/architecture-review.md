# Architecture Review — Loopy → Segno rebrand

**Branch**: `rebrand/segno`  
**Scope**: Post-rename architecture validation only. Intentional product/package
renames are out of scope unless they broke layer boundaries, dependency
direction, or monorepo package structure.  
**Stack**: Flutter/Dart VGV layered monorepo (Presentation → Business Logic →
Repository → Data), as documented in `docs/PROGRESS.md` and VGV layered-
architecture standards.

## Mapping under review

| Before | After | Layer |
|--------|--------|--------|
| app package `loopy` | `segno` | Presentation + BLoC (`lib/`) |
| `packages/loopy_engine` | `packages/segno_engine` | Data (FFI plugin) |
| Feature vocab `looper` / `looper_repository` | unchanged (intentional) | Repository / feature |

---

## Architecture Review

### Layer Separation

- Violations found: **0** (rebrand-introduced)
- Clean files / boundaries checked:
  - `lib/**` production code does **not** import `package:segno_engine`
  - App bootstrap (`lib/app/run_segno.dart`) constructs the engine only via
    `createNativeAudioEngine()` from `looper_repository`, keeping the concrete
    engine type transitive (documented in-file)
  - Repository packages that previously depended on `loopy_engine` now depend
    on `segno_engine` with the same direction:
    - `looper_repository` → `segno_engine`
    - `session_repository` → `segno_engine`
    - `performance_repository` → `segno_engine`
    - `midi_client` → `segno_engine`
  - No package under `packages/` imports `package:segno/` (no upward dep on app)
  - Old `packages/loopy_engine` directory is gone (rename complete, no dual package)

**Pre-existing (not introduced by rebrand; out of scope):**

- Presentation/bootstrap uses `brightness_client` directly
  (`lib/app/run_segno.dart`, `lib/appliance/display_brightness_cubit.dart`,
  tray cubits) — no `brightness_repository`. Unchanged pattern vs pre-rename
  `run_loopy.dart`.
- Presentation imports `daw_export` for performance export UI
  (`lib/performance/cubit/performance_recorder_cubit.dart`,
  `export_device_chain_summary.dart`) — documented accepted shortcut in
  `docs/PROGRESS.md`.

### State Management Assessment

- Rebrand did not alter BLoC/Cubit ownership, provider wiring shape, or move
  business logic into views.
- Entrypoint rename `runLoopy` → `runSegno` / `LoopyNavigator` →
  `SegnoNavigator` preserves the same MultiRepositoryProvider bootstrap role.
- `LooperBloc` / feature cubits remain under `lib/<feature>/` and continue to
  depend on repository packages, not on `segno_engine` directly.
- Assessment: **Correct** relative to pre-rebrand architecture (no new SM
  violations from the rename).

### Dependency Direction

- Direction violations (rebrand-introduced): **0**
- Graph after rename (intended):

```
package:segno (app)
  → *_repository (+ routing_graph UI kit, daw_export [pre-existing])
      → *_client / segno_engine / wav_codec

package:segno  (production deps)
  does NOT depend on segno_engine

package:segno  (dev_dependencies)
  → segno_engine   # tests / integration only — correct
```

- Clean dependencies verified:
  - `segno_engine` depends only on `ffi` / `flutter` / `meta` (no repos, no app)
  - App production `pubspec.yaml` lists repositories; `segno_engine` is
    `dev_dependencies` only
  - No circular `segno` ↔ `segno_engine` or repo ↔ app cycles
  - Barrel boundary preserved: `looper_repository` re-exports a controlled
    subset of `package:segno_engine/segno_engine.dart` and owns
    `createNativeAudioEngine()`

**Pre-existing direction quirks (unchanged by rename; out of scope):**

- `midi_client` (data) → `controller_repository` (repo)
- `midi_device_repository` → `settings_repository` / `controller_repository`
  (inter-repository deps)
- `pedal_repository` → `midi_client` + `controller_repository`

### Package Structure

- **`segno` (root app)**: Complete — `pubspec.yaml` renamed, path deps intact,
  `lib/` + `test/` present, flavors still entry via `runSegno`.
- **`segno_engine`**: Complete — `pubspec.yaml`, `analysis_options.yaml`
  (very_good_analysis), `lib/` barrels (`segno_engine.dart`,
  `segno_engine_ffi.dart`), `test/`, native plugin dirs (`macos`/`linux`/
  `windows`), `ffigen.yaml`. Single responsibility (native audio FFI) preserved.
- All other `packages/*` retain `analysis_options.yaml` and `test/` directories.
- No grab-bag packages added by the rebrand; no new package that should have
  been folded into an existing one.
- Feature vocabulary package `looper_repository` correctly **not** renamed
  (product name ≠ feature domain).

### Verdict

**Architecture is clean.** The Loopy→Segno rename preserved VGV layer
boundaries and dependency direction for `package:segno` /
`package:segno_engine`. No presentation→data shortcuts were introduced by the
rename; monorepo package structure remains intact. No architecture fixes
required before merge on rebrand grounds.

---

## Checks performed

1. Compared root + package `pubspec.yaml` path dependencies before/after rename
2. Grepped `lib/` for `package:segno_engine` and other data-client imports
3. Grepped `packages/` for upward `package:segno/` imports
4. Confirmed `loopy_engine` path removed and no residual `package:loopy` /
   `package:loopy_engine` in Dart/YAML sources
5. Verified `looper_repository` barrel + `createNativeAudioEngine` seam
6. Verified every `packages/*` has lint config + tests
7. Cross-checked against `docs/PROGRESS.md` architecture map and rebrand plan
