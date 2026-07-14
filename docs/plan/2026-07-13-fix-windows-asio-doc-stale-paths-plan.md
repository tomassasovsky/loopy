---
title: Fix stale file-location links in docs/WINDOWS_ASIO.md
type: fix
date: 2026-07-13
---

## Fix stale file-location links in docs/WINDOWS_ASIO.md - Minimal

`docs/WINDOWS_ASIO.md`'s "Where the code lives" section (~line 121-153) links
to flat `packages/loopy_engine/src/*.{c,cpp,h}` paths that no longer exist
after the engine's `src/` reorg into `core/`, `platform/`, `asio/`, `test/`
subdirectories. Every link in that section currently 404s except the one
pointing at `src/test/test_engine_core.c`. Update each stale link to its
current, verified location. Pure path correction — no prose/structure
rewrite, no changes outside this one section.

## Success Criteria

```success-criteria
GOAL: Every Markdown link in docs/WINDOWS_ASIO.md's "Where the code lives"
section resolves to a file that exists in the current repo tree, and each
link's surrounding prose still names the correct function(s) for that file.

SUCCESS CRITERIA:
- Every relative link target in the "Where the code lives" section (from the
  "**Label probe**" heading through the end of the "**Duplex backend (Part
  2)**" bullet list) points at a file that exists on disk | verify: bash -c '
  cd docs && awk "/^## Where the code lives/,0" WINDOWS_ASIO.md |
  grep -oE "\]\(\.\./[^)]+\)" | sed -E "s/^\]\((.*)\)$/\1/" | sort -u |
  while read -r p; do [ -f "$p" ] || { echo "MISSING: $p"; exit 1; }; done'
- The doc no longer references any bare `src/engine.c`, `src/engine_windows.c`,
  `src/win_asio_labels.*`, or `src/win_asio_device.*` path (the pre-reorg flat
  paths) | verify: bash -c '! grep -nE "src/(engine\.c|engine_windows\.c|win_asio_(labels|device)\.(cpp|h))\)" docs/WINDOWS_ASIO.md'
- `le_excluded_mask_from_names` / `le_label_is_loopback` are attributed to
  `engine_devices.c`, not `engine.c` | verify: bash -c 'grep -A2 "le_excluded_mask_from_names" docs/WINDOWS_ASIO.md | grep -q "engine_devices.c"'
- `le_select_backend` is attributed to `engine_devices.c` (not `engine.c`),
  while `le_engine_start` stays attributed to `engine.c` | verify: bash -c '
  grep -B1 -A1 "le_select_backend" docs/WINDOWS_ASIO.md | grep -q "engine_devices.c" &&
  grep -B1 -A1 "le_engine_start" docs/WINDOWS_ASIO.md | grep -q "\](\.\./packages/loopy_engine/src/core/engine.c)"'
- `le_deinterleave_in` / `le_interleave_out` / `le_asio_pick_buffer` are
  attributed to `engine_convert.c` | verify: bash -c 'grep -B2 "le_asio_pick_buffer" docs/WINDOWS_ASIO.md | grep -q "engine_convert.c"'
- The existing `test_engine_core.c` link(s) are unchanged and still point at
  `src/test/test_engine_core.c` | verify: bash -c 'grep -q "src/test/test_engine_core.c" docs/WINDOWS_ASIO.md'
- No other section of the doc, and no other file in the repo, is modified |
  verify: bash -c '[ "$(git -C . diff --name-only | tr -d "\n")" = "docs/WINDOWS_ASIO.md" ] || [ "$(git -C . diff --cached --name-only | tr -d "\n")" = "docs/WINDOWS_ASIO.md" ]'

NON-GOALS:
- Rewriting the doc's prose, tone, or structure beyond the link targets and
  their immediate function attribution
- Fixing any other issue found in the same review pass (other agents own
  those, in separate worktrees)
- Auditing or fixing links elsewhere in the repo's docs/ tree

VERIFICATION COMMAND: cd docs && awk "/^## Where the code lives/,0" WINDOWS_ASIO.md | grep -oE "\]\(\.\./[^)]+\)" | sed -E "s/^\]\((.*)\)$/\1/" | sort -u | while read -r p; do [ -f "$p" ] || { echo "MISSING: $p"; exit 1; }; done && cd .. && ! grep -nE "src/(engine\.c|engine_windows\.c|win_asio_(labels|device)\.(cpp|h))\)" docs/WINDOWS_ASIO.md && grep -A2 "le_excluded_mask_from_names" docs/WINDOWS_ASIO.md | grep -q "engine_devices.c" && grep -B1 -A1 "le_select_backend" docs/WINDOWS_ASIO.md | grep -q "engine_devices.c" && grep -B1 -A1 "le_engine_start" docs/WINDOWS_ASIO.md | grep -q "\](\.\./packages/loopy_engine/src/core/engine.c)" && grep -B2 "le_asio_pick_buffer" docs/WINDOWS_ASIO.md | grep -q "engine_convert.c" && grep -q "src/test/test_engine_core.c" docs/WINDOWS_ASIO.md
```

## Context

Verified current file locations (via `find`/`grep` against the working
tree — see `docs/brainstorm/2026-07-13-windows-asio-doc-path-fix-brainstorm-doc.md`
for the full trail):

| Symbol / file | Doc currently says | Actual current path |
|---|---|---|
| `le_platform_excluded_input_mask` dispatch | `src/engine_windows.c` | `src/platform/engine_windows.c` |
| ASIO label probe | `src/win_asio_labels.cpp` / `.h` | `src/asio/win_asio_labels.cpp` / `.h` |
| `le_excluded_mask_from_names` / `le_label_is_loopback` | `src/engine.c` | `src/core/engine_devices.c` |
| ASIO backend + driver enumeration | `src/win_asio_device.cpp` / `.h` | `src/asio/win_asio_device.cpp` / `.h` |
| `le_select_backend` | `src/engine.c` | `src/core/engine_devices.c` (moved here per an explicit comment left at the old call site in `engine.c`: "Loopback detection, device enumeration / id resolution, and backend selection (le_select_backend + the ASIO-driver enumeration stub) moved to engine_devices.c (S1)") |
| `le_engine_start` | `src/engine.c` | `src/core/engine.c` (unchanged function location, only the bare path needs `src/core/` prefix) |
| `le_deinterleave_in` / `le_interleave_out` / `le_asio_pick_buffer` | `src/engine.c` | `src/core/engine_convert.c` |
| `test_engine_core.c` | `src/test/test_engine_core.c` | unchanged, correct — leave alone |

Note: the original issue report said `le_select_backend` was still in
`engine.c` alongside `le_engine_start`. Re-verification found this is only
half true — `le_select_backend` itself now lives in `engine_devices.c`. The
plan corrects this more precisely than the original issue text.

## MVP

Edit only the "## Where the code lives" section of
`docs/WINDOWS_ASIO.md` (lines ~121-153). Two bullet groups, "Label probe" and
"Duplex backend (Part 2)":

**Label probe** — change:
```markdown
- Dispatch: `le_platform_excluded_input_mask` in
  [engine_windows.c](../packages/loopy_engine/src/engine_windows.c), under
  `#if defined(LOOPY_ENABLE_ASIO)`.
- ASIO probe: [win_asio_labels.cpp](../packages/loopy_engine/src/win_asio_labels.cpp)
  (+ [win_asio_labels.h](../packages/loopy_engine/src/win_asio_labels.h)).
- Portable, unit-tested mask core: `le_excluded_mask_from_names` /
  `le_label_is_loopback` in
  [engine.c](../packages/loopy_engine/src/engine.c) (tested in
  [test_engine_core.c](../packages/loopy_engine/src/test/test_engine_core.c)).
```
to:
```markdown
- Dispatch: `le_platform_excluded_input_mask` in
  [engine_windows.c](../packages/loopy_engine/src/platform/engine_windows.c), under
  `#if defined(LOOPY_ENABLE_ASIO)`.
- ASIO probe: [win_asio_labels.cpp](../packages/loopy_engine/src/asio/win_asio_labels.cpp)
  (+ [win_asio_labels.h](../packages/loopy_engine/src/asio/win_asio_labels.h)).
- Portable, unit-tested mask core: `le_excluded_mask_from_names` /
  `le_label_is_loopback` in
  [engine_devices.c](../packages/loopy_engine/src/core/engine_devices.c) (tested in
  [test_engine_core.c](../packages/loopy_engine/src/test/test_engine_core.c)).
```

**Duplex backend (Part 2)** — change:
```markdown
- ASIO backend + driver enumeration:
  [win_asio_device.cpp](../packages/loopy_engine/src/win_asio_device.cpp)
  (+ [win_asio_device.h](../packages/loopy_engine/src/win_asio_device.h)),
  exposing `le_asio_backend` and `le_enumerate_asio_drivers`.
- Backend selection: `le_select_backend` / `le_engine_start` in
  [engine.c](../packages/loopy_engine/src/engine.c). The default build links no
  ASIO symbol (the reference lives inside the `#if`); a non-ASIO build provides a
  stub `le_enumerate_asio_drivers` returning 0.
- Pure, unit-tested bridge math: `le_deinterleave_in` / `le_interleave_out` /
  `le_asio_pick_buffer` in [engine.c](../packages/loopy_engine/src/engine.c)
  (tested in [test_engine_core.c](../packages/loopy_engine/src/test/test_engine_core.c)).
```
to:
```markdown
- ASIO backend + driver enumeration:
  [win_asio_device.cpp](../packages/loopy_engine/src/asio/win_asio_device.cpp)
  (+ [win_asio_device.h](../packages/loopy_engine/src/asio/win_asio_device.h)),
  exposing `le_asio_backend` and `le_enumerate_asio_drivers`.
- Backend selection: `le_select_backend` in
  [engine_devices.c](../packages/loopy_engine/src/core/engine_devices.c), called from
  `le_engine_start` in
  [engine.c](../packages/loopy_engine/src/core/engine.c). The default build links no
  ASIO symbol (the reference lives inside the `#if`); a non-ASIO build provides a
  stub `le_enumerate_asio_drivers` returning 0.
- Pure, unit-tested bridge math: `le_deinterleave_in` / `le_interleave_out` /
  `le_asio_pick_buffer` in [engine_convert.c](../packages/loopy_engine/src/core/engine_convert.c)
  (tested in [test_engine_core.c](../packages/loopy_engine/src/test/test_engine_core.c)).
```

Everything else in the doc (title, license section, hardware-spike section,
building section, all prose above line 121) stays byte-for-byte identical.

## References

- Issue source: multi-agent code review finding re-verified at commit
  `f3f5b76` (origin/master HEAD)
- `docs/brainstorm/2026-07-13-windows-asio-doc-path-fix-brainstorm-doc.md`
- File: `docs/WINDOWS_ASIO.md`
