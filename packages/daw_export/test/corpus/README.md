# Corpus: Live 12 reference projects

Parts 9-10 of the performance-recording / DAW-export umbrella
(`docs/plan/2026-07-05-feat-performance-recording-daw-export-plan.md`) and
part 10 of the [Loopy FX as VST3 plugins](../../../../docs/plan/2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
umbrella are meant to be developed against a committed corpus of **minimal
Ableton Live 12 projects, actually saved from Live 12 itself** — a "save
from Live, diff the XML" methodology: create the smallest possible project
exercising one structural feature at a time (one audio track with an
arrangement clip; one audio track with a session-view clip; a project with
two tracks; a project with the tempo changed from the 120 default; a track
with mixer volume automation; a track with activator/mute automation; a
track with one or more Loopy VST3 plugins loaded as devices; etc.), save
it, inspect the resulting `.als`'s decompressed XML, and use that as the
ground truth the generator's output is diffed against.

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

## Part 10: real device-chain XML (HIGH PRIORITY — needs Ableton Live 12 + all seven Loopy VST3 plugins installed)

Part 10 ([Loopy FX as VST3 plugins](../../../../docs/plan/2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
umbrella) adds `als_builder.dart`'s first-ever device-XML emission
(`_deviceChainXml`): one `<Vst3PluginDevice>` block per resolved chain
entry, referencing the plugin by its permanent class GUID
(`loopy_vst3_plugins.dart`). **This is the single least-verified piece of
XML in this entire package** — meaningfully more uncertain than the
tempo/clip/automation XML above. Those are extensively documented in public
Live-Set-format reverse-engineering writeups; a hosted-VST3 device's exact
element/attribute names are not. `_deviceChainXml`'s shape (`On`/
`AutomationTarget`, `ParametersListWrapper`/`Parameters`/
`PluginFloatParameter`, `PluginDesc`/`Vst3PluginInfo`/`Uid`) is a best-effort
reconstruction following the same `Manual`+`AutomationTarget` pattern this
file's own Volume/Tempo/TrackActivator blocks already use — **not** a
transcription of anything independently confirmed.

Follow-up, in addition to the base-feature list above:

1. Build all seven Loopy VST3 plugins (`packages/loopy_engine/vst3/`, parts
   2, 3, 5-9) and install them locally
   (`-DLOOPY_VST3_DEV_INSTALL=ON`).
2. In Live 12, insert a single Loopy plugin (e.g. "Loopy Delay") on one
   audio track, tweak its params away from default, save.
3. Insert a chain of 2-3 Loopy plugins on a second track (order matters —
   this is the multi-effect case `_deviceChainXml` needs to get right),
   save.
4. Copy both `.als` files into this directory, decompress, and diff against
   `_deviceChainXml`'s actual output for an equivalent fixture `DawTrack`.
   Reconcile every structural difference — element names, attribute names,
   nesting order relative to `<Mixer>`/`<MainSequencer>`, how Live encodes a
   VST3 class id (this file assumes a 32-hex-char `Uid Value="..."`, itself
   unverified), and how it maps a plugin's own `RangeParameter`/
   `StringListParameter` index to the parameter values it persists.
5. Manual gate (part 10's own acceptance criteria): open a generated
   fixture project with a resolved device chain in Live 12 and confirm the
   correct Loopy plugin(s) load (not offline/missing), with parameter
   values matching what was played, and audio sounding correct through the
   live chain (not literally identical samples to the old wet-bounce
   export, since the arrangement clip is now the dry stem — the
   golden-parity harness from the VST3-plugins umbrella's parts 4/6/9
   already proves the live device reproduces the same DSP bit-exactly).

Until this happens, treat `_deviceChainXml`'s exact XML schema as
unverified guesswork with a plausible structural shape, not best-effort —
a stronger caveat than the rest of this file's "best-effort, not
verified-correct," since even the general vocabulary (element names) here
is uncertain, not just fine details like attribute ordering.
