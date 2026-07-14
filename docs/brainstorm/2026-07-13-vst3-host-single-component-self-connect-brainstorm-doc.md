---
date: 2026-07-13
topic: vst3-host-single-component-self-connect
---

# Vst3Host: don't self-connect single-component plugins' controller

## What We're Building

In `Vst3Host::loadImpl` (`packages/loopy_engine/src/host/host_vst3.cpp`, ~line 682-705),
`connectComponentAndController()` is called unconditionally whenever `controller_` is
non-null. For a single-component plugin — where the edit controller is obtained via
`component_->queryInterface(IEditController::iid, ...)` on the *same* underlying object
as `component_` — `separateController` stays `false`, but the connect call still runs.
`connectComponentAndController()` queries `IConnectionPoint` off both `component_` and
`controller_`, which for a single-component plugin are literally the same object, and
connects it to itself if it implements that interface. The vendored VST3 SDK's own
reference host (`third_party/vst3sdk/public.sdk/source/vst/hosting/plugprovider.cpp:218`)
explicitly guards this: `if (res && !isSingleComponent) return connectComponents();`.

The fix is to gate the existing `connectComponentAndController()` call in `loadImpl` on
`separateController`, so it only runs when the controller is a genuinely distinct object
from the component — mirroring the SDK's own pattern exactly.

## Why This Approach

Considered two approaches:

1. **Gate the call site on `separateController`** (chosen). `loadImpl` already computes
   `separateController` to decide whether to call `controller_->initialize(&hostApp_)`.
   Reusing that same flag to also gate `connectComponentAndController()` is a one-line,
   minimal-diff change that exactly mirrors the SDK reference host's
   `if (res && !isSingleComponent)` structure. No new state, no API changes, no risk to
   any other code path.

2. **Push the guard inside `connectComponentAndController()` itself** (e.g. compare
   `component_ == controller_` pointer identity, or compare `compCP_ == ctrlCP_` after
   querying). Rejected: pointer-identity comparison between an `IComponent*` and an
   `IEditController*` obtained via two different `queryInterface` calls is not guaranteed
   to be reliable in all COM-style implementations (the two interface pointers could
   differ even when they resolve to the same object, depending on how the plugin
   multiply-inherits). The `separateController` boolean, computed at the point the
   controller was first obtained, is the unambiguous signal — it directly answers "was
   this instantiated as a separate object" rather than trying to infer it after the fact.
   Also this would require querying `IConnectionPoint` first just to throw the result
   away, doing unnecessary work.

Approach 1 is also exactly what the suggested fix direction in the issue recommends, and
it's the smallest possible change that removes the divergence from the SDK's own host.

## Key Decisions

- **Gate on `separateController`, at the `loadImpl` call site** (line ~704): change
  `if (controller_) { ... connectComponentAndController(); }` so the
  `connectComponentAndController()` call only fires when `separateController` is `true`.
  The `controller_->setComponentHandler(&componentHandler_)` call stays unconditional
  (unaffected by this bug — the component handler wiring is unrelated to the
  connection-point self-connect issue, and the SDK's own host does not skip that step
  for single-component plugins either).
- **No changes to `connectComponentAndController()` or the teardown/disconnect path**
  (~line 1008-1028). Teardown already null-guards `compCP_`/`ctrlCP_` before
  disconnect/release, so if they're simply never populated (single-component case),
  teardown is a no-op for those fields — verified by reading the existing code, no
  follow-up change needed there.
- **No behavior change for any plugin currently in this repo's test suite.** Verified by
  grepping `packages/loopy_engine/vst3/` (tremolo, echo, drive, filter, delay, octaver,
  reverb — all the repo's own plugins) for `getControllerClassId` and `IConnectionPoint`:
  none of them implement either, meaning every one of them is single-component and none
  of them implement `IConnectionPoint` on themselves. So today this call is already a
  silent no-op for all of them (the `if (compCP_ && ctrlCP_)` guard inside
  `connectComponentAndController()` prevents any actual `connect()` call when the object
  doesn't implement `IConnectionPoint`). This confirms the fix is purely additive
  safety for third-party single-component plugins that *do* implement
  `IConnectionPoint` on themselves — nothing in this repo's golden-parity harness or
  host tests currently depends on, or exercises, the buggy unconditional-connect
  behavior.
- **Test approach**: add a host-level unit test (or extend an existing one in
  `vst3/test/`) asserting that for a single-component plugin, `connectComponentAndController()`
  (or its effect — no `IConnectionPoint::connect` call) is skipped. Since none of this
  repo's real plugins implement `IConnectionPoint`, a real assertion needs either (a) a
  minimal fake/mock single-component plugin implementing `IConnectionPoint` on itself to
  observe whether `connect()` gets called, or (b) a lighter-weight unit test that directly
  exercises the gating logic/boolean rather than a full plugin load. The concrete test
  design is left to the planning phase, which should look at what test scaffolding
  already exists in `vst3/test/host_harness.{h,cpp}` before deciding whether a new fake
  plugin is warranted or whether a narrower test (e.g. a small standalone
  `IConnectionPoint`-implementing test double wired through the existing harness) is
  more appropriate.

## Open Questions

- Exact shape of the regression test (fake single-component plugin with self-implemented
  `IConnectionPoint` vs. a narrower logic-only test) is deferred to `/plan`, which should
  inspect `vst3/test/host_harness.{h,cpp}` and `load_smoke.cpp` first to reuse existing
  scaffolding rather than inventing new plugin fixtures if avoidable.
- Assumption (documented, not blocking): this fix should NOT touch
  `controller_->setComponentHandler(&componentHandler_)` — that call is orthogonal to
  the connection-point issue and the SDK reference host does not gate it either.
