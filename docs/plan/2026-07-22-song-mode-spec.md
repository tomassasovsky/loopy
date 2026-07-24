---
title: "B1: Song & Band mode spec + per-mode clock arming (from Sheeran Looper X manual v1.0.0)"
type: spec
date: 2026-07-22
issue: 263
status: APPROVED — plan-gate cleared 2026-07-23
index: 2026-07-22-feat-tempo-aware-looper-modes-plan.md
---

> **APPROVED.** Plan-gate cleared by the user 2026-07-23. B4 (Song mode
> engine) is unblocked. Transcribed from the Sheeran Looper X User Guide
> v1.0.0 (§3.1, §4.2, §5.9, §6.2). Engine work for Song/Band (B4) must not
> start until this is approved. Items marked **[loopy decision]** are places
> the manual is silent or loopy's 8-track model differs from the Sheeran's
> 4-track model; each carries a proposed default.

## 1. What the manual actually says (normative transcription)

### Modes (§4.2, §5.9.2)

- **Multi**: four looper tracks locked to the same length. (Ed's workflow;
  structurally today's loopy.)
- **Sync**: tracks can vary in length; **one primary track** (crown icon in
  Wave view); the three others "can be a multiple or division of the primary
  track's length, and will be automatically quantized to keep them in sync
  with the primary track."
- **Song**: "four looper tracks that can vary in length and be played back
  independently. Useful for creating different sections of a song (e.g.,
  verse, chorus, bridge, and outro)."
- **Band**: "a combination of Sync and Song Modes, with one primary track
  and three other tracks that can be played independently as song sections
  over the primary. Like in Sync Mode, the other tracks must be a multiple
  or division of the primary track's length, and will be automatically
  quantized." Use: "songs with a consistent backing beat or repeating phrase
  underneath."
- **Free**: "four un-synced, independently playing, free-form tracks."
- Mode change with recorded content: "If you change the selected mode after
  recording, **all loops are discarded**" (§4.2 Tip) — confirms plan decision
  D4 (mode locked while content exists; explicit clear-all confirmation).

### Section transport (§3.1, §5.9.4)

- Track pedals "select and control loop **tracks and sections**";
  double-press solos the selected track/section.
- STOP pedal per mode (§3.1 item 6): Multi — stops all tracks; Sync — stops
  all tracks; **Song — stops an individual section**; **Band — stops a
  section or the primary track**; Free — stops all tracks.
- **One Shot** (§5.9.4, per-track): a track "plays just once and then
  stops" — the manual's tool for non-looping sections.
- Sections in Song/Band are simply the (non-primary) tracks; the manual
  defines no separate section object, no section count beyond the track
  count, and no automatic "advance to next section."

### Tempo & click (§5.9.1)

- Tempo range **30–280 BPM**.
- Time signatures — exactly **17**: 2/4, 3/4, 4/4, 5/4, 6/4, 7/4, 5/8, 6/8,
  7/8, 8/8, 9/8, 10/8, 11/8, 12/8, 13/8, 14/8, 15/8.
- **Click is a 4-value mode**, not a boolean: **Off / Rec** (click while
  recording + overdubbing) / **Rec (1st Layer)** (click only while recording
  the first layer) / **Play+Rec** (click during playback, recording and
  overdubbing). Click level/pan are mixer controls.
- **Count-In**: on/off + a configurable number of **measures** (not fixed at
  one bar); applies "before a loop starts to play, record or overdub."

### Track length & quantize (§5.9.3)

- Multi: ONE track-length setting for all tracks; other modes: per-track.
- Sync/Band: the TRACK LENGTH setting **applies only to the first recorded
  track**; every later track is AUTO — quantized to "AUTO (Bars)" —
  exception: lengths may be half, double, or quadruple of each other.
- AUTO + Click OFF → detect **tempo and bar count** from the first
  recording. AUTO + Click ON → detect **measures only**, tempo unchanged.
- 1–64 BARS + Click OFF → the **tempo is calculated automatically** from the
  recording and the set bar count. 1–64 BARS + Click ON → first-layer
  recording auto-finishes at N bars and starts overdubbing.
- Track length is only available when **MIDI Clock Receive is OFF**.
- Quantize: On/Off + division — nearest **1 bar / 1/2 / 1/4 / 1/8 / 1/16
  note** — applied to "the start and end points of your loop."

### Time stretch (§5.9.5) — two independent toggles

- **Sync Audio to Tempo**: whether tempo changes affect the loop audio at
  all.
- **Time Stretch**: whether pitch is preserved when they do (0.5×–2×,
  "without any unwanted artifacts"). I.e. Sync ON + Stretch OFF is
  varispeed-style (speed and pitch change); Sync ON + Stretch ON is
  pitch-preserved.

### MIDI clock (§6.2.1, §6.2.2)

- **Send**: active "while recording, overdubbing, and playing your loops in
  **Multi, Sync and Band** modes" (not Song, not Free).
- **Receive** — when enabled:
  - Track pedals **arm** record/overdub; armed pedal LEDs flash.
  - External clock **not running**: armed tracks start when **MIDI Start**
    is received. Playback cannot be started or stopped while the external
    clock is not running.
  - Clock running + **Multi**: armed tracks wait for the **next downbeat**.
  - Clock running + **Sync/Band**: armed tracks wait for the **primary
    track to return to its beginning**.
  - **MIDI Stop** stops recording/overdubbing.
  - STOP pedal: Multi — tracks stop immediately; Sync/Band — tracks stop at
    the **end of the primary track**.
  - "The loop's tempo cannot be manually changed"; "Sync Audio to Tempo
    cannot be disabled."
  - Manual warns: tempo cannot change during recording — ensure lock before
    starting; odd/miscut bar lengths "may not work properly."
- The §6.2.1 intro names "Fixed, Sync and Serial-Sync modes" — inconsistent
  with the rest of the manual (those modes don't exist on this device); the
  operative bullets above reference Multi/Sync/Band and are taken as
  normative.

## 2. Loopy adaptation — the six B1 questions

| # | Question | Answer |
|---|----------|--------|
| 1 | How many sections; what is a section? | A section **is a track** (no separate object). Loopy: 8 tracks → up to 8 sections in Song mode; in Band, 1 primary + 7 sections. **[loopy decision]** — the Sheeran has 3 non-primary tracks; loopy's 8 fall out of the same rule. Manifest `songSections` field is DROPPED (nothing to persist beyond tracks themselves); `bandGroups` likewise — Band grouping is just "primary vs. rest". |
| 2 | Pedal advance gesture? | **None exists on the Sheeran** — sections are started/stopped directly via their track pedals; there is no "advance to next section" action. **[loopy decision]**: drop the planned `advanceSection` LooperAction (D20) in favor of direct section (track) presses, matching the manual. A follow-up convenience action can be added later if wanted. |
| 3 | Quantized transition point? | Song mode: sections start/stop **independently and immediately** (no primary, no shared grid obligation); quantize setting still governs record start/end. Band mode: section starts/stops quantize to the **primary track's cycle** (STOP semantics: "end of the primary track"). |
| 4 | In-flight recording at a section switch? | No special rule in the manual; recording follows the normal one-capturer + quantize rules. MIDI Stop (slaved) ends recording. **[loopy decision]**: starting another section while one records does a normal hand-off (existing engine behavior). |
| 5 | Distinct section lengths? | Yes — Song tracks vary freely in length; Band non-primary tracks must be multiple/division of the primary. |
| 6 | Distinct tempos per section? | **No** — one session tempo. Confirmed: nothing in the manual gives sections independent tempo. |

**Engine consequences for B4** (unchanged from part-2 otherwise):
Song mode = per-track independent transport like Free, **plus** the shared
grid (one tempo/click) and One-Shot-style stop semantics; Band = Sync's
primary/multiple-division machinery + Song's independent start/stop for
non-primary tracks. This means B2b's per-track clocks are the substrate for
**Song and Band too**, not just Free — Band derives non-primary phase from
the primary rather than the master clock. One Shot per-track (§5.9.4) enters
scope as a small Song/Band-phase addition (a per-track "play once then
stop" flag). Feedback/Decay (§5.9.4) stays **out of scope** (not tempo
related — candidate follow-up issue).

## 3. Per-mode clock-arming table for Phase E (E2)

| External clock state | Mode | Armed record/overdub starts | STOP pedal | MIDI Stop |
|---|---|---|---|---|
| Not running | any | on MIDI Start | playback cannot start/stop | — |
| Running | Multi | next downbeat | tracks stop immediately | ends rec/overdub |
| Running | Sync | at primary-track top | tracks stop at end of primary | ends rec/overdub |
| Running | Band | at primary-track top | section/primary stop at end of primary | ends rec/overdub |
| Running | Song / Free | **receive inactive** (manual: send/receive operate in Multi/Sync/Band only) — **[loopy decision]**: entering Song/Free while slaved drops to internal clock with a UI notice | — | — |

While slaved: manual tempo/tap rejected; Sync Audio to Tempo forced on
(index D3/D14 unchanged).

## 4. Corrections this spec feeds back into the plan (applied)

1. Time signatures: **17**, exact set above (index D1, A1).
2. Tempo range: Sheeran is 30–280; loopy keeps **30–300** as a deliberate
   superset (documented deviation).
3. Click: 4-value **click mode**, not boolean (A2); click level is a mix
   control (already planned as click volume).
4. Count-in: configurable **measures count**, default 1 (A2/D9).
5. Track-length preset semantics: the §5.9.3 matrix above refines D7/D17
   (A6) — notably "N bars + click off ⇒ tempo derived from recording length
   ÷ N bars", and presets interact with click state.
6. Clock send restricted to Multi/Sync/Band (C1/D15); receive likewise
   (E1/E2, table above).
7. Time-stretch is a **two-toggle model** (Sync Audio to Tempo ∥ Time
   Stretch); whether loopy implements the varispeed (stretch-off) leg is a
   D0 spike decision — pitch-preserved-only remains the part-4 default with
   varispeed as documented deviation if skipped.
8. `advanceSection` dropped from D20; `songSections`/`bandGroups` manifest
   fields dropped (v4 schema note updated); One Shot flag added to Phase B
   scope.
