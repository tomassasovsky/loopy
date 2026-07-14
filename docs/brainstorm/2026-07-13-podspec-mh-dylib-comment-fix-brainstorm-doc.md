# Brainstorm: Fix inaccurate MACH_O_TYPE=mh_dylib comment in loopy_engine.podspec

Date: 2026-07-13
Status: autonomous fix (1 of 21 parallelized code-review fixes across isolated worktrees; no live user for this run — proceeding on documented assumptions per task instructions)

## Problem

`packages/loopy_engine/macos/loopy_engine.podspec` (lines ~33-39) explains the
`MACH_O_TYPE => 'mh_dylib'` setting with a comment claiming FFI symbols are
"resolved at runtime via `DynamicLibrary.open('loopy_engine.framework/loopy_engine')`".

That is not how the Dart layer works. `_openLibrary()` in
`packages/loopy_engine/lib/src/native_audio_engine.dart` always returns
`DynamicLibrary.process()` on macOS/iOS:

```dart
if (Platform.isMacOS || Platform.isIOS) {
  return DynamicLibrary.process();
}
```

with its own comment stating "there is no standalone library file to open".
A repo-wide grep for the literal string `loopy_engine.framework` (excluding
worktrees/build) confirms the podspec comment is the only place this path-based
`DynamicLibrary.open` claim appears — it doesn't reflect any real code path.

This is pure docs-drift: a maintainer debugging a symbol-not-found issue who
reads only the podspec would be pointed at the wrong mechanism
(path-based dlopen) instead of the real one (process-wide symbol visibility
via dlopen(NULL) / `DynamicLibrary.process()`).

## What must NOT change

- The `MACH_O_TYPE => 'mh_dylib'` setting itself. It is correct and necessary:
  a static archive (CocoaPods' default `staticlib` for plugin frameworks)
  isn't dlopen-loadable and its symbols get dead-stripped since nothing
  references them at link time. Only the prose explaining *why* is wrong.
- Every other line in the podspec and the rest of the repo. This is 1 of 21
  independently parallelized fixes from a multi-agent review pass; other
  agents in other worktrees own the other findings.

## Approach

Single approach — there's no real design space here, just accurate technical
writing:

**Rewrite the comment block (lines ~33-39) to describe the real mechanism.**

New comment should say, in effect:
- Build as a dynamic library so the framework binary is a loadable Mach-O
  dylib.
- Flutter/CocoaPods defaults plugin frameworks to static
  (`MACH_O_TYPE=staticlib`); fine for normal plugins reached via the
  registrant, but wrong for FFI plugins.
- The Dart side loads native symbols via `DynamicLibrary.process()`
  (dlopen(NULL) semantics) rather than opening the framework binary by path —
  see `native_audio_engine.dart`'s `_openLibrary()`. That only works if the
  framework's symbols are dynamically loaded into and globally visible within
  the host process's namespace.
- A static archive can't be dlopen-loaded at all, and its symbols would be
  dead-stripped at link time since nothing references them directly — hence
  `mh_dylib` is required even though nothing calls `dlopen()` on a path.

This keeps the explanation of *why* `mh_dylib` matters (dead-stripping /
non-loadability of a static archive) but corrects the *how symbols are found*
part to match `DynamicLibrary.process()` reality, and cross-references the
Dart file so the two comments stay aligned for future readers.

## Assumptions (documented, since no live user to confirm)

1. Comment-only change; no code/build-setting change. Confirmed necessary by
   the issue's own "Suggested fix direction" and severity (low, docs-drift).
2. It's fine and helpful to name the specific Dart file/function
   (`native_audio_engine.dart`'s `_openLibrary()`) in the podspec comment as a
   cross-reference, so future edits to one side prompt a check of the other.
3. Scope stays to lines ~33-39 (the `mh_dylib` comment block) only — no other
   podspec comments (e.g. the `Classes/` forwarder comment near the top) are
   touched, since they aren't part of this finding.
4. No tests are needed/possible for a comment change; verification is just
   "read the diff, confirm it doesn't contradict native_audio_engine.dart, and
   confirm `MACH_O_TYPE` line is untouched."

## Next step

Proceed to `/plan` to turn this into a concrete (trivial) implementation plan.
