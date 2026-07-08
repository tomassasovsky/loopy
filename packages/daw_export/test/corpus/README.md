# Corpus: Live 12 reference projects

Parts 9-10 of the performance-recording / DAW-export umbrella
(`docs/plan/2026-07-05-feat-performance-recording-daw-export-plan.md`)
are meant to be developed against a committed corpus of **minimal Ableton
Live 12 projects, actually saved from Live 12 itself** — a "save from Live,
diff the XML" methodology: create the smallest possible project exercising
one structural feature at a time (one audio track with an arrangement
clip; one audio track with a session-view clip; a project with two tracks;
a project with the tempo changed from the 120 default; a track with mixer
volume automation; a track with activator/mute automation; etc.), save it,
inspect the resulting `.als`'s decompressed XML, and use that as the ground
truth the generator's output is diffed against.

## Status: not yet populated

**This corpus does not exist yet.** Building it requires an actual Ableton
Live 12 installation, which was not available while implementing either
part. Instead, `als_builder.dart` was built from documented/public knowledge
of the Live Set XML format (gzipped XML; `Id`/`PointeeId` cross-references;
`AudioTrack`/`MainTrack` structure; tempo as a `Manual` value plus an
automation envelope targeting the main track's tempo pointee; part 10 adds
per-track `Volume`/`TrackActivator` mixer entries with their own
`AutomationTarget`/`AutomationEnvelope` pairs, `FloatEvent`-based continuous
ramps for volume and `BoolEvent`-based steps for the activator) — every
structural guarantee this part's own test suite can enforce without a real
reference file (Id/Pointee consistency, relative-only `FileRef`s, warp off
on every clip, correct beat-position math at 120 BPM, one track per
non-empty input, one session clip per lane, envelope Id/PointeeId wiring,
step-vs-ramp event shape) is implemented and tested in
`test/als_builder_test.dart`, but the *exact* element/attribute set Live 12
itself expects has not been verified against a real save.

## Follow-up (needs Ableton Live 12)

1. In Live 12, create and save a few minimal projects, each isolating one
   structural feature:
   - one audio track, one arrangement-view clip, tempo left at the project
     default;
   - one audio track, one session-view (clip-slot) clip;
   - two audio tracks;
   - a project with a non-default tempo;
   - a track with a mixer-volume automation ramp (part 10) — verify the
     exact envelope shape Live expects for a continuous `FloatEvent` curve;
   - a track with its Activator toggled off then on partway through (part
     10) — verify Live's actual step/`BoolEvent` representation for a mute
     toggle, since D-MUTE's whole premise (no native mute automation) rests
     on this being the closest available mechanism.
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
5. Manual gate (per parts 9-10's acceptance criteria): open a generated
   fixture project in Live 12 and confirm — no missing-file dialog, correct
   track/clip layout, that moving the whole capture folder keeps every
   reference resolving, and (part 10) that volume/activator automation is
   visibly present and correct on the timeline. Record the outcome in the
   PR that adds real corpus files.

Until this happens, treat `als_builder.dart`'s exact XML schema as
best-effort, not verified-correct — this file exists so that gap is never
silently forgotten.
