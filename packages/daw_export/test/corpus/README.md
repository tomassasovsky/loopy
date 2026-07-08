# Corpus: Live 12 reference projects

Part 9 of the performance-recording / DAW-export umbrella
(`docs/plan/2026-07-05-feat-performance-recording-daw-export-plan.md`)
is meant to be developed against a committed corpus of **minimal Ableton
Live 12 projects, actually saved from Live 12 itself** — a "save from Live,
diff the XML" methodology: create the smallest possible project exercising
one structural feature at a time (one audio track with an arrangement
clip; one audio track with a session-view clip; a project with two tracks;
a project with the tempo changed from the 120 default; etc.), save it,
inspect the resulting `.als`'s decompressed XML, and use that as the ground
truth the generator's output is diffed against.

## Status: not yet populated

**This corpus does not exist yet.** Building it requires an actual Ableton
Live 12 installation, which was not available while implementing this part.
Instead, `als_builder.dart` was built from documented/public knowledge of
the Live Set XML format (gzipped XML; `Id`/`PointeeId` cross-references;
`AudioTrack`/`MainTrack` structure; tempo as a `Manual` value plus an
automation envelope targeting the main track's tempo pointee) — every
structural guarantee this part's own test suite can enforce without a real
reference file (Id/Pointee consistency, relative-only `FileRef`s, warp off
on every clip, correct beat-position math at 120 BPM, one track per
non-empty input, one session clip per lane) is implemented and tested in
`test/als_builder_test.dart`, but the *exact* element/attribute set Live 12
itself expects has not been verified against a real save.

## Follow-up (needs Ableton Live 12)

1. In Live 12, create and save a few minimal projects, each isolating one
   structural feature:
   - one audio track, one arrangement-view clip, tempo left at the project
     default;
   - one audio track, one session-view (clip-slot) clip;
   - two audio tracks;
   - a project with a non-default tempo.
2. Copy each `.als` into this directory (e.g. `corpus/one_track_arrangement.als`).
3. Decompress each (`gzip -dc project.als > project.xml`) and diff the
   result against what `buildAls` emits for an equivalent fixture
   `DawProject` — reconcile any structural difference in `als_builder.dart`
   (element names/order, attribute names, the exact tempo-automation
   wiring, any Live-version-specific fields this implementation is
   currently missing).
4. Record the Live 12 version used (Preferences → About, or the `.als`'s own
   `Creator`/`MinorVersion` attributes) at the top of this file once real
   corpus files land.
5. Manual gate (per the plan's acceptance criteria): open a generated
   fixture project in Live 12 and confirm — no missing-file dialog, correct
   track/clip layout, and that moving the whole capture folder keeps every
   reference resolving. Record the outcome in the PR that adds real corpus
   files.

Until this happens, treat `als_builder.dart`'s exact XML schema as
best-effort, not verified-correct — this file exists so that gap is never
silently forgotten.
