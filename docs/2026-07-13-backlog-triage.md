# Backlog triage — 2026-07-13

A verified sweep of everything in flight or pending, sorted into **Finish /
Build / Decide / Defer / Drop**. Every claim below was checked against `master`
at `519d3fa`, not taken from memory. Items are ordered within each bucket by
priority.

---

## FINISH — relevant, cheap, or unblocks the merge train

| # | Item | Evidence | Action | Status |
|---|------|----------|--------|--------|
| F1 | **Unblock PR #146** (DAW export chains) | The *only* failing check was `spell-check`: cspell flagged `writeups` at `packages/daw_export/test/corpus/README.md:77`. | Hyphenated to "write-ups" (`55053e5`). | ✅ **DONE** |
| F2 | **Merge the VST3 plugin stack #140→#145** | Strict linear stack. macOS-only plugins (Echo/Drive/Filter/Tremolo/Octaver) + golden-parity harness. | Merged bottom-up, each rebased onto master + CI-gated. | ✅ **DONE** |
| F3 | **Merge the export stack #146→#147** | Separate 2-PR stack. #147 hit one flaky `control_cubit_test.dart:669` failure post-rebase; cleared on re-run. | Both merged. | ✅ **DONE** |
| F4 | **Open a PR for the LED-gamma firmware commit** | `claude/led-gamma-correction-9c8334` worktree holds 1 self-contained commit *"gamma-correct the LED output on all three firmwares"* — never turned into a PR. Part of the active pedal-hardware line (#149 landed 2 days ago). | Open as its own PR off master. | ⏳ pending |

**Merge-train notes (2026-07-13):** all 8 PRs squashed to master. Because these
were stacked with squash merges, each child was retargeted to `master` then
`git rebase --onto master <prev-part-original-tip>` to drop the already-merged
parent commits (a plain retarget went `CONFLICTING`). All 8 feature branches
deleted. Local `master` in the main worktree left un-fast-forwarded (uncommitted
`app_theme.dart` edit present) — `git pull` when ready.

## BUILD — the VST3 "loopy-fx-vst3-plugins" 17-part series

**Important:** the umbrella plan docs (`2026-07-08-feat-loopy-fx-vst3-plugins-plan.md`,
`2026-07-05-…-daw-export-plan.md`) are **not committed** to master — referenced by
the PRs but never merged (gitignored or lived only on the now-deleted branches).
The series map below was **reconstructed from git subjects + the breadcrumbs in
`packages/loopy_engine/vst3/CMakeLists.txt`** (header comment + lines 26, 122).

Architecture: plugins are real `.vst3` bundles under `packages/loopy_engine/vst3/<fx>/`
(each = processor/controller/factory/ids + parity test), built by a standalone
hand-rolled CMake against the vendored SDK (`third_party/vst3sdk`, 363 files).
`packages/daw_export/` emits Ableton `.als` referencing them by class GUID.

| Part | Scope | Status |
|------|-------|--------|
| 1 | `loopy_dsp_core` scaffold + VST3 SDK vendoring | ✅ done |
| 2–3 | Loopy **Delay** (#138), **Reverb** (#139) | ✅ done |
| 4 | golden-parity audio-diff harness (#140) | ✅ done |
| 5–9 | **Echo/Drive/Filter/Tremolo/Octaver** (#141–#145) — completes all 7 built-in FX | ✅ done |
| 10 | DAW export: real device chains in `.als` (#146) | ✅ done |
| 11 | export-flow device-chain feedback + re-export (#147) | ✅ done |
| **12** | **D-SIGN** — macOS hardened runtime + **notarization** for distribution (CMake:122) | ⏳ not started |
| **13** | **Windows** VST3 port (MSVC build of SDK; `.vst3/Contents/x86_64-win/*.vst3` DLL) (CMake:26) | ⏳ not started (**= B2**) |
| **14** | **Linux** VST3 port (`.so` in `Contents/x86_64-linux/`) (CMake:26) | ⏳ not started (**= B2**) |
| **15–17** | **UNDEFINED** — no breadcrumb in code or docs. Candidates: installer/packaging, CLAP format, pluginval/validator CI, preset mgmt, more DAW targets (Reaper/Logic) beyond Ableton `.als`. Needs a fresh planning session. | ❓ unknown |

**Notes for whoever picks this up:**
- The **7 DSP processors are portable C++** (`processor.cpp`) — parts 13/14 are
  mostly per-platform *build + bundle packaging* (the macOS `codesign` /
  `Contents/MacOS` / SDK build in CMakeLists is the only OS-specific layer),
  plus wiring `native-tests`/`build-*` CI to compile them off-macOS. High value:
  makes the plugins usable outside macOS. Moderate, mechanical.
- **Part 12** is macOS-only distribution polish (Apple notarization) — needed
  before shipping the `.vst3`s to users, low urgency until a release.
- **Parts 15–17 are a genuine unknown** — don't assume; ask or re-plan before
  committing to "6 parts left."

## DECIDE — RESOLVED (both dropped after verification)

| # | Item | Verdict | Evidence |
|---|------|---------|----------|
| D1 | **`worktree-refactor+audio-engine-robustness`** | ✅ **DROPPED** (worktree + local + **remote** branch deleted; SHA `b6b0afb` if ever needed) | Verification **overturned** the earlier "cherry-pick the reliability wins" idea: master *already has the whole branch*. The `core/` refactor, `engine_process.c`, `engine_fx.c`, typed command union, FX vtable, and role interfaces are all present on master. So are every reliability follow-up — P1 xrun (`engine_snapshot.dart` `xrunCount`), P2 CI native-tests (`main.yaml:104` `native-tests` job), P3 ASIO recovery, P5 FX prepare/defaults vtable (`fx_*_prepare`/`fx_*_defaults`), P6 per-step limiter (`le_process_master_step`, extracted for unit-testing). Master reimplemented all 23 commits independently as cleaner PRs. Nothing unique remained. |
| D2 | **`loopy-midi` worktree** (`feat/midi-device-selection`) | ✅ **DROPPED** (worktree + local branch removed) | Clean tree, 12 ahead / 161 behind — all pre-squash originals of merged work (#30, multi-lane, pedal docs via #35). The only doc deltas vs master were cosmetic "real-time"↔"realtime" hyphenation. Nothing to preserve. |

## DEFER — relevant, not urgent (several hardware-gated)

| # | Item | Evidence / correction | Note |
|---|------|----------------------|------|
| V1 | **Accessibility pass** | **PROGRESS.md is stale here** — it says "no `Semantics` coverage yet". In reality `Semantics(` appears in **19 `lib/` files**. | Re-scope from "start" to "audit gaps + focus order + a11y tests". |
| V2 | **FX "loading…" visual** | Partial handling already exists (`loading`/`unavailable` in `fx_scope.dart`, `fx_inspector.dart`, `fx_block_chip.dart`). | Verify it renders on cold plugin boot; small polish only. |
| V3 | **Session bundle gaps** | Stems are lane-0-only; lane routing (input/output/count) isn't carried, so leftover routing can persist across loads (chains + monitor routing *are* reset). | Bounded fix; schedule when session work resumes. |
| V4 | **Hardware validations** | Latency ≤10 ms round-trip gate; ASIO full-count interface end-to-end; live MIDI-pedal smoke; 2nd-display waveform window. | A checklist to run when the hardware is in front of you, not backlog. |
| V5 | **Per-track multi-loop phase alignment** | Absolute-downbeat option for k-loop tracks. Niche. | Low priority. |

## DROP — superseded / done / no longer important

| # | Item | Why |
|---|------|-----|
| X1 | **Raspberry Pi GPIO backend** | No `gpio_client` package, no `gpio` seam in `controller_repository/lib`, no recent Pi-console commits. The hardware direction is now the **MIDI foot-pedal** (active: #149 two days ago), which supersedes the GPIO-appliance path. Drop unless the Pi appliance is deliberately revived (its plans + PCB still exist in `docs/`/`hardware/`). |
| X2 | **ASIO l10n orphaned-keys sweep** | Effectively **done** — the orphan keys (`backendGroup`, `backendWasapi`, `exclusiveModeTitle`, `audioSetupKicker`, `asioDriverHandlesAllIo`, …) are already gone from the ARBs. `engineStoppedBanner` remains but is **still used** (`tracks_chrome.dart:154`), so it is not an orphan. Close the follow-up. |

---

## Cleanup already done in this pass
- Pruned 4 leftover worktrees + branches for merged PRs: `reconnect-reapply-rig`
  (#153), `restart-record-offset` (#157), `latency-monitor-enable-clobber`
  (#152), `input-monitoring-fx-cache-4ba187` (#150).
- Kept `led-gamma-correction` (F4) and `worktree-refactor+…` (D1) — unmerged work.

## Recommended order of attack
1. **F1** (cspell) → unblocks **F3**.
2. **F2 → F3**: merge both VST3 stacks bottom-up. Clears 8 open PRs.
3. **F4**: LED-gamma PR (quick, keeps pedal line moving).
4. **D1**: decide the engine-refactor branch — recommend cherry-picking the
   reliability wins as small PRs.
5. **D2**: drop the `loopy-midi` worktree.
6. **B1/B2**: scope VST3 parts 12–17 + cross-platform.
7. Fix the stale accessibility line in `PROGRESS.md` (V1) whenever docs are touched.

_All buckets above verified against `master@519d3fa`._
