## VGV Code Review

**Scope**: `feat/console-log-and-audio-pin` vs `master` — AppLog rotating logfile, bootstrap wiring, `pickConsoleAudioDevices` / console auto-pin, `loopy-kiosk-launch` mkdir, `docs/RUNNING_ON_RPI.md`. (Excludes unrelated branch commits: pedal plan docs #332, CI chmod #330.)

### Summary

Solid, well-scoped feature work with good layering (`console_audio_devices.dart` pure helper), injectable `consoleMode` for tests, and meaningful unit coverage for the picker and happy-path pin/heal. Not merge-ready without fixing the latency auto-measure guard, which was updated for `useLoopbackCapture` but left inconsistent for `measureLatency` — that breaks the same invariant an existing test documents for saved capture pins. A couple of resilience gaps (no first-run fallback; error handlers that always “handle”) are worth tightening on an appliance build.

### 🔴 Critical — Must Fix Before Merge

- **`lib/app/audio_bootstrap.dart:182`** — Console empty-id heal pins `captureId` but latency auto-measure still keys off `saved.captureDeviceId.isEmpty`.
  - Why: `useLoopbackCapture` correctly uses `captureId.isEmpty` (line 122), so heal disables loopback capture; the `else if` at 182 still sees the pre-heal empty saved id and can call `measureLatency()` on PipeWire / auto-routable hosts. That chirps / measures on a path the existing test (“saved capture device wins over loopback”) says must be skipped when capture is pinned.
  - Fix: Use the effective id — `captureId.isEmpty` (same as `useLoopbackCapture`). Add a test: console heal + routable loopback → `useLoopbackCapture == false`, `measureLatencyCalls == 0`.

### 🟡 Important — Should Fix

- **`lib/app/audio_bootstrap.dart:333-338`** — Console first-run: if `pickConsoleAudioDevices` returns ids but `startEngine` fails, there is no fallback to system default; the app lands stopped.
  - Why: Pre-change first-run always opened the default. Enumeration ≠ openable (permissions, busy device). Console boot becomes more brittle.
  - Fix: On open failure after a console pick, retry `EngineConfig()` (empty ids), log the fallback, and persist whatever actually started (or leave unsaved if both fail).

- **`lib/bootstrap.dart:56-58`** — `PlatformDispatcher.instance.onError` always returns `true`, and startup runs under `runZonedGuarded`.
  - Why: Uncaught async/platform errors are logged and treated as handled; the process may stay alive in a bad UI state instead of exiting for systemd `Restart=`. Previous bootstrap did not swallow these.
  - Fix: Return `false` (or rethrow after log) for fatal cases, or document + align with `loopy.service` restart policy; at minimum don’t claim “handled” unless the appliance intentionally wants soft-fail.

- **`test/app/audio_bootstrap_test.dart` (console heal group)** — Heal tests omit the loopback / measureLatency interaction.
  - Why: The critical inconsistency above would have been caught by extending the existing loopback invariant test to `consoleMode: true` empty-id heal.
  - Fix: Add the case described under Critical.

### 🔵 Suggestions — Nice to Have

- **`lib/logging/app_log.dart:81`** — Rotation uses `file.lengthSync()` (bytes) + `bytes.length` (Dart string length).
  - Suggestion: Compare UTF-8 byte length (`utf8.encode(bytes).length` or `File` write via bytes) so multi-byte messages don’t delay rotation.

- **`lib/logging/app_log.dart:68`** — `developer.log` maps only `'E'` to level 1000; warn/info both use 0.
  - Suggestion: Map `'W'` to a distinct level (e.g. 900) for tooling filters.

- **`lib/control/cubit/control_cubit.dart:782-788`** — Pedal `_log` mirrors to `AppLog` with sync `flush: true` (encoders excluded — good).
  - Suggestion: Acceptable at pedal rates; if the log ever grows noisier, gate with `kConsoleMode` or a sampling flag rather than flushing every press.

- **`test/logging/app_log_test.dart`** — Rotation test covers `.1` only.
  - Suggestion: One case that drops `.2` when `rotatedCount` is exceeded.

### Simplicity Assessment

- Lines that could be removed: ~0 in feature logic; logging volume in `audio_bootstrap` is a bit chatty but justified for appliance breadcrumbing.
- Unnecessary abstractions: None — `pickConsoleAudioDevices` + typedef earn their keep; static `AppLog` is pragmatic for bootstrap.
- YAGNI violations: None material.
- Complexity verdict: Already minimal; fix the one inconsistent condition rather than adding structure.

### Testing Assessment

- New code with tests: ✅ `AppLog`, `pickConsoleAudioDevices`, console first-run pin, empty-id heal happy path.
- Test quality: Meaningful for picker edge cases; heal path missing failure / loopback / measureLatency cases.
- State management test coverage: N/A (no new cubit); ControlCubit only gained log mirroring — no new behavior tests needed.
- UI component test coverage: N/A for this scope.
