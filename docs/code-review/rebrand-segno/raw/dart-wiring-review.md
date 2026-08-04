# Dart / Package Wiring Review — Loopy → Segno Rebrand

**Scope**: Broken Dart/package wiring after the Loopy→Segno rename  
**Date**: 2026-08-04  
**Workspace**: `/Users/Tomas/Documents/Work/opensource/loopy`  
**Verdict**: PASS — no broken Dart/package wiring found  

---

## Checklist

### 1. Root `pubspec` name is `segno`; path deps point at `packages/segno_engine`

**PASS**

Evidence:

- Root `pubspec.yaml` line 1: `name: segno`
- Root `pubspec.yaml` (dev_dependencies):

```yaml
segno_engine:
  path: packages/segno_engine
```

- Root `pubspec.lock` resolves `segno_engine` → `path: "packages/segno_engine"`
- Root `.dart_tool/package_config.json`: `"name": "segno"` with `"rootUri": "../"`; `"name": "segno_engine"` with `"rootUri": "../packages/segno_engine"`

---

### 2. All `package:*` imports resolve (no `package:loopy` or `package:loopy_engine`)

**PASS**

Evidence:

- Ripgrep over `*.dart` / `*.yaml` / `*.lock` / `*.json` in the live tree: **zero** matches for `package:loopy`, `package:loopy_engine`, `loopy_engine`, or `name: loopy`
- App/test imports use `package:segno/...` and `package:segno_engine/...`
- Entrypoints import `package:segno/app/app.dart` or `package:segno/app/run_segno.dart`
- `dart analyze` (repo root): **No issues found!** (exit 0) — confirms import graph resolves

---

### 3. Every `packages/*/pubspec.yaml` that references the engine uses `segno_engine` path

**PASS**

Packages with a direct engine dependency (all use `segno_engine` + `path: ../segno_engine`):

| Package | Dependency |
|---------|------------|
| `packages/segno_engine` | `name: segno_engine` |
| `packages/looper_repository` | `segno_engine: path: ../segno_engine` |
| `packages/midi_client` | `segno_engine: path: ../segno_engine` |
| `packages/session_repository` | `segno_engine: path: ../segno_engine` |
| `packages/performance_repository` | `segno_engine: path: ../segno_engine` |
| root app (`pubspec.yaml`) | `segno_engine: path: packages/segno_engine` |

Notes:

- `packages/daw_export/pubspec.yaml` mentions `segno_engine` only in a comment (explicitly does **not** depend on it) — intentional own-input-model rule.
- No `packages/loopy_engine/` directory exists in the live package tree.
- Transitive consumers (`midi_device_repository`, `pedal_repository`) resolve `segno_engine` via their dependency chain; their `.dart_tool/package_config.json` entries point at `../../segno_engine`.

---

### 4. `lib/main_*.dart` call `runSegno`; `run_segno.dart` / `segno_navigator.dart` exist

**PASS**

Evidence:

| File | Status |
|------|--------|
| `lib/main_development.dart` | `runSegno(args)` |
| `lib/main_production.dart` | `runSegno(args)` |
| `lib/main_staging.dart` | `runSegno(args)` |
| `lib/main_mock.dart` | `await runSegno(...)` |
| `lib/app/run_segno.dart` | exists; defines `Future<void> runSegno(...)` |
| `lib/app/segno_navigator.dart` | exists; exports `segnoNavigatorKey`, `openSegnoSettings`, etc. |
| `lib/app/app.dart` | `export 'run_segno.dart';` |

Stale paths absent: `lib/app/run_loopy.dart`, `lib/app/loopy_navigator.dart` do not exist.

---

### 5. ffigen output path and header paths match `segno_engine_api.h`

**PASS**

Evidence — `packages/segno_engine/ffigen.yaml`:

```yaml
name: SegnoEngineBindings
output: 'lib/src/generated/segno_engine_bindings.dart'
headers:
  entry-points:
    - 'src/core/segno_engine_api.h'
  include-directives:
    - 'src/core/segno_engine_api.h'
```

- Header present: `packages/segno_engine/src/core/segno_engine_api.h` (opens with `segno_engine_api.h — the C ABI exposed to Dart via FFI`)
- Generated bindings present: `packages/segno_engine/lib/src/generated/segno_engine_bindings.dart` (`class SegnoEngineBindings`)
- macOS SPM forwarder `macos/.../include/segno_engine_api.h` `#include`s `../../../../../src/core/segno_engine_api.h` (same renamed header; not an ffigen entry point)

No `loopy_engine_api.h` references in ffigen config or generated bindings.

---

### 6. `.dart_tool/package_config.json` has no `loopy_engine` entries across packages

**PASS** (live package graph)

Scanned:

- Root `.dart_tool/package_config.json`
- All `packages/*/.dart_tool/package_config.json` (19 package configs)

Results:

- **Zero** `loopy_engine` or `"name": "loopy"` entries
- Engine entries are `"name": "segno_engine"` with `rootUri` → `../packages/segno_engine` (root) or `../../segno_engine` (packages)
- Root package entry is `"name": "segno"`

Out of scope for this checklist: orphaned agent worktrees under `.claude/worktrees/*` still contain historical `packages/loopy_engine/.dart_tool/package_config.json` files from prior checkouts. They are not part of the live `packages/` tree and do not affect resolution for the working tree under review.

---

### 7. `dart analyze` (repo root) must be clean

**PASS**

Command:

```bash
dart analyze
```

Output:

```
Analyzing loopy...
No issues found!
```

Exit code: `0`.

---

## Findings

_No findings._ All seven wiring checklist items pass with evidence above.

| Severity | Count |
|----------|------:|
| Critical | 0 |
| Important | 0 |
| Suggestion | 0 |

---

## Summary table

| # | Check | Result |
|---|--------|--------|
| 1 | `pubspec` name `segno` + `segno_engine` path | PASS |
| 2 | No `package:loopy` / `package:loopy_engine` | PASS |
| 3 | Engine path deps → `segno_engine` | PASS |
| 4 | `runSegno` + navigator files | PASS |
| 5 | ffigen ↔ `segno_engine_api.h` | PASS |
| 6 | package_config free of `loopy_engine` | PASS |
| 7 | `dart analyze` clean | PASS |
