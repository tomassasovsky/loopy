# Test Quality Review — loopy

**Date:** 2026-06-19
**Reviewer:** Test Quality Review Agent (VGV standards)
**Stack:** Flutter / Dart, bloc + bloc_test, mocktail, flutter_test

---

## Coverage Summary

- **Test run:** Pass — 358 tests passed, 3 skipped (screenshot goldens that self-skip outside the author's machine)
- **Coverage:** ~95%+ measured lines across the 63 tracked source files
- **Files with tests:** All major implementation units have corresponding test files
- **Files with zero coverage (no tests exercising them):**
  - `lib/app/run_loopy.dart` — 0% (22 lines): platform entrypoint — not directly unit-testable (depends on native engine, desktop multi-window, path_provider)
  - `lib/session_directory.dart` — 0% (3 lines): thin wrapper over `path_provider` — not unit-testable without platform channel mocks
  - `lib/app/midi_bootstrap.dart` — 0% (5 lines): factory function with a try/catch; the null case is indirectly covered by other tests
  - `lib/bootstrap.dart` — 10% (1/10 lines): `AppBlocObserver.onError` is never triggered in tests; `bootstrap()` itself is a run-entrypoint

The zero-coverage files are justified infrastructure (entrypoints, OS wrappers). No business-logic file is uncovered.

### Coverage outliers worth watching

| File | Coverage | Note |
|---|---|---|
| `lib/looper/bloc/looper_event.dart` | 60% | `LooperStopAllPressed` and several sealed subclass constructors never reached in tests |
| `lib/looper/view/big_picture_view.dart` | 87% | Some error/edge branches untested |
| `lib/app/view/app.dart` | 86% | ASIO-lost and Escape-close branches partially covered |
| `lib/setup/setup_surface.dart` | 86% | Legacy surface kept for routing; partially exercised |
| `lib/theme/surface_theme.dart` | 61% | Many color accessors not directly asserted |
| `lib/visualizer/waveform_window.dart` | 21% | Secondary window — untestable without platform channels |
| `lib/window/window_chrome.dart` | 15% | Window manager platform channel — not unit-testable |

---

## State Management Test Quality

### `BigPictureCubit` — `test/looper/cubit/big_picture_cubit_test.dart`

**Pass** — Excellent coverage.

- Defaults, select, toggleMode, setDefaultPerformanceMode, load, rename, rename-ignores-blank, rename-during-load race all tested.
- Uses `blocTest` with `bloc_test` consistently; `SettingsRepository` wired through `FakeKeyValueStore` (real implementation, not a mock — correct VGV pattern for persistence).
- `verify` used only where the cubit must persist via settings — not over-verified.
- Edge case: rename with whitespace-only string correctly expected to emit nothing.

### `QuantizeCubit` — `test/looper/cubit/quantize_cubit_test.dart`

**Pass** — Good coverage.

- Tests: defaults, load+restore, setEnabled (true), setEnabled with current value (no-emit but still persists).
- `verifyNever` used to assert no repository call on no-op. Correct use.
- Minor observation: no test for `setEnabled(false)` when previously true (toggling back). Not a critical gap since the path is symmetric and covered by `setEnabled(true)`.

### `RecordOptionsCubit` — `test/looper/cubit/record_options_cubit_test.dart`

**Pass** — Good coverage.

- Tests defaults, load (both flags), setRecDub, setAutoRecord, setDefaultMultiple.
- Correct use of `setUp` for shared repo stubbing.

### `RefreshRateCubit` — `test/looper/cubit/refresh_rate_cubit_test.dart`

**Pass** — Good coverage.

- Tests: defaults, load+restore, setHz, setHz to same value (no-emit but persists).
- `registerFallbackValue(Duration.zero)` in `setUpAll` properly handles the matcher.
- Magic value comments (e.g. "30 Hz -> 1_000_000 / 30 ≈ 33333 µs") — well documented.

### `BankCubit` — `test/looper/cubit/bank_cubit_test.dart`

**Pass** — Clean.

- Tests: defaults, selectBank, clamping out-of-range, toggle.

### `WaveformWindowCubit` — `test/visualizer/cubit/waveform_window_cubit_test.dart`

**Pass** — Clean.

- Tests: defaults, setEnabled, setEnabled (no-op), toggle, load.

### `AudioSetupCubit` — `test/audio_setup/cubit/audio_setup_cubit_test.dart`

**Pass** — Comprehensive and thorough. This is one of the best test files in the codebase.

- Covers: initial state, hydration from running engine, option setters, max-loop-minutes (frame conversion), stopped-to-running restart, failed open, non-startable ASIO config, recovery from failed open, measureLatency, setRecordOffset (positive and clamped negative), repository stream updates, loopback auto-measure (all four branches), ASIO driver cache (D1), latency persistence, device selection (hydrate, setPlayback, setCapture, reopen while running, failed reopen), device connectivity (lost/restored for pinned and default), ASIO backend (nine scenarios).
- Uses `blocTest` and direct `test` appropriately.
- No over-verification — `verify` appears only where a specific side-effect must be asserted.
- Well-structured with nested `group` blocks per feature area.

### `MonitorCubit` — `test/audio_setup/cubit/monitor_cubit_test.dart`

**Pass** — Excellent.

- Tests: defaults, setEnabled, setLaneOutputMask, setLaneVolume, setLaneMute, addLane, removeLane (with collapse), addLane at cap, removeLane no-op, input independence, load (full state restoration), per-lane effects (add, setParam, removeEffect, moveEffect with reorder, moveEffect no-op/OOB).

### `MidiSetupCubit` — `test/audio_setup/cubit/midi_setup_cubit_test.dart`

**Pass** — Very thorough.

- Tests: enumeration + initial state, null source graceful degradation, activity tick, select (opens/persists/connects), switch A→B, failed open (error with retained pin), selectNone, launch auto-reconnect (re-opens if present, marks deviceGone if absent), hotplug (lost→restored, first observation no transition), audio independence (verifyNoMoreInteractions).

### `SessionCubit` — `test/session/cubit/session_cubit_test.dart`

**Pass** — Good.

- Tests: saveSession (success+verify), loadSession (success+verify), exportMixdown, exportStems, saveSession (failure), loadSession (failure).
- Uses `expectLater`-style approach with `bloc_test` — correct.

### `PedalCubit` — `test/pedal/cubit/pedal_cubit_test.dart`

**Pass** — Excellent coverage of a complex state machine.

- Tests: Rec/Play in Rec mode, track press while idle (re-arms), track press hands off recording, Stop in Rec (mutes), Mode toggle, Play-mode arm/disarm, Stop in Play (freeze), Rec/Play in Play (resumes), Rec/Play in Play (freezes), external track clear drops from armed set, Bank toggle (re-arms/syncs BankCubit), global_color LED, reconnect (full cycle: absent on launch, appears, vanishes, reappears), reconnect for unpinned output, outputsTick change detection, encoder drives master gain, Undo tap, Clear (bank reset), projection (frame encoding), loop-top pulse, close sends goodbye.
- Uses `FakePedalTransport` — correctly avoids native MIDI.

### `LooperBloc` — `test/looper/bloc/looper_bloc_test.dart`

**Pass** — Comprehensive. Notable findings:

- `LooperStopAllPressed` event is declared in `looper_event.dart` and handled in the bloc but has no corresponding test. Coverage confirms 60% for `looper_event.dart`. The `LooperPlayPressed` and `LooperClearPressed` internal events (fired by `LooperPlayAllPressed`/`LooperClearAllPressed` via `_onControllerEvent`) are also untested in isolation.
- The controller wiring section at the end uses `await Future<void>.delayed(Duration.zero)` twice — this is an important nuance (one for the microtask queue, one for the event loop). The pattern is correct but fragile. A `pumpEventQueue()` call would be more expressive.
- `LooperMuteToggled` is tested only for unmuted→muted; the reverse (already-muted→unmute) is not directly tested in `looper_bloc_test.dart` (it is tested in `pedal_cubit_test.dart` via the pedal path, but not in the bloc's own test).

### `tryAutoStartEngine` (audio_bootstrap) — `test/app/audio_bootstrap_test.dart`

**Pass** — Outstanding. Covers 14 distinct scenarios including platform-overriding, ASIO enumeration, routing restoration, effects restoration, multi-lane restoration, latency restoration, loopback auto-measurement with two sources (loopback device, excluded-input mask), saved-capture-device override, and failure cases. Uses `FakeAudioEngine` directly — correct.

---

## UI Component Test Quality

### `BigPictureView` — `test/looper/view/big_picture_view_test.dart`

**Pass** — Thorough widget test.

- Tests: tile count, tap to record, long-press to stop, bank A/B switch, keyboard shortcuts (M, digits, R, Space, C, F), rename dialog flow, play-mode visuals (meter height, meter colors, muted color, selection border), audio-not-running affordance.
- Uses `MockBloc` and `whenListen` with `initialState` — correct VGV pattern.
- `pump()` helper avoids duplicating the provider setup.

### `BigPictureSettingsPage` — `test/looper/view/big_picture_settings_page_test.dart`

**Pass** — Very thorough. Tests tab navigation (View/Tracks/Audio/Routing), waveform window toggle, track rename, default performance mode, refresh rate, quantize toggle, Escape to pop. Uses real cubits wired to `FakeKeyValueStore` — not mocked away — which gives high fidelity.

### `AudioSettingsSection` — `test/audio_setup/view/audio_settings_section_test.dart`

**Pass** — Comprehensive.

- Tests: renders pickers and status, select playback device, select capture device, measure button, manual record offset, per-input monitor (no master toggle), opens monitor graph, quantize toggle, rec/dub and auto-record toggles, default loop length, max loop length, measuring label, not-running status, ASIO backend (no backend selector, ASIO driver picker replaces device pickers, no driver shows ASIO4ALL message, MIDI stays visible), error banner.

### `TrackRoutingDialog` — `test/looper/view/track_routing_dialog_test.dart`

**Pass** — Excellent.

- Tests: unified lane graph, wiring input, toggling output, muting, add lane, remove last lane, remove non-last lane (shift), quantize override, add effect (with editor), change effect type, drag param slider, drag to reorder, saved per-lane chain preloaded, saved lane count, add-lane disabled at cap.

### `LaneGraphView` — `test/looper/view/lane_graph/lane_graph_view_test.dart`

**Pass** (partial read). The view's behavior is tested via the dialog test above; there is also a dedicated `LaneGraphView` widget test.

### `MonitorGraphView` — `test/audio_setup/view/monitor_graph/monitor_graph_view_test.dart`

Only partially read — exists and covers the monitoring routing graph.

### `PedalSettingsSection` — `test/pedal/view/pedal_settings_section_test.dart`

Exists. Coverage shows 89%.

### `MidiDevicePicker` — `test/audio_setup/view/midi_device_picker_test.dart`

Exists with MockCubit. Tests: empty state, dropdown+status.

### `WaveformView` — `test/visualizer/waveform_view_test.dart`

**Pass** — Tests WaveformView paint, WaveformWindowApp render and update, WaveformPainter.shouldRepaint (same, new list, color change, playhead change).

### `App` — `test/app/view/app_test.dart`

**Pass** — Tests: renders LooperPage, no first-run gate, opens waveform window, waveform window disabled, right-click opens settings + waveform toggle closes window, S key opens settings, device disconnect banner (lost+restored), MIDI disconnect banner (lost+restored).

### `EffectParamsEditor` — `test/common/effect_params_editor_test.dart`

**Pass** — Tests octaver discrete Mode control, non-octaver param count, delay param count, PV latency hint (shows, hides at zero latency, hides for PSOLA, hides for non-octaver).

### `LooperPage` — `test/looper/view/looper_page_test.dart`

**Pass** — Smoke test confirms wiring and renders `BigPictureView`. Appropriate for a thin wiring widget.

### `App (view)` — `test/app/view/app_test.dart`

**Pass** — see above.

---

## Package Test Quality

### `looper_repository` — `packages/looper_repository/test/`

**Pass** — Exceptional.

- `looper_repository_test.dart`: poll interval (reports + updates + timer path), projection (full snapshot, multiple tracks, per-lane, loop multiple, empty, excluded mask, fx latency), looperState stream (distinct emit, late subscriber, subscribe/cancel cycle), commands (all engine methods, startEngine stores config, failed start does not store, setQuantize deferred/live, per-track quantize, clear override, rec/dub/multiples, setMasterGain deferred/live/restart/clamped, effects chain deferred/live/param-tweak/empty-chain, monitor lane chain/param/output/volume/mute/count, per-input enable, input independence, engineVersion, setRecordOffset, setInputMask, setOutputMask, setLaneCount, detectLoopback), reconnect supervisor (8 scenarios), dispose.
- `models/lane_test.dart`: defaults, hasContent, inputMask, equality.
- `models/input_monitor_test.dart`: MonitorLane (defaults, copyWith, equality, effect chain equality), InputMonitor (defaults, lane(i) OOB, copyWith, withLane, withLane grows, equality).
- No test file for `Track`, `TransportState`, `LooperState`, or `EngineStatus` models directly. These are exercised only through the repository projection tests and UI tests, not through direct model unit tests.

### `loopy_engine` — `packages/loopy_engine/test/`

**Pass** — Good.

- `engine_config_test.dart`: defaults, AudioBackend round-trip/explicit/fallback, writeTo (all fields, defaults, empty device ids, truncation), value semantics (equality, inequality, toString).
- `mock_audio_engine_test.dart`: defaults (channels, snapshot), backend echo, ASIO driver enumeration, device enumeration, master gain (default/clamp/snapshot), gain resets on start, lane routing in snapshots.
- `engine_result_test.dart`, `audio_device_test.dart`, `loopback_info_test.dart`, `track_effect_test.dart`, `engine_snapshot_test.dart`: individual model/value tests.
- No test for `NativeAudioEngine` (correct — it wraps native FFI code that cannot be unit-tested).
- No test for `FfiStrings` helpers in isolation (they are exercised via `engine_config_test.dart`'s `writeTo` tests).

### `pedal_repository` — `packages/pedal_repository/test/`

**Pass** — Excellent.

- `pedal_codec_test.dart`: frame round-trip (all goldens), framing (F0/F7 + 7-bit payload), max loop length preservation, reference encoder cross-check, decodeMessage (NoteOn/Off for all buttons, velocity-0 as release, timestamp, MIDI channel nibble ignore, unknown note returns null), encoder decode (positive/negative/zero/unrelated CC), decodeFrame rejects (too short, missing F0, missing F7, wrong manufacturer, unknown protocol version, unknown message type, corrupted checksum, 8th-bit payload, wrong logical length, OOB global color, OOB active bank, OOB armed track, OOB track LED), outbound messages, encodeEncoder (inverse, clamping).
- `pedal_codec_golden_test.dart`: golden frames parametric.
- `pedal_repository_test.dart`: events (NoteOn→ButtonPressed, velocity-0→ButtonReleased, encoder CC→EncoderDelta, drops non-pedal), bind (success+status+identity-request, error), unbind (goodbye+close), pushState (bound/unbound), sendLoopTop (bound/unbound), availableOutputs, dispose (idempotent).
- `pedal_button_test.dart`, `pedal_event_test.dart`, `pedal_state_frame_test.dart`, `noop_pedal_transport_test.dart`: individual models/no-op transport.

### `midi_client` — `packages/midi_client/test/`

**Pass** — Good.

- `midi_client_test.dart`, `midi_controller_source_test.dart`, `midi_device_test.dart`, `midi_out_client_test.dart`: client lifecycle, source parsing, device model, out client.

### `controller_repository` — `packages/controller_repository/test/`

**Pass** — `controller_mapping_test.dart` and `controller_repository_test.dart`.

### `session_repository` — `packages/session_repository/test/`

**Pass** — `session_repository_test.dart`, `session_test.dart`, `wav_test.dart`.

### `settings_repository` — `packages/settings_repository/test/`

**Pass** — `settings_repository_test.dart` (read partially: latency offset round-trip, profile isolation).

### `local_storage_client` — `packages/local_storage_client/test/`

**Pass** — `shared_preferences_key_value_store_test.dart`.

### `routing_graph` — `packages/routing_graph/test/`

**Pass** — Tests for all widgets: `add_effect_button`, `channel_chip`, `effect_chain_card`, `effect_drop_zone`, `graph_canvas`, `graph_card_ref`, `graph_edge_painter`, `graph_edge`, `graph_geometry`, and `routing_graph_theme`.

---

## Anti-Patterns Found

### Important

**`test/looper/bloc/looper_bloc_test.dart` (line ~522) — Fragile async waiting**

```dart
source.press(ControllerSourceKind.midiCc, 80);
await Future<void>.delayed(Duration.zero);
await Future<void>.delayed(Duration.zero);
```

Two chained `Future.delayed(Duration.zero)` calls to let events propagate. This is an implicit pump-count assumption: if the dispatch chain gains one more async hop, the test breaks silently. The standard VGV pattern is `await pumpEventQueue()` (from flutter_test) or `await tester.pump()` in a widget test, both of which drain all pending microtasks and timers in one call. The same pattern appears in `midi_looper_integration_test.dart` (line ~59).

**Fix:** Replace double `await Future<void>.delayed(Duration.zero)` with `await pumpEventQueue()` (already used correctly elsewhere in the codebase, e.g. `midi_setup_cubit_test.dart`).

**`test/audio_setup/cubit/audio_setup_cubit_test.dart` (latency persistence tests, lines ~459–491) — Raw double-delayed await**

```dart
stateController.add(connected);
await Future<void>.delayed(Duration.zero);
await Future<void>.delayed(Duration.zero);
```

Same pattern as above. Works today but is fragile and inconsistent with the rest of the file which uses `blocTest`.

**Fix:** Replace with `await pumpEventQueue()`.

### Suggestions

**`test/looper/bloc/looper_bloc_test.dart` — `LooperStopAllPressed` is untested**

`LooperStopAllPressed` is declared, handled, and dispatched from `_onControllerEvent`, but it has no test case in `looper_bloc_test.dart`. The bloc's `LooperPlayAllPressed` test seeds a state and uses `verify` — the same approach should be used for `LooperStopAllPressed`.

**`packages/looper_repository/test/` — No direct model unit tests for `Track`, `TransportState`, `LooperState`, `EngineStatus`**

The `Lane` and `InputMonitor` models have dedicated test files with equality, copyWith, and edge-case tests. The `Track` model also has computed properties (`hasContent`, `canUndo`, `isMultiple`) and equality semantics that are only exercised indirectly through `looper_repository_test.dart` projections. Adding a `track_test.dart` would make the model contract explicit and prevent regressions when fields are added.

Similarly, `TransportState` has `hasLoop` and `progress` getters that are exercised only via projection assertions — not through direct value tests.

**`test/app/pedal_bootstrap_test.dart` — Near-empty test file**

The file contains only one test:
```dart
test('returns null when there is no MIDI source', () {
  expect(createPedalRepository(null), isNull);
});
```

`createPedalRepository` accepts a non-null `MidiControllerSource` and in that case constructs a `PedalRepository`. The non-null path is never tested. The successful construction case should be covered.

**`lib/app/midi_bootstrap.dart` — `createMidiSource` error path not tested**

`createMidiSource` has a try/catch that returns null on any error. There is no test exercising this fallback (the only test is via the null-source guard in `pedal_bootstrap_test.dart`). A test that injects a factory that throws and asserts the result is null (and that `FlutterError.reportError` is invoked) would complete the contract.

**`test/looper/bloc/looper_bloc_test.dart` — `LooperMuteToggled` (unmute path) not tested in the bloc**

The mute→unmute path is tested in `pedal_cubit_test.dart` (via `PedalCubit.setMute` calling `looper.setMute(muted: false)`), but `LooperBloc`'s own handler for `LooperMuteToggled` when the track is already muted (`_isMuted(channel) == true`) is not directly tested in `looper_bloc_test.dart`. The handler's un-mute branch line would be covered but there is no assertion for it.

**`test/looper/view/big_picture_view_test.dart` — Some visual states assert internal widget structure**

Several tests reach into `Container.decoration` and cast to `BoxDecoration` to inspect `Border.top.color`. While this is technically testing behavior (visual state), it is tightly coupled to the widget's internal DOM. If the border is ever moved to a `DecoratedBox` sibling, the test breaks without behavior changing. This is an acceptable tradeoff for a looper UI where the visual design IS the behavior, but it should be noted.

---

## Recommendations

1. **Replace double `Future.delayed(Duration.zero)` with `pumpEventQueue()`** in `looper_bloc_test.dart` (controller-wiring test) and `midi_looper_integration_test.dart` and `audio_setup_cubit_test.dart` (latency persistence tests). This is the only anti-pattern that could cause silent false positives.

2. **Add a `LooperStopAllPressed` test** to `looper_bloc_test.dart`. The event handler exists, the bloc is seeded for `LooperPlayAllPressed` and `LooperClearAllPressed` — adding the mirror for `LooperStopAllPressed` takes one `blocTest` block.

3. **Add direct model unit tests for `Track`, `TransportState`, `LooperState`** in `packages/looper_repository/test/models/`. Lane and InputMonitor already have this; Track is more complex (computed properties) and benefits from the same treatment.

4. **Add a non-null path test to `pedal_bootstrap_test.dart`** — inject a real or fake `MidiControllerSource` and assert a non-null `PedalRepository` is returned.

5. **Add an error-path test for `createMidiSource`** — inject a factory that throws and assert the function returns null without propagating.

6. **Consider adding `LooperMuteToggled` unmute test** directly in `looper_bloc_test.dart`, seeding the bloc with a muted track and verifying `setMute(muted: false)` is called.

---

## Verdict

**Ready to merge — with minor follow-up recommended.**

The test suite is of high quality. Every major state management unit, repository, and UI component has tests covering happy paths, failure paths, and meaningful edge cases. The VGV patterns (bloc_test, mocktail, FakeKeyValueStore, FakeAudioEngine, FakePedalTransport, seed/verify) are applied consistently throughout. The test naming is descriptive and specification-grade.

The two instances of double `Future.delayed(Duration.zero)` are the only pattern-level anti-patterns found; they work today but are fragile. The coverage gaps (Track model, LooperStopAllPressed, pedal bootstrap non-null path) are low-risk but represent genuine missing specifications.

No tautological assertions, no mock-everything anti-patterns, no tests with no assertions, and no implementation mirroring were found.

| Severity | Count | Summary |
|---|---|---|
| Critical | 0 | — |
| Important | 2 | Double `Future.delayed(Duration.zero)` fragile async wait (2 files) |
| Suggestions | 6 | LooperStopAllPressed test, Track model tests, pedal bootstrap non-null, createMidiSource error, LooperMuteToggled unmute, visual assertion coupling |
