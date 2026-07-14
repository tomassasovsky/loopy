# fix: correct inaccurate mh_dylib comment in loopy_engine.podspec

Brainstorm: `docs/brainstorm/2026-07-13-podspec-mh-dylib-comment-fix-brainstorm-doc.md`

## Problem

`packages/loopy_engine/macos/loopy_engine.podspec` (lines ~33-39) documents
`MACH_O_TYPE => 'mh_dylib'` with a comment claiming FFI symbols are "resolved
at runtime via `DynamicLibrary.open('loopy_engine.framework/loopy_engine')`".

That's not what happens. `_openLibrary()` in
`packages/loopy_engine/lib/src/native_audio_engine.dart` (lines 34-44) always
uses `DynamicLibrary.process()` on macOS/iOS — dlopen(NULL) semantics against
the process's global symbol namespace — and that file's own comment says
"there is no standalone library file to open". A maintainer debugging a
symbol-not-found issue who trusts only the podspec comment would be pointed
at the wrong mechanism.

This is a docs-only drift fix. The `MACH_O_TYPE => 'mh_dylib'` setting is
correct and must not change — only the prose explaining it is wrong.

## Scope

- **In scope**: rewrite the comment block at
  `packages/loopy_engine/macos/loopy_engine.podspec` lines ~33-39 (the prose
  above/around `'MACH_O_TYPE' => 'mh_dylib'`) so it accurately describes that
  symbols are found via `DynamicLibrary.process()` (dlopen(NULL) / global
  process symbol visibility), not a path-based `DynamicLibrary.open()`.
- **Out of scope**: the `MACH_O_TYPE` value itself, every other line/comment
  in the podspec, `native_audio_engine.dart`, and any other file. This is 1 of
  21 fixes being applied in parallel isolated worktrees — other findings are
  owned by other agents.

## Implementation

### Step 1 — Rewrite the comment

Replace the existing comment (currently lines 33-39):

```ruby
    # Build as a dynamic library so the produced framework binary is a loadable
    # Mach-O dylib. Flutter/CocoaPods default plugin frameworks to static
    # (MACH_O_TYPE=staticlib); that works for normal plugins (reached via the
    # registrant) but breaks FFI plugins, whose symbols are only resolved at
    # runtime via DynamicLibrary.open('loopy_engine.framework/loopy_engine').
    # A static framework's binary is an ar archive that dlopen cannot load, and
    # its symbols get dead-stripped since nothing references them at link time.
```

with prose that:

1. Keeps the correct rationale: default static (`staticlib`) framework binary
   is an ar archive — not dlopen-loadable, and its symbols would be
   dead-stripped since nothing references them at link time.
2. Corrects the loading mechanism: the Dart side loads native symbols via
   `DynamicLibrary.process()` (dlopen(NULL) semantics against the process's
   global symbol table) — see `_openLibrary()` in
   `packages/loopy_engine/lib/src/native_audio_engine.dart` — not a
   path-based `DynamicLibrary.open(...)` on the framework binary.
3. Ties the two together: `mh_dylib` is what makes the framework's symbols
   dynamically loaded and globally visible in the host process in the first
   place, which is what `DynamicLibrary.process()` depends on to find them.

Suggested replacement text:

```ruby
    # Build as a dynamic library so the produced framework binary is a loadable
    # Mach-O dylib. Flutter/CocoaPods default plugin frameworks to static
    # (MACH_O_TYPE=staticlib); that works for normal plugins (reached via the
    # registrant) but breaks FFI plugins. A static framework's binary is an ar
    # archive that dlopen cannot load, and its symbols get dead-stripped since
    # nothing references them at link time.
    #
    # The Dart side never opens the framework by path: _openLibrary() in
    # native_audio_engine.dart uses DynamicLibrary.process() (dlopen(NULL)
    # semantics) to resolve symbols from the host process's global namespace.
    # That only works because MACH_O_TYPE=mh_dylib makes this framework's
    # binary a real dylib whose symbols are dynamically loaded and exported
    # into that global namespace at launch, instead of being buried in a
    # static archive.
```

### Step 2 — Verify no other references need updating

Confirm (already checked during brainstorm via repo-wide grep) that no other
file references the old `DynamicLibrary.open('loopy_engine.framework/...')`
claim. No other edits expected.

## Success Criteria

- [ ] `MACH_O_TYPE => 'mh_dylib'` line is byte-for-byte unchanged.
      verify: `git diff --unified=0 packages/loopy_engine/macos/loopy_engine.podspec | grep -c "MACH_O_TYPE"` returns `0` (i.e., that line does not appear in the diff hunks — confirming it wasn't touched)
- [ ] The podspec no longer contains the phrase `DynamicLibrary.open('loopy_engine.framework`.
      verify: `! grep -q "DynamicLibrary.open('loopy_engine.framework" packages/loopy_engine/macos/loopy_engine.podspec`
- [ ] The podspec comment references `DynamicLibrary.process()` and/or `native_audio_engine.dart`, aligning it with the real loading mechanism.
      verify: `grep -q "DynamicLibrary.process" packages/loopy_engine/macos/loopy_engine.podspec`
- [ ] No other files changed.
      verify: `git diff --stat | grep -v "loopy_engine.podspec" | grep -v "^ [0-9]* files\? changed" | grep -c . ` — expect only the podspec (and this plan/brainstorm doc) in the diff stat; manual check: `git status --short` shows only the podspec, brainstorm doc, and plan doc as changed/untracked.
- [ ] Podspec remains syntactically valid Ruby (CocoaPods podspecs are plain Ruby).
      verify: `ruby -c packages/loopy_engine/macos/loopy_engine.podspec`

## Risks

None of note — this is a comment-only change in a file that isn't executed
as code beyond CocoaPods parsing it as Ruby syntax, which is covered by the
`ruby -c` syntax-check criterion above.
