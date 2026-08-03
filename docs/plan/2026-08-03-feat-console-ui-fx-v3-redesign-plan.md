---
title: "feat(console): UI redesign for the FX v3 four-stage system (rail drawer, racks, 7\" readout, Custom pedal mode)"
type: feat
date: 2026-08-03
issue: 442
---

## feat(console): console UI redesign — Extensive

> Source brainstorm: [docs/brainstorm/2026-08-02-console-ui-fx-v3-redesign-brainstorm-doc.md](../brainstorm/2026-08-02-console-ui-fx-v3-redesign-brainstorm-doc.md)
> Issue: [#442](https://github.com/tomassasovsky/loopy/issues/442) (epic)
> Autonomy: `autonomy:plan-gate` — direction approved in-session (drawer rail, rack scope, inheritance semantics, FX-mode default, `auto` semantics); this plan is the review artifact.
> Build convention: split each part below into its own `-part-N-plan.md` before `/build`ing it; `/build` targets a part, never this index. Once a part file exists it is canonical — the index's bullets are source material to lift, not a second copy to maintain. Each part gets its own child issue with `stage:*`/`autonomy:*` labels; every part checks the cspell dictionary + semantic PR title before opening its PR, and every part that touches UI regenerates the author-only screenshot goldens under `test/screenshots/`.

> **Session setup + live status:** [execution guide](2026-08-03-feat-console-ui-fx-v3-redesign-execution-guide.md)
> — per-part model/effort/autonomy and the status table every session updates.
>
> | Part | Scope | Depends on |
> |------|-------|------------|
> | 1 | drawer navigation rail (shell only, no feature change) | — |
> | 2 | 7″ permanent performance readout | — |
> | 3 | rack domain model + global library + persistence/migration | — |
> | 4 | FX panel in the drawer: stage tabs + rack UI | 1, 3 |
> | 5 | Routing panel in the drawer: stage tabs | 1, 4 |
> | 6 | three-state live-monitor control (off / auto / on) | 3, 4 |
> | 7 | Pedal panel as a rail destination (closes #440) | 1 |
> | 8 | Custom pedal mode + protocol v4 | 7 |
> | 9 | hardening: goldens, appliance soak, docs | all |
>
> Parts 1, 2, 3 and 7 have no in-epic dependencies and can run in parallel;
> 7 depends on 1 only for its final mount point and can be built against the
> existing tray if 1 has not landed.

## Overview

Make the FX v3 feature set discoverable and configurable on the floor console
without a manual. FX v3 shipped a complete four-stage engine (Input → Loop →
Track → Master), pedal FX mode, remappable bindings and expression — and on
real hardware it proved unusable: the assignment surface is three levels deep
in Settings, the input-vs-track distinction is invisible, and there is no way
to audition a track's FX while recording into it.

Five moves:

- **The drawer grows a navigation rail.** Config stops pushing you to
  full-screen routes and becomes an overlay you drop out of with one gesture.
  The 16″ keeps a clean stage view — the reason the drawer exists — while
  finally being somewhere config can *live* rather than merely launch from.
- **The 7″ becomes a permanent performance readout** (track states, loop
  position, tempo, what is armed). This is what makes a near-fullscreen drawer
  acceptable: you configure mid-set without losing sight of the loop. It is
  the one design question the Sheeran material cannot answer, since they have
  one screen.
- **Effects become named, assignable racks** — a global library of saveable,
  loadable, transferable objects — replacing anonymous per-stage chains as the
  central object of the FX surface. This also makes the existing record-time
  chain inheritance visible for the first time.
- **The four stages become tabs inside the FX and Routing panels**, not
  top-level navigation. Signal order is visible furniture exactly where it is
  being manipulated, without forcing the model onto the performance view.
- **The pedal keeps REC / MUTE / FX and gains one Custom mode** where every
  switch is a blank slot assigned from a function list.

## Problem Statement

1. **The pedal-assignment surface is unreachable.** `PedalAssignmentPage`
   (`lib/pedal/view/pedal_assignment_page.dart:41`) is reached only from
   `pedal_settings_section.dart:88`, which is mounted inside
   `audio_settings_section.dart:112` — Settings → Audio → Pedal → button, three
   levels deep, on a device with no keyboard. This is #440.
2. **The drawer only launches you elsewhere.** `SettingsTrayDestination`
   (`lib/looper/cubit/settings_tray_state.dart:5`) has exactly three values —
   `home`, `wifi`, `bluetooth`. WiFi and Bluetooth expand in-tray; Settings and
   Signal *push full-screen routes* (`settings_tray.dart:460`, `:476`), which
   is precisely the "config blinds the performer" failure. There is no FX tile
   and no pedal tile at all.
3. **Chains are anonymous and non-transferable.** Every chain is addressed
   positionally by `FxAddress` and stored as an opaque envelope under a
   stage-derived key across three sinks —
   `settings_repository.dart:896` (`track_fx_chain.$channel`), `:897`
   (`master_fx_chain`), `:612`/`:620` (monitor input), the session manifest
   (`session.dart:517-520`), and `PerformanceChains`. There is no chain name,
   no library, no catalog. A sound must be rebuilt from scratch every time.
   Grep for `preset` finds only *track length* presets.
4. **Inheritance is invisible.** `FxChainMeta.inheritedFrom`
   (`fx_chain_envelope.dart:9`) already records that a take copied the input
   chain by value at record time, but nothing names the thing it came from, so
   the UI cannot say it.
5. **You cannot audition a track's FX while recording into it.** There is no
   monitor control at the chain-placement granularity — only the global
   monitor path.
6. **The 7″ renders a waveform and nothing else.**
   `WaveformWindowApp` (`lib/visualizer/waveform_window.dart:183`) mounts a
   single full-screen `WaveformView` with no localization ancestor and no
   transport state. It cannot stand in for the stage while the drawer is open.
7. **The tuner is a stub.** `settings_tray.dart:549` opens
   `showComingSoonStub`. No pitch-detection code exists anywhere.

## Key Decisions

Direction resolved in-session on 2026-08-03; these are pinned — parts consume
them, they do not revisit them.

- **D1 — Rack scope: one global library, sessions hold references.** Racks
  live in an app-level library persisted outside the session; a session stores
  a reference plus any per-placement overrides. Transferability between
  sessions is the entire reason to name a rack, and per-session-only storage
  drops it. Migration gets one obvious target.
- **D2 — An inherited rack is a frozen copy that shows its origin name.**
  Matches today's by-value semantics exactly — no engine change, no manifest
  semantics change. A take renders `from <rack name>` as provenance; editing
  it detaches into an unnamed local chain. A recorded take's sound stays
  reproducible, and a rack edit can never retroactively change takes already
  on disk. `FxChainMeta.inheritedFrom` is widened to carry the rack id **and**
  the display name captured at record time, so provenance survives the rack
  being renamed or deleted.
- **D3 — Anonymous chains migrate as unnamed local chains.** Follows from D1 +
  D2: existing sessions keep working untouched, nothing is auto-named, and a
  chain enters the library only through an explicit "save as rack". No
  speculative naming of chains the user never asked to name.
- **D4 — The zero-config FX-mode pedal layout keeps binding Track chains.**
  Unchanged from FX v3 part 5b. The brainstorm's open question resolves as *no
  change*: a switch whose meaning depends on rig state is exactly what you do
  not want under a foot mid-set, and Custom mode (part 8) covers the guitarist
  who wants the input pedalboard under the switches.
- **D5 — `auto` follows armed, not selected.** The three-state live-monitor
  control is off / auto / on per rack placement; `auto` means *heard while the
  track is armed for record*. Strictly tied to arming, so a stopped session
  never makes unexpected noise. Auditioning a non-armed track's FX is the
  explicit `on` state — one deliberate tap, not a side effect of selection.
  Still **provisional as to location**: the state lives on the rack placement
  regardless, so moving the control onto the Routing panel later is a view
  change with no migration, no protocol change and no engine work.
- **D6 — The tuner gets a reserved rail slot in this epic, not an
  implementation.** It stays the `showComingSoonStub` target, moved from a
  tile to a rail destination. A real tuner needs pitch-detection DSP in the
  native engine, which is a different kind of work from a UI redesign and does
  not belong in this epic's critical path. Placement answer: **rail
  destination, not a full-screen takeover** — the drawer is already
  near-fullscreen, so Sheeran's takeover buys nothing loopy does not already
  have; the input-mute side effect is communicated in the panel instead.
  Tracked separately (see Follow-ups).
- **D7 — The 7″ readout stays rigid while the drawer is open.** No per-panel
  variation in v1. The performance readout's whole job is to be the thing that
  does *not* change when you go configure something; making it context-
  sensitive re-introduces the failure it exists to prevent. Provisional — the
  pedal panel is the one plausible exception, and it is cheap to add later
  because the readout is already a pushed-state renderer.

## Part breakdown

### Part 1 — Drawer navigation rail (shell only)

Turn `SettingsTray` from a tile grid that pushes routes into a rail-driven
panel host. No feature changes: every destination that exists today must still
be reachable and behave identically.

- Widen `SettingsTrayDestination` (`settings_tray_state.dart:5`) from
  `home | wifi | bluetooth` to the full destination set: `home`, `fx`,
  `routing`, `pedal`, `tuner`, `wifi`, `bluetooth`, `settings`. Destinations
  that later parts fill land as placeholders now, so no part after this one
  touches the enum or the rail.
- Add the rail widget and the panel host inside the tray; keep `_TrayHome`
  (`settings_tray.dart:430`) as the `home` destination so the tile grid does
  not disappear from under the user in one step.
- The tray grows to near-fullscreen when a rail destination other than `home`
  is showing. Drag-to-dismiss stays the single exit gesture.
- `isNavigating` (`settings_tray_state.dart`) guarded route pushes stay for
  `settings` and `signal` in this part; parts 4/5/7 convert them.
- `settings_tray.dart` is already 833 lines. Extract the rail, the panel host
  and each panel into their own files — widget classes, not `_build` methods
  [VGV].
- **Risk:** the tray is drag-driven off a single `dragProgress` field. A rail
  changes what "open" means (height depends on destination). Keep
  `dragProgress` as the only open/closed source of truth; destination must not
  become a second, desyncable open bit.

### Part 2 — 7″ permanent performance readout

Replace the waveform-only sub-window content with a performance readout.

- `WaveformWindowApp` (`waveform_window.dart:183`) currently mounts
  `WaveformView` full-screen with **no localization ancestor**. The readout
  needs l10n; adding `AppLocalizations` to the sub-window is part of this
  part's real cost.
- Push transport state over `waveformWindowChannel`
  (`waveform_window_channel.dart`) alongside the existing frame pushes: track
  states, loop position, tempo, armed set, interaction mode. Reuse the
  established ready-handshake — the main window must not push readout state
  before `waveformWindowReadyMethod`.
- The waveform stays; it becomes one region of the readout rather than the
  whole surface.
- `PedalFaceplate` mirrors this window in its 7″ aperture
  (`pedal_faceplate.dart:111` `_ScreenWaveform`) — the simulator must show the
  same readout, or the on-screen pedal stops matching the hardware.
- **Risk:** state push frequency. The waveform channel is already a hot path;
  the readout must diff and push on change, not per frame.

### Part 3 — Rack domain model + global library + persistence

The data part, and the largest. No UI.

- `FxRack` — `{id, name, envelope}`, where the envelope is the existing
  `FxChainEnvelope` (`fx_chain_envelope.dart:52`) verbatim. Racks are not a
  new chain format; they are a *name and identity* wrapped around the one that
  already crosses every layer boundary.
- A rack library store. Prefer a new `rack_repository` package over more keys
  on `settings_repository` — the library is app-level user data with its own
  lifecycle, and `lib/common` cannot import feature packages [VGV layering].
  Decide in the part plan; do not smear it across `settings_repository`'s
  already-crowded key space.
- Extend `FxChainMeta` (`fx_chain_envelope.dart:9`) so `inheritedFrom` carries
  the rack id **and** the name captured at inherit time (D2). Widening the
  envelope means a schema bump — the session is at v5 (`session.dart:491-506`)
  and the migration story must be written down in the same terms part 3b used.
- Placement references + overrides in the session; anonymous chains migrate as
  unnamed local chains (D3) with no auto-naming.
- `FxAddress` (`packages/looper_repository/lib/src/models/fx_address.dart`)
  and its `canonicalString()` are **unchanged**. Racks are addressed by id, not
  by position; a rack reference is additive metadata on a placement.
- Cover the third sink: `PerformanceChains`
  (`packages/performance_repository/.../performance_chains.dart:16`) feeds DAW
  export. A rack name is provenance the export can carry, but export behavior
  must not change in this part.
- **Risk:** three persistence sinks disagreeing. `persistTrackFxChain`
  (`lib/common/fx_chain_persistence.dart:18`) exists precisely because the
  bloc and pedal paths drifted once. Every new write path funnels through one
  writer, same discipline.

### Part 4 — FX panel in the drawer: stage tabs + rack UI

- A drawer `fx` destination with Input / Loop / Track / Master tabs backed by
  `FxStage` (`fx_address.dart:9`) — stage is data, not four widgets.
- Reuse `FxScope` (`fx_editor/fx_scope.dart:19`) and `FxDock`
  (`fx_editor/fx_dock.dart:22`) as-is. The editing surface is already
  stage-parameterized from part 4b; this part changes *where it is mounted*,
  not how it edits.
- Rack UI: pick a rack, load onto the current placement, save-as-rack, rename,
  duplicate, delete. Deleting a rack must not break takes that inherited it —
  D2's captured name is what makes that safe.
- Inherited-rack provenance badge on loop chains, replacing the anonymous
  inheritance hint. `signal_fx_summary.dart` and the existing overdub-mismatch
  hint (`fx_dock.dart:252`) are the reuse targets.
- **Risk:** double surface. The Signal page (`showSignalPage`,
  `signal_list_view.dart:33`) still exists and still edits FX. This part must
  either route the Signal page's FX editing into the drawer panel or state
  explicitly that Signal keeps its own copy until part 5 folds it — two live
  editing surfaces for the same chains is exactly the confusion this epic
  exists to remove.

### Part 5 — Routing panel in the drawer: stage tabs

- The routing half of today's Signal page — `_InputsPane` (`:161`),
  `_TracksPane` (`:267`), `_OutputsPane` (`:474`), `signal_routing_chips.dart`,
  trace state (`signal_rows.dart:280`) — becomes the drawer's `routing`
  destination, with the same four stage tabs as part 4.
- This is where `showSignalPage` retires. After this part, the tray no longer
  pushes a full-screen Signal route, and the `isNavigating` re-entrancy guard
  it motivated can go with it.
- **Risk:** the Signal library is a single `part`-based unit rooted at
  `signal_list_view.dart` (~7 files, `signal_fx_rack.dart` alone is 1637
  lines). Splitting FX (part 4) from routing (part 5) across a `part` boundary
  is the mechanical hard bit of this epic. Plan the seam before writing code;
  if the split proves worse than the disease, keeping one panel with tabs is
  an acceptable fallback — say so in the part plan rather than discovering it
  mid-build.

### Part 6 — Three-state live-monitor control

- One control per rack placement: off / auto / on. `auto` = heard while the
  track is armed for record (D5). Default `auto`.
- State lives on the placement (D5), so relocating the control later is a view
  change. Persist it with the placement, not with the rack — two tracks using
  the same rack must be able to disagree about monitoring.
- Engine wiring: the monitor path already exists per-input
  (`monitor_input_fx.$input`, `monitor_fx.$input`). This part extends it to
  track-stage placements; scope the native work in the part plan before
  committing to an autonomy label.
- **Risk:** feedback. Monitoring a track's FX while recording into it is the
  literal definition of a loop if the routing is wrong. The macOS loopback
  lesson applies — verify on hardware before calling it done.

### Part 7 — Pedal panel as a rail destination

- Move `PedalAssignmentPage` (`pedal_assignment_page.dart:41`) out of
  Settings → Audio → Pedal and into the drawer's `pedal` destination. Closes
  **#440**.
- `_PlatePicker` (`:110`) already drives `PedalPlate`
  (`pedal_plate.dart:50`) with a `selected` set — the presentational
  extraction from FX v3 part 6a is exactly what makes this a re-mount rather
  than a rewrite.
- Keep the Settings → Audio entry point working (or remove it deliberately and
  say so); do not leave two paths to the same page by accident.
- Smallest part in the epic and it closes a filed bug — a good first build
  after part 1.

### Part 8 — Custom pedal mode + protocol v4

- A fourth `InteractionMode` (`lib/looper/model/interaction_mode.dart:8`)
  where every switch is a blank slot assigned from a function list. REC / MUTE
  / FX keep their fixed meanings (D4). A full remap matrix stays rejected —
  overriding REC and STOP invites collisions with the long-press system
  gestures.
- **The wire has no free slot.** The v3 mode field is 2 bits (low bit in flags
  bit 0, high bit in byte 2 bit 1, `pedal_codec.dart:167-191`) and the fourth
  value `3` is explicitly **reserved and rejected** on decode
  (`pedal_codec.dart:248`, `:303`). Defining `3 = custom` inside v3 would make
  every already-shipped v3 decoder reject the frame outright. This part needs
  a **protocol v4** with the same downgrade discipline part 5a and the [B10]
  amendment established: the codec alone owns the per-version degrade, and a
  v3 pedal must render Custom as something safe rather than refusing frames.
- Reuse the FX v3 part 6b binding model verbatim: `FxBindingTarget`
  (`lib/control/binding/fx_binding_target.dart:29`), `PedalBinding`,
  `PedalBindingSet`, `FxBindingResolver`. Only the *function list* is new —
  Custom mode's slots resolve through the same machinery, and
  `releaseAllMomentary()` stays the one enforcement point.
- `InteractionMode.bootDefaults` excludes `fx` on purpose (R12: booting into a
  dead surface). Custom mode has the same hazard — an unconfigured Custom mode
  is ten dead switches. Exclude it from boot defaults for the same reason.
- Carries a `blocked-verify` hardware slice: mode cycle on a real pedal, and a
  v3 pedal receiving a v4-mode frame.

### Part 9 — Hardening

- Regenerate the author-only screenshot goldens (`test/screenshots/`) and
  eyeball them — they skip everywhere but the author's machine and rot
  silently after a UI redesign.
- Appliance soak on the console: drawer open/close under load, 7″ readout
  across a sub-window respawn, WiFi/Bluetooth panels still reachable from the
  rail.
- Accessibility pass on the rail — focus order and semantics (feeds **#198**).
- Docs: `docs/PROGRESS.md`, and retire the tray/Signal-page descriptions this
  epic invalidates.
- `blocked-verify`: green CI does not mean it works on the floor.

## Risks

- **The Signal-page `part` split (part 5)** is the mechanical risk. Everything
  else is additive; this one is surgery on a 7-file `part` unit.
- **Two live FX editing surfaces** between parts 4 and 5. Named as part 4's
  exit criterion so it cannot be discovered late.
- **Protocol v4 (part 8)** — the reserved-value rejection means there is no
  cheap path. Better to know now than to find it in the build.
- **Schema bump in part 3.** The session is at v5; racks make it v6. Migration
  correctness is the difference between "racks shipped" and "someone's set
  came back dry", which is exactly the failure #389 already describes.
- **Scope.** Nine parts is FX-v3-sized. Parts 1, 2, 3 and 7 are independently
  valuable and independently mergeable; if the epic stalls, those four alone
  fix the two filed bugs (#440) and the discoverability complaint that
  triggered it.

## Resolved from the brainstorm's open questions

| Question | Resolution |
|---|---|
| Does the zero-config FX-mode layout keep binding Track chains? | Yes — no change (D4). |
| Rack persistence and scope? | Global library, sessions hold references (D1). |
| Inherited rack: frozen or editable? | Frozen copy showing its origin name (D2). |
| Does `auto` follow armed, selected, or either? | Armed (D5). |
| Where does the tuner live? | Rail destination; implementation out of epic (D6). |
| Migration of existing anonymous chains? | Unnamed local chains, no auto-naming (D3). |
| Does the 7″ readout change under the drawer? | No, rigid in v1 (D7). |

## Follow-ups (not in this epic)

- **Tuner implementation** — needs pitch-detection DSP in the native engine
  (D6). File as its own issue; this epic only reserves its rail slot.
- **#372** (virtual slider pots on the 7″) — overlaps part 2's surface. Decide
  after part 2 lands whether the readout hosts them or they stay separate.
- **#453** (persistent device-lost / MIDI-lost surface) — needs a home in the
  new shell; the rail is the obvious candidate.
- **#389** (session load never writes chains back to settings) — pre-existing,
  and part 3's persistence work will touch the same code. Worth scheduling
  before part 3 rather than after.
