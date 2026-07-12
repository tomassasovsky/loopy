# feat: session multi-lane audio round-trip (manifest v3) — part 1/4

**Type:** enhancement (architecture) · **Detail:** Standard · **Date:** 2026-07-11

> Part 1 of the [session overdub-layer-fidelity umbrella](2026-07-11-feat-session-overdub-layer-fidelity-plan.md).

## Dependencies

None. This is the base of the stack; parts 2–4 build on the manifest v3 + DTO
shape it lands.

## Goal

Kill the lane-0-only limitation. After this PR, a multi-lane track saves and
reloads **every lane's current audio** and per-lane mix. Undo history is *not*
persisted yet (`undoDepth == 0` on reload — part 3 adds it), but the manifest and
DTO already carry the final layer-bearing shape so parts 2–3 are purely additive.

## Background (see umbrella for full engine detail)

- A track owns `lanes[LE_MAX_LANES]`; each lane owns its own mono `pool[a_live]`
  live buffer ([`engine_private.h:184`](packages/loopy_engine/src/core/engine_private.h#L184)).
- Export/import touch **lane 0 only** today
  ([`engine_session.c:22`](packages/loopy_engine/src/core/engine_session.c#L22),
  [`:54`](packages/loopy_engine/src/core/engine_session.c#L54);
  [`session_repository.dart:294`](packages/session_repository/lib/src/session_repository.dart#L294)).
- `Session.fromJson` version-gates via **structural presence**, not a version
  switch (`json['laneChains'] as List? ?? const []`,
  [`session.dart:233`](packages/session_repository/lib/src/models/session.dart#L233)).

## Tasks

### Engine (C)

- [ ] Add `le_engine_import_track_lane(channel, lane, pcm, frames)` — fills lane
      `lane`'s live slot of an EMPTY track (mirror the lane-0 body of
      [`le_engine_import_track`](packages/loopy_engine/src/core/engine_session.c#L54)),
      growing `lane_count` to cover the highest imported lane.
- [ ] Keep `le_engine_import_track` as a lane-0 convenience wrapper.
- [ ] C round-trip harness: import lanes 0..N, `exportTrackLane` each, assert PCM
      identity + `lane_count`.

### FFI / Dart — update **every** `AudioEngine` implementer (build-blocker)

`AudioEngine` is an `abstract interface class`
([audio_engine.dart:582](packages/loopy_engine/lib/src/audio_engine.dart#L582)); a
new method must be implemented in all of these in this PR or the monorepo won't
compile:

- [ ] `AudioEngine.importTrackLane` declaration + regenerate
      `loopy_engine_bindings.dart`.
- [ ] `native_audio_engine.dart`, `mock_audio_engine.dart`
- [ ] `packages/session_repository/test/helpers/fake_session_engine.dart`
      (mirror the existing `exportTrackLane` at
      [fake_session_engine.dart:91](packages/session_repository/test/helpers/fake_session_engine.dart#L91))
- [ ] `packages/looper_repository/test/helpers/fake_audio_engine.dart`,
      `test/helpers/fake_audio_engine.dart`,
      `packages/performance_repository/test/helpers/fake_performance_engine.dart`

### session_repository — models

- [ ] New `SessionLayer { file }` and `SessionLane { lane, volume, muted,
      outputMask, inputChannel, layers: List<SessionLayer>, undoCount, redoCount }`.
      **Equality/hash must match the module pattern**: `@immutable`, const ctor,
      `factory fromJson`, `toJson`, `operator==` using `_listEquals(layers, …)`
      ([session.dart:302](packages/session_repository/lib/src/models/session.dart#L302))
      and `hashCode` via `Object.hashAll(layers)`
      ([session.dart:292](packages/session_repository/lib/src/models/session.dart#L292)).
- [ ] Do **not** store `liveIndex` (derive `== undoCount`) and do **not** add a
      per-layer `lengthFrames` — every layer of a lane shares the track length
      (`dub_len` is latched at session start,
      [engine_private.h:273](packages/loopy_engine/src/core/engine_private.h#L273));
      keep the single `SessionTrack.lengthFrames`.
- [ ] `SessionTrack`: replace `stem` with `lanes: List<SessionLane>`; make the old
      `stem` optional in `fromJson`. Bump `Session.formatVersion = 3` and update
      its doc comment ([session.dart:243](packages/session_repository/lib/src/models/session.dart#L243)).
- [ ] Presence-keyed migration in `SessionTrack.fromJson`: when `lanes` is absent
      (v1/v2), synthesize one `SessionLane`(lane 0) with a single live
      `SessionLayer(stem)` and `undoCount == redoCount == 0`; map the old
      track-level `volume`/`muted` onto lane 0.

### session_repository — I/O (capture reshapes; keep the three call sites consistent)

- [ ] `_capture()`: iterate `0..laneCount`, `exportTrackLane` each; the
      `_Capture.stems` map becomes per-`(channel, lane)`. Skip non-playing/stopped
      tracks as today ([session_repository.dart:307](packages/session_repository/lib/src/session_repository.dart#L307)).
- [ ] `save()`: write one WAV per lane — `track{c}_lane{l}_L0.wav`; write manifest v3.
- [ ] `_mixdown()` **and** `exportStems()`: sum **all lanes'** live buffers at
      their gains (resolves umbrella R3 here, not deferred — capture's new shape
      forces all three to move together;
      [session_repository.dart:349](packages/session_repository/lib/src/session_repository.dart#L349),
      [:283](packages/session_repository/lib/src/session_repository.dart#L283)).
- [ ] `read()` + `SessionBundle` typedef
      ([session_repository.dart:16](packages/session_repository/lib/src/session_repository.dart#L16)):
      decode every lane's live WAV.

### looper_repository — final DTO shape now

- [ ] `SessionRigLane { lane, layers, volume, muted, outputMask, inputChannel }` —
      **carry `layers` from the start** so part 3 only *populates* more; part 1
      always emits one live layer. Replace `SessionRigTrack.pcm`
      ([session_rig.dart:18](packages/looper_repository/lib/src/models/session_rig.dart#L18))
      with `lanes: List<SessionRigLane>`. Keep the DTO equality-free by design.
- [ ] `applySession`: import each lane's live layer via `importTrackLane`, then
      `commitSession`; restore per-lane mix through the cached setters; drop the
      lane-0-only note ([looper_repository.dart:837](packages/looper_repository/lib/src/looper_repository.dart#L837)).

### App bridge

- [ ] `lib/session/session_mapping.dart` / `session_cubit.dart`: map manifest lanes
      ↔ rig lanes.

## Edge cases

- Empty session → no tracks, no master (unchanged ghost-grid guard,
  [session_repository.dart:338](packages/session_repository/lib/src/session_repository.dart#L338)).
- Undone-to-empty track → **skipped** (consistent with `_capture` today) — pinned,
  not deferred.
- Lane with `inputChannel == -1` but audio present → restore buffer, leave input
  unbound.
- Sample-rate mismatch on load → existing `SessionSampleRateMismatch` refusal
  covers all lanes (one rate per bundle).

## Acceptance criteria

- [ ] A multi-lane track saved and reloaded is byte-identical **per lane**.
- [ ] v1 and v2 bundles still load (as one live lane-0 layer) — with explicit v1
      **and** v2 load tests.
- [ ] `mixdown.wav` now reflects all lanes; `SessionSampleRateMismatch` still enforced.
- [ ] Mapping/bloc round-trip test updated (`test/session/session_fx_roundtrip_test.dart`,
      `test/session/cubit/session_cubit_test.dart`); all existing tests pass.
