---
date: 2026-07-13
topic: windows-asio-doc-path-fix
---

# Fix stale file-location links in docs/WINDOWS_ASIO.md

## What We're Building

`docs/WINDOWS_ASIO.md`'s "Where the code lives" section (lines ~121-153) links
to flat `packages/loopy_engine/src/*.{c,cpp,h}` paths that no longer exist
after an engine `src/` reorganization into subdirectories
(`core/`, `platform/`, `asio/`, `test/`). Every link in that section 404s
against the current repo tree except the one pointing at
`src/test/test_engine_core.c`, which is already correct.

This is a pure path-correction pass over one section of one doc: update each
Markdown link target to the file's current location, without changing the
section's prose, structure, or any other part of the document.

## Why This Approach

The alternative (rewriting the whole doc, or restructuring "Where the code
lives" into a different shape) is unnecessary — the prose accurately describes
what each piece does; only the paths are stale. Minimal, targeted link fixes
keep the diff reviewable and avoid touching content unrelated to the one
verified issue this task is scoped to.

Every path below was independently re-verified against the current worktree
tree with `find` and `grep` (not just trusted from the issue report), since
the issue itself warned that files may have moved again since it was written:

```
packages/loopy_engine/src/core/engine_convert.c
packages/loopy_engine/src/core/engine.c
packages/loopy_engine/src/core/engine_devices.c
packages/loopy_engine/src/test/test_engine_core.c
packages/loopy_engine/src/platform/engine_windows.c
packages/loopy_engine/src/asio/win_asio_device.{cpp,h}
packages/loopy_engine/src/asio/win_asio_labels.{cpp,h}
```

One detail beyond what the issue report described: the report says
`le_select_backend` / `le_engine_start` are both still in `engine.c`. Grep
shows this is only half true now — `le_engine_start` is in `engine.c`, but
`le_select_backend` itself has *also* moved to `engine_devices.c`, alongside
`le_excluded_mask_from_names` / `le_label_is_loopback`. This is confirmed by
an explicit comment left in `engine.c` at the old call site:

> `/* Loopback detection, device enumeration / id resolution, and backend
> selection (le_select_backend + the ASIO-driver enumeration stub) moved to
> engine_devices.c (S1). The ASIO bridge math (deinterleave / interleave /
> pick_buffer) lives in engine_convert.c. */`

So the "Backend selection" bullet needs `le_select_backend` and
`le_engine_start` split across two links (`engine_devices.c` and `engine.c`
respectively), not just a single swapped path.

## Key Decisions

- **Scope: only the "Where the code lives" section.** No other part of
  `docs/WINDOWS_ASIO.md` is touched — the rest of the doc has no stale paths
  per the issue report, and rewriting prose is out of scope for a docs-drift
  fix.
- **Leave the `test_engine_core.c` link alone.** It already points at
  `src/test/test_engine_core.c`, which is correct.
- **Path corrections, function-to-file mapping changes:**
  - `engine_windows.c` → `src/platform/engine_windows.c`
  - `win_asio_labels.cpp` / `.h` → `src/asio/win_asio_labels.cpp` / `.h`
  - `win_asio_device.cpp` / `.h` → `src/asio/win_asio_device.cpp` / `.h`
  - `le_excluded_mask_from_names` / `le_label_is_loopback` (label-probe mask
    core) → now defined in `src/core/engine_devices.c`, not `engine.c`
  - `le_select_backend` (backend selection) → now defined in
    `src/core/engine_devices.c`, not `engine.c`
  - `le_engine_start` (backend selection call site) → stays in
    `src/core/engine.c` (bare `engine.c` path becomes `src/core/engine.c`)
  - `le_deinterleave_in` / `le_interleave_out` / `le_asio_pick_buffer` (bridge
    math) → now defined in `src/core/engine_convert.c`, not `engine.c`
- **Keep both prose bullets structurally intact** ("Label probe" section and
  "Duplex backend (Part 2)" section) — only the bracketed link targets and,
  where a function moved to a different file than its neighboring function,
  the surrounding sentence's file reference change. No new bullets, no
  reordering.

## Open Questions

None outstanding — every referenced symbol's current location was verified
directly against the working tree (`grep -n` on each candidate file) before
writing this doc, including the `le_select_backend` split that the original
issue report did not call out.
