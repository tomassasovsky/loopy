---
title: "feat(plugin): native editor window — macOS (part 6)"
type: feat
date: 2026-06-23
part: 6 of 9
umbrella: ./2026-06-23-feat-vst3-clap-plugin-hosting-plan.md
---

> **Part 6 of the [VST3 & CLAP plugin hosting](./2026-06-23-feat-vst3-clap-plugin-hosting-plan.md)
> stack.** Shared design and decisions (**D-WIN**, **D-SYNC**) live in the umbrella;
> the `le_plugin_editor_*` ABI is defined there (§New C ABI surface). macOS only —
> Windows/Linux editor embedding are parts 8–9.

## Dependencies

**Part 5** (params + the Open Editor button exists, inert). This part makes the
button open the plugin's own window and closes the two-way sync loop.

## Overview

Open a plugin's **own native editor window** as a **host-owned top-level NSWindow**
(D-WIN) — not embedded in the Flutter tree, sidestepping the child-window limitation
PROGRESS.md flags. Adds the `NativeWindowController` (NSWindow whose `contentView` is
the parent NSView the plugin attaches to), the `le_plugin_editor_*` ABI, the window
lifecycle/teardown rules, and the **inbound** half of two-way param sync (D-SYNC).

See umbrella **D-WIN** (ownership/teardown) and **D-SYNC** (≤10 Hz poll, source of
truth, **drain-before-refresh** sequencing, bloc-owned timer disposed on close).

## Tasks

### Native (C / Objective-C++)
- [ ] `NativeWindowController` (macOS): create a host-owned NSWindow, expose its
  `contentView` (NSView) as the attach parent.
- [ ] VST3 editor: `createView("editor")` → `isPlatformTypeSupported("NSView")` →
  `getSize` → `attached(contentView, kPlatformTypeNSView)`; implement `IPlugFrame`
  so plugin-requested `resizeView` resizes the NSWindow then calls `onSize`.
- [ ] CLAP editor: `gui->is_api_supported(COCOA)` → `create(COCOA, floating=false)`
  → `get_size` → `set_parent(contentView)` → `show`.
- [ ] `le_plugin_editor_open/close/is_open` on the `le_plugin_slot*` handle (all
  main-thread).
- [ ] **Teardown (D-WIN):** closing the owning slot/lane/track/session and app-quit
  force-close the editor first; removing a plugin whose editor is open force-closes
  the window; **zero leaked native windows**.
- [ ] **Inbound sync (D-SYNC):** drain the SDK output events (VST3
  `outputParameterChanges` / CLAP `out_events`) and expose changed param values for
  a main-thread read-back; full `state_get` on editor-close happens **after** the RT
  param queue is drained (no clobber).
- [ ] ffigen regen + `dart format`.

### Dart
- [ ] `EnginePluginHosting`: `editorOpen/editorClose/editorIsOpen` + a
  changed-params read-back; implement in `NativeAudioEngine`; `MockAudioEngine` no-op
  editor + static params.
- [ ] `LooperBloc` events `LooperLanePluginEditorOpened/Closed` (+ monitor); a
  ≤10 Hz poll **timer owned by the bloc, cancelled on close**, mirrors the first-N
  knob values while an editor is open.
- [ ] Wire the `_PluginDeviceCard` Open Editor button to dispatch the event.

## File References

- New: `packages/loopy_engine/macos/.../native_window_controller.mm`,
  `packages/loopy_engine/src/host/editor_*.{cpp,mm}`
- [loopy_engine_api.h](../../packages/loopy_engine/src/core/loopy_engine_api.h)
- [native_audio_engine.dart](../../packages/loopy_engine/lib/src/native_audio_engine.dart),
  [mock_audio_engine.dart](../../packages/loopy_engine/lib/src/mock_audio_engine.dart)
- [looper_bloc.dart](../../lib/looper/bloc/looper_bloc.dart),
  [signal_fx_rack.dart](../../lib/looper/view/signal_graph/signal_fx_rack.dart)

## Acceptance Criteria

- [ ] Open Editor opens the plugin's own window (VST3 + CLAP); resize works.
- [ ] **Window teardown:** closing the owning slot/lane/track/session, and quitting
  the app, closes all child editor windows with **zero leaked native windows**;
  removing a plugin with its editor open force-closes the window first.
- [ ] **Two-way sync:** a param change in the native editor is mirrored to the
  in-app knobs (≤10 Hz) and persisted on editor-close; an app knob change is
  reflected in the native editor; the close re-read runs after the queue drains.
- [ ] Multiple editors open at once behave independently; poll timer is disposed on
  close (no leaked timer); `MockAudioEngine` keeps `flutter test` green.

## Testing Strategy

- Native: window create/attach/detach leak check; resize callback.
- Dart: `bloc_test` editor open/close + poll-timer disposal; manual two-way sync +
  multi-editor + teardown matrix.

## Out of Scope

Opaque-state persistence + D-MISS (part 7); Windows HWND (part 8); Linux X11 (part 9).
</content>
