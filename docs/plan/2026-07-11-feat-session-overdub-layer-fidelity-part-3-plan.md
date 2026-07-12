# feat: overdub-layer persistence — FFI + Dart wiring — part 3/4

**Type:** enhancement (architecture) · **Detail:** Extensive · **Date:** 2026-07-11

> Part 3 of the [session overdub-layer-fidelity umbrella](2026-07-11-feat-session-overdub-layer-fidelity-plan.md).

## Dependencies

- **Part 1** — manifest v3 + `SessionLane`/`SessionLayer`/`SessionRigLane` shapes
  (this PR only *populates* the already-final DTO — no reshape).
- **Part 2** — the native `export_layer` / `import_layer` / `finalize_layers`
  contract this PR wires to Dart.

## Goal

Persist and restore **all overdub layers + undo/redo stacks** through the Dart
stack, so a reloaded session reports the correct `undoDepth`/`redoDepth` and
`undo()`/`redo()` reproduce every take.

## Tasks

### FFI / Dart — update **every** `AudioEngine` implementer (build-blocker, R5)

- [ ] `AudioEngine` gains `exportLayer(channel, lane, ordinal)`,
      `importLayer(channel, lane, ordinal, pcm)`, `finalizeLayers(channel,
      undoCount, redoCount)`; regenerate `loopy_engine_bindings.dart`.
- [ ] Implement in `native_audio_engine.dart`, `mock_audio_engine.dart`, and keep
      all four test fakes in sync (`fake_session_engine`,
      `looper_repository/.../fake_audio_engine`, `test/helpers/fake_audio_engine`,
      `fake_performance_engine`).

### session_repository — per-layer file I/O

- [ ] `_capture()`: for each lane, read layer count from the **existing snapshot**
      (`track.undoDepth`/`track.redoDepth` — no new FFI) and `exportLayer` each
      ordinal; keep the `_awaitLayersSettled()` gate
      ([session_repository.dart:381](packages/session_repository/lib/src/session_repository.dart#L381))
      so nothing is captured mid-drain.
- [ ] `save()`: write `track{c}_lane{l}_L{n}.wav` per layer; populate
      `SessionLane.layers` + `undoCount`/`redoCount`.
- [ ] **Prune stale files (SH5):** the per-track file set is now variable (lanes ×
      layers shrink between saves). Write the bundle to a temp dir and swap, or
      delete orphaned `track*_lane*_L*.wav` not in the new manifest — otherwise
      `duplicateSession`'s recursive copy
      ([session_repository.dart:157](packages/session_repository/lib/src/session_repository.dart#L157))
      carries cruft.
- [ ] `read()`: decode every layer file into the bundle.

### looper_repository — full restore

- [ ] Populate `SessionRigLane.layers` (multiple) from the bundle.
- [ ] `applySession`: per lane, `importLayer` each ordinal → `finalizeLayers` →
      `commitSession`. Reloaded track reports correct `undoDepth`/`redoDepth`.

### App bridge

- [ ] `session_mapping.dart`: carry layers through manifest ↔ rig.

## Acceptance criteria

- [ ] A track with N overdub passes saved and reloaded is byte-identical **per
      layer**; `undoDepth`/`redoDepth` match the pre-save engine.
- [ ] After reload, `undo()`/`redo()` reproduce every take.
- [ ] Re-saving a session with fewer layers/lanes leaves **no orphaned WAVs**.
- [ ] Per-layer file-I/O unit test (`session_repository`) + layer-carrying mapping
      test (bloc) added; all existing tests pass.

## Stacked-PR note

Stacks on parts 1–2; do not `--delete-branch` on merge (part 4 depends). Merge
`master` in after each base merges.
