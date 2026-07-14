---
title: Vst3Host: don't self-connect single-component plugins' controller
type: fix
date: 2026-07-13
---

## Vst3Host: don't self-connect single-component plugins' controller - Standard

## Overview

`Vst3Host::loadImpl` (`packages/loopy_engine/src/host/host_vst3.cpp`, ~line 682-705)
calls `connectComponentAndController()` unconditionally whenever `controller_` is
non-null, including the single-component case where `controller_` was obtained via
`component_->queryInterface(IEditController::iid, ...)` on the *same* underlying
object as `component_` (`separateController` stays `false` on that path).
`connectComponentAndController()` queries `IConnectionPoint` off both `component_`
and `controller_` and connects them to each other — for a single-component plugin
this means connecting the object to itself if it implements `IConnectionPoint`.

The vendored VST3 SDK's own reference host
(`third_party/vst3sdk/public.sdk/source/vst/hosting/plugprovider.cpp:218`) guards
exactly this case: `if (res && !isSingleComponent) return connectComponents();`.
This plan gates the existing `connectComponentAndController()` call on the existing
`separateController` boolean, mirroring the SDK's own pattern.

## Problem Statement / Motivation

Today, any single-component plugin that happens to implement `IConnectionPoint` on
itself would be connected to itself — `compCP_->connect(ctrlCP_)` and
`ctrlCP_->connect(compCP_)` where `compCP_ == ctrlCP_` is effectively the same
object. Most plugins don't implement `IConnectionPoint` on a single-component
design (confirmed: none of this repo's own 7 VST3 plugins do — see Technical
Considerations), so this is a silent no-op today. But any single-component
third-party plugin that does implement it could see duplicate/looped `notify()`
calls or other undefined behavior — exactly what the SDK's own host was written to
avoid. Fixing this removes an unnecessary divergence from the SDK's reference
hosting pattern with no behavior change for any currently-supported plugin.

## Proposed Solution

In `Vst3Host::loadImpl`, change the controller-wiring block (~line 696-705) from:

```cpp
if (controller_) {
  if (separateController) {
    controller_->initialize(&hostApp_);
  }
  controller_->setComponentHandler(&componentHandler_);
  connectComponentAndController();
}
```

to gate the connect call on `separateController`:

```cpp
if (controller_) {
  if (separateController) {
    controller_->initialize(&hostApp_);
  }
  controller_->setComponentHandler(&componentHandler_);
  if (separateController) {
    connectComponentAndController();
  }
}
```

`setComponentHandler` stays unconditional — it is unrelated to the
`IConnectionPoint` self-connect issue and the SDK's own host does not skip it for
single-component plugins either (`plugprovider.cpp` sets the component handler on
the controller regardless of `isSingleComponent`; only `connectComponents()` is
gated). Add/update the comment at this call site to reference the SDK's own guard
so a future reader understands the invariant.

No changes to `connectComponentAndController()` itself (~line 920-935) or to the
teardown/disconnect path (~line 1008-1028) — teardown already null-guards
`compCP_`/`ctrlCP_` before disconnecting/releasing, so leaving them unpopulated for
the single-component case is already handled correctly.

## Technical Considerations

- **No behavior change for any plugin this repo ships or tests today.** Verified by
  grep: none of `packages/loopy_engine/vst3/{delay,reverb,echo,drive,filter,tremolo,octaver}`
  implement `getControllerClassId` (so all are single-component,
  `separateController == false` for every one of them) or `IConnectionPoint` (so
  `connectComponentAndController()`'s own internal `if (compCP_ && ctrlCP_)` guard
  is already a no-op for all of them regardless of this fix). This confirms the
  fix is purely additive safety for third-party single-component plugins that
  implement `IConnectionPoint` on themselves — nothing in `run_native_tests.sh`'s
  plugin-slot tests or the `vst3/` golden-parity CTest suite currently depends on,
  or exercises, the buggy unconditional-connect behavior.
- **No test-infrastructure hook exists to exercise this path directly.** `Vst3Host`
  is a `.cpp`-local class (`host_vst3.cpp`) with no test seam: `load()` only takes a
  real bundle path and internally `dlopen`s it (`openBundle`) then resolves
  `GetPluginFactory` (`getFactory_`) — there's no dependency-injection point for a
  fake `IPluginFactory`/`IComponent`. The existing "stub host" used by
  `src/test/test_plugin_slot.c` (`StubHost` in `src/host/slot.cpp`) is a from-scratch
  `IPluginHost` implementation that bypasses VST3 COM entirely — it cannot exercise
  `connectComponentAndController()`, `IConnectionPoint`, or the
  `separateController` branch at all, so it can't be reused or extended to cover
  this fix. Building a *new*, real, `dlopen`-able single-component `.vst3` test
  fixture (own factory/processor/controller-on-self, implementing
  `IConnectionPoint`, wired into `vst3/CMakeLists.txt`) is possible in principle
  but is a disproportionately large addition (comparable in size to one of the
  seven shipped effect plugins) for a one-line gating fix, and is out of scope for
  this narrowly-scoped bug fix.
  - **Decision (documented assumption, no test added):** ship the code fix without
    new test infrastructure. Regression safety comes from the full existing
    native test suite (`src/test/run_native_tests.sh`, which compiles and links
    `host_vst3.cpp` on Darwin via the plugin-slot test target) continuing to pass
    unchanged, plus the `vst3/` golden-parity CTest suite continuing to pass
    unchanged (proving the real shipped plugins' load/param/state/process paths
    are unaffected). This is called out explicitly as a plan decision rather than
    silently skipped.
- **Platform scope**: `host_vst3.cpp` is shared across macOS/Windows/Linux hosting
  (the `loadImpl` function is not platform-`#ifdef`'d for this section), so the fix
  applies uniformly; only the surrounding `load()` SEH wrapper is Windows-specific
  and is untouched.
- **Architecture impact**: none — no new types, no header/API surface change, no
  change to `IPluginHost`.
- **Security considerations**: none — this only removes a self-connection that
  could otherwise cause duplicate callback delivery; it does not change any trust
  boundary.

## Success Criteria

```success-criteria
GOAL: Vst3Host::loadImpl only calls connectComponentAndController() when the edit
controller is a genuinely separate object from the component, matching the vendored
VST3 SDK's own PlugProvider guard, with zero behavior change for any plugin this
repo currently ships or tests.

SUCCESS CRITERIA:
- connectComponentAndController() in host_vst3.cpp's loadImpl is gated on separateController (single-component plugins skip it; plugins with a distinct controller class still connect) | verify: grep -A2 "controller_->setComponentHandler(&componentHandler_);" packages/loopy_engine/src/host/host_vst3.cpp | grep -q "if (separateController)"
- setComponentHandler is still called unconditionally whenever controller_ is non-null (unaffected by this fix) | verify: manual - read host_vst3.cpp loadImpl (~line 696-708) and confirm controller_->setComponentHandler(&componentHandler_) is not wrapped in the new separateController gate
- The full native test suite (engine, MIDI, plugin scan, plugin slot — the latter two link host_vst3.cpp) builds and passes on this Darwin host | verify: cd packages/loopy_engine && bash src/test/run_native_tests.sh
- No other files or behaviors outside this one gating change (and its comment) are touched | verify: manual - git diff --stat shows only host_vst3.cpp changed (plus this plan/brainstorm doc)

NON-GOALS:
- Adding new VST3 test-fixture-plugin infrastructure (fake IConnectionPoint-implementing bundle) to directly exercise this code path — judged disproportionate to the size of this fix (see Technical Considerations); may be revisited separately if the project ever wants general Vst3Host unit-test infrastructure.
- Touching connectComponentAndController()'s own body or the teardown/disconnect path — both already correct and unaffected.
- Fixing any other finding from the same review pass (other agents own those).

VERIFICATION COMMAND: cd packages/loopy_engine && bash src/test/run_native_tests.sh && grep -A2 "controller_->setComponentHandler(&componentHandler_);" src/host/host_vst3.cpp | grep -q "if (separateController)"
```

## Success Metrics

- `run_native_tests.sh` reports "ALL PASSED" for every suite it runs (engine core,
  MIDI, plugin scan, plugin slot), unchanged from before the fix.
- The diff to `host_vst3.cpp` is minimal (a few lines: the new `if
  (separateController)` gate plus an updated comment) with no other files touched
  other than this plan/brainstorm documentation.

## Dependencies & Risks

- **Risk: none identified for currently-shipped plugins** — confirmed via grep
  that no repo-owned plugin implements `getControllerClassId` or
  `IConnectionPoint`, so this is a behavior-preserving change for every plugin this
  repo builds and tests today.
- **Risk: reduced test coverage of the new branch** — accepted and documented above
  (no automated regression test added); mitigated by the fix's minimality (a
  single added `if`) and by full existing suite passing unchanged.
- **Dependency**: none on other in-flight work; this is a self-contained,
  single-file change.

## References & Research

- Bug evidence: `packages/loopy_engine/src/host/host_vst3.cpp:682-705` (the
  unconditional connect) and `packages/loopy_engine/src/host/host_vst3.cpp:920-935`
  (`connectComponentAndController()`'s `IConnectionPoint` query/connect).
  Teardown symmetry already correct: `packages/loopy_engine/src/host/host_vst3.cpp:1008-1028`.
- Reference pattern being mirrored:
  `packages/loopy_engine/third_party/vst3sdk/public.sdk/source/vst/hosting/plugprovider.cpp:130,162,218,225-235`
  (`isSingleComponent` computation and the `!isSingleComponent` guard on
  `connectComponents()`).
- Brainstorm doc:
  `docs/brainstorm/2026-07-13-vst3-host-single-component-self-connect-brainstorm-doc.md`.
- No related open PRs for this specific finding; this is 1 of 21 independent fixes
  from the same review pass, each in its own isolated worktree.
