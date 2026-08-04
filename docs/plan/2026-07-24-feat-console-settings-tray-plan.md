---
title: Console Settings Tray
type: feat
date: 2026-07-24
---

## Console Settings Tray - Standard

Closes #302

## Overview

Add a slide-down quick-access tray to the console's main touchscreen
(`TracksView`), iOS/Android Control Center style: swipe down from the top
edge, tracking the finger during the drag, to reveal a panel of shortcut
buttons; swipe up or tap the scrim to dismiss.

Tray contents:

- **Settings** — opens the existing `SettingsPage` via `openSegnoSettings()`
  (same destination as the `S` key / toolbar button)
- **Signal/FX graph** — opens the existing graph page via
  `showSignalPage(context)` (same destination as the `G` key / toolbar button)
- **WiFi / Bluetooth / Tuner** — each opens a shared "coming soon" stub dialog
  naming the tapped feature; no real functionality this round
- **Brightness** — an inline slider, local `SettingsTrayCubit` state only, no
  real display dimming, resets to a default every session (no persistence)

A small visible pull-tab handle sits at the top edge at all times — tappable
to toggle open/closed, and draggable to open/close with the finger-tracking
feel. This is a deliberate addition beyond a pure swipe gesture: in console
(kiosk) mode the existing on-screen toolbar — the only current on-screen path
to Settings/Signal graph — is hidden entirely (see
[tracks_view.dart:103-105](../../lib/looper/view/tracks_view.dart#L103), foot
pedals drive transport there instead), so this tray would otherwise be the
sole, completely undiscoverable way to reach those destinations on real
hardware.

## Problem Statement / Motivation

The console app has no slide-down/overlay navigation precedent at all — every
screen is a plain `Navigator` push. On the physical console (kiosk mode),
Settings and the Signal/FX graph are reachable only via keyboard shortcuts
(`S`/`G`) or a toolbar that is explicitly hidden in that mode
([tracks_view.dart:112](../../lib/looper/view/tracks_view.dart#L112)), leaving
no on-screen path to either destination on real hardware today. A
touch-reachable quick-access tray closes that gap and gives a home for
upcoming WiFi/Bluetooth/Tuner features and (eventually) real brightness
control, without adding more toolbar clutter to the desktop build.

## Proposed Solution

### Architecture — where the tray lives

The tray and its `SettingsTrayCubit` are mounted **inside `_TracksViewState`
itself** (`lib/looper/view/tracks_view.dart`), wrapping the existing
`Focus > GestureDetector > Scaffold` subtree in a `Stack`, not at `LooperPage`
or globally in `app.dart`. Two facts from the codebase make this the exact
right scope, resolving what would otherwise be an ambiguous "where's the top
of the screen" question:

- **`TracksView` is never embedded in a small aperture.** In
  [pedal_faceplate.dart:99-107](../../lib/pedal/view/pedal_faceplate.dart#L99),
  when `onScreenPedal` is `false` (the real/production path — physical
  footswitches bound), `TracksView` renders full-screen, exactly matching
  "the 15.6in main touchscreen." When `onScreenPedal` is `true` (dev/simulator
  convenience mode, on-screen pedal graphic in place of real footswitches),
  `TracksView` is **replaced entirely** by `TrackMeterRow` embedded in the
  small plate mockup — `TracksView` (and therefore the tray) simply never
  mounts there. No extra gating logic is needed to keep the tray off the
  simulator plate.
- **There is exactly one `Navigator` in the whole app**, keyed by
  `segnoNavigatorKey` and installed once at
  [app.dart:622](../../lib/app/view/app.dart#L622). `openSegnoSettings()`
  (via `segnoNavigatorKey.currentState`) and `showSignalPage(context)` (via
  `Navigator.of(context)`) push onto the **same** navigator, just reached two
  different ways. Confirmed by grepping the whole `lib/` tree for a second
  `Navigator(...)`/`navigatorKey:` — there is none. This means either push
  lays a new, opaque, full-screen `MaterialPageRoute` directly on top of
  `TracksView`'s subtree (where the tray lives); the tray widget is not
  disposed by the push (default `maintainState: true`), it's simply painted
  over. Consequently "always closed on return" needs no pop-listener
  machinery — the tray's Settings/Signal button handlers call
  `context.read<SettingsTrayCubit>().close()` **synchronously, before**
  awaiting the navigation call, so by the time the pushed route is on screen
  (and by the time it later pops back), the cubit already reports closed.

### State — `SettingsTrayCubit` / `SettingsTrayState`

New files, following the `TracksCubit`/`TracksState` and
`ControlCubit`/`ControlState` convention (manual `Equatable` state class,
`part`-file split — no `freezed` anywhere in this codebase):

- `lib/looper/cubit/settings_tray_cubit.dart`
- `lib/looper/cubit/settings_tray_state.dart`

```dart
// settings_tray_state.dart
part of 'settings_tray_cubit.dart';

class SettingsTrayState extends Equatable {
  const SettingsTrayState({
    this.isOpen = false,
    this.dragProgress = 0,
    this.isNavigating = false,
    this.brightness = 0.8,
  });

  /// Whether the tray is fully open (post-settle). `false` while mid-drag.
  final bool isOpen;

  /// Live drag/settle progress in `0..1` — `0` fully closed, `1` fully open.
  /// Driven every frame during a drag; animated during settle.
  final double dragProgress;

  /// True from the instant a tray nav button is tapped until the pushed
  /// route pops — guards against a rapid double-tap double-pushing
  /// `showSignalPage` (which, unlike `openSegnoSettings`, has no re-entrancy
  /// guard of its own).
  final bool isNavigating;

  /// UI-only brightness slider value. Not persisted; not wired to any real
  /// display dimming yet.
  final double brightness;

  SettingsTrayState copyWith({...}) => ...;

  @override
  List<Object?> get props => [isOpen, dragProgress, isNavigating, brightness];
}
```

Cubit methods: `dragTo(double progress)` (clamped `0..1`, emitted every drag
frame), `settleFromDrag()` (distance-only threshold — `dragProgress > 0.5`
snaps to open, else closed; no velocity/fling threshold this round, flagged
as a follow-up), `open()` / `close()` / `toggle()` (programmatic, for
tap-on-handle and tap-on-scrim), `beginNavigating()` / `endNavigating()`,
`setBrightness(double value)`. No `SettingsRepository` dependency — this
cubit holds pure ephemeral UI state, unlike `HighContrastCubit`/`TracksCubit`.

### Widgets

- `lib/looper/view/settings_tray.dart` — the `Stack` overlay: a `_TrayHandle`
  (small pull-tab, always visible, pinned top-center; owns the
  `GestureDetector` with `onVerticalDragUpdate` → `dragTo`, `onVerticalDragEnd`
  → `settleFromDrag`, and `onTap` → `toggle`), a scrim (`GestureDetector` +
  `AnimatedOpacity`, tap → `close`, hit-testable only when `dragProgress > 0`),
  and the tray panel itself (height driven by `dragProgress * fullHeight`,
  containing the button row + brightness slider). Confining all drag handling
  to `_TrayHandle` — rather than the full tray body — means the brightness
  `Slider` inside the open panel owns its own gesture arena outright; there is
  no competing recognizer over its hit area.
- `lib/looper/view/coming_soon_stub.dart` — one shared
  `showComingSoonStub(context, {required String feature})` (`showDialog`,
  `"$feature — coming soon"`, dismissed by tap-outside or a close button); the
  tray stays open underneath, matching how the Settings/Signal buttons behave
  (nothing auto-closes on stub open, since it isn't a real navigation).
- Every duration (`_TrayHandle`'s tap-toggle, the settle animation after drag
  release, the scrim's `AnimatedOpacity`) follows the codebase's existing
  reduced-motion idiom — `MediaQuery.disableAnimationsOf(context) ?
  Duration.zero : const Duration(milliseconds: N)` — already used in
  [tracks_chrome.dart:320-322](../../lib/looper/view/tracks_chrome.dart#L320),
  [setup_surface.dart:216-218](../../lib/setup/setup_surface.dart#L216), and
  [window_chrome.dart:350-352](../../lib/window/window_chrome.dart#L350).
  During an active drag there is nothing to animate (position is driven every
  frame by the pointer); the reduced-motion check only affects the
  post-release settle and the tap-triggered open/close.

### Wiring the Settings/Signal buttons

Both buttons call the **exact same functions** the keyboard shortcuts and
toolbar already use — no new navigation logic:

```dart
onSettingsTap: () async {
  final cubit = context.read<SettingsTrayCubit>()..close()..beginNavigating();
  await openSegnoSettings();
  if (!context.mounted) return;
  cubit.endNavigating();
},
```

(and the equivalent for `showSignalPage(context)`). `beginNavigating()` /
`endNavigating()` disable both nav buttons for the duration of the push,
closing the rapid-double-tap gap that `showSignalPage` doesn't guard against
on its own — implemented at the tray level so `showSignalPage` itself stays
untouched.

## Technical Considerations

- **Architecture impact**: additive only. No change to `openSegnoSettings()`,
  `showSignalPage()`, `TracksCommands`, or the keyboard-shortcut path — both
  keep their exact current bindings and behavior.
- **Gesture conflicts**: `TrackColumn` has no scrollable and no vertical-drag
  gesture of its own (only tap + `onLongPress` on the meter bar), so there is
  no fight with existing content gestures. The existing
  `onSecondaryTapUp -> openSegnoSettings` `GestureDetector`
  ([tracks_view.dart:96-99](../../lib/looper/view/tracks_view.dart#L96)) is
  untouched — it wraps the `Scaffold`; the tray's own `Stack` sits as a sibling
  layer above it.
- **Performance**: `dragTo` emits once per drag-update frame; the tray panel
  should be a narrow, cheap subtree (a row of icon buttons + one slider) so
  per-frame rebuilds during the drag stay light.
- **Accessibility**: the visible pull-tab handle (tap **and** drag) is the
  answer to the discoverability gap on console/kiosk builds where the toolbar
  is hidden. Every open/close transition respects
  `MediaQuery.disableAnimationsOf` per WCAG 2.3.3, matching existing app
  precedent.
- **Scope boundaries carried over from the brainstorm** (unchanged): tray
  shell only this round — WiFi/Bluetooth/Tuner are stubs; brightness slider
  does not persist and does not dim any real display; no new keyboard
  shortcuts; scoped to the main touchscreen only (see architecture section
  above for why no explicit 7in/simulator exclusion code is needed).

## Success Criteria

```success-criteria
GOAL: A working, tested slide-down settings tray on TracksView: drag-to-open/close with a visible pull-tab handle, Settings/Signal buttons that reuse the existing navigation functions and always leave the tray closed on return, WiFi/Bluetooth/Tuner "coming soon" stubs, and a local-only brightness slider — all animations respecting reduced-motion.

SUCCESS CRITERIA:
- SettingsTrayCubit exists with open/close/toggle/dragTo/settleFromDrag/beginNavigating/endNavigating/setBrightness, covered by bloc_test cases for every transition and the 50% distance-threshold settle rule | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/cubit/settings_tray_cubit_test.dart
- The tray widget renders the handle, scrim, Settings/Signal/WiFi/Bluetooth/Tuner buttons, and brightness slider, and a widget test drives open-via-tap, open-via-drag-past-threshold, and close-via-scrim-tap | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view/settings_tray_test.dart
- Tapping the Settings or Signal/FX button closes the tray synchronously (before the push resolves) and calls the existing openSegnoSettings()/showSignalPage() functions unchanged | verify: manual 1) run the app 2) open the tray 3) tap Settings 4) confirm SettingsPage opens and the tray is closed underneath 5) back out 6) confirm tray stays closed 7) repeat for the Signal/FX button
- Rapid double-tap on the Signal/FX tray button does not push the signal page twice | verify: manual 1) open the tray 2) double-tap the Signal/FX button quickly 3) back out once and confirm only a single graph page was pushed (no doubled back-stack)
- Reduced-motion (MediaQuery.disableAnimationsOf) collapses the tray's settle and scrim animations to Duration.zero | verify: manual 1) enable "reduce motion" in the OS accessibility settings 2) run the app 3) open/close the tray via tap and via drag-release 4) confirm no animated transition plays, only instant state changes
- Existing keyboard shortcuts (S, G) and the desktop toolbar's Settings/Signal buttons are unchanged | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view/tracks_commands_test.dart test/looper/view/tracks_chrome_test.dart
- No lint/format regressions across the touched packages | verify: /Users/Tomas/development/flutter/bin/flutter analyze lib test && /Users/Tomas/development/flutter/bin/flutter format --set-exit-if-changed lib test

NON-GOALS:
- Real display brightness/dimming (no wlr-randr or platform-channel work)
- WiFi/Bluetooth/Tuner real functionality (stub dialogs only)
- Persisting the brightness slider value across app restarts
- Velocity/fling-based open threshold (distance-only for this round)
- Any change to the 7in secondary panel or its waveform widget
- Any change to existing keyboard shortcuts or their bindings

VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test test/looper/cubit/settings_tray_cubit_test.dart test/looper/view/settings_tray_test.dart test/looper/view/tracks_commands_test.dart test/looper/view/tracks_chrome_test.dart && /Users/Tomas/development/flutter/bin/flutter analyze lib test && /Users/Tomas/development/flutter/bin/flutter format --set-exit-if-changed lib test
```

## Success Metrics

- Settings and Signal/FX graph are reachable by touch on a console-mode build
  with no keyboard or toolbar, closing the discoverability gap identified
  during flow analysis.
- Zero regressions to existing `S`/`G` shortcuts, the desktop toolbar, or the
  `onSecondaryTapUp` shortcut.
- New code stays within `lib/looper/` (cubit + view), matching the existing
  single-`lib/` layout — no new package boundary needed for this feature.

## Dependencies & Risks

- **Risk — gesture-arena regressions**: confining tray-drag recognition to
  the handle widget (not the full tray body) is what keeps the brightness
  slider free of conflicts; if a future change widens the tray's own drag
  region, that isolation breaks silently. Call this out in a code comment at
  the handle's `GestureDetector`.
- **Risk — screenshot goldens are author-only** (per prior project learning):
  do not add new golden/screenshot tests for the tray's visual appearance —
  they render correctly only on the original author's machine (font
  differences) and rot silently everywhere else. Widget tests in this plan
  assert structural/state behavior (button presence, cubit state
  transitions), not pixel goldens.
- **Dependency**: none beyond existing packages already in `pubspec.yaml`
  (`bloc`, `flutter_bloc`, `equatable`, `bloc_test` — all already used by
  sibling cubits).
- **Follow-up work (explicitly out of scope here)**: velocity/fling-based
  open threshold; real brightness persistence + platform dimming; real
  WiFi/Bluetooth/Tuner functionality; adding a re-entrancy guard directly
  inside `showSignalPage()` itself (this plan guards only at the tray's call
  site).

## References & Research

- Brainstorm: `docs/brainstorm/2026-07-24-console-settings-tray-brainstorm-doc.md`
- Tracking issue: #302
- Console screen: [tracks_view.dart](../../lib/looper/view/tracks_view.dart)
  (no `TracksChrome` screen class exists — `tracks_chrome.dart` holds
  sub-widgets like `TracksToolbar`, not a screen container)
- Keyboard shortcuts: [tracks_commands.dart:178-185](../../lib/looper/view/tracks_commands.dart#L178)
- Navigation functions to reuse unchanged:
  [segno_navigator.dart:15-27](../../lib/app/segno_navigator.dart#L15) (`openSegnoSettings`),
  [signal_list_view.dart:31-79](../../lib/looper/view/signal_graph/signal_list_view.dart#L31) (`showSignalPage`)
- Single-Navigator confirmation: [app.dart:622](../../lib/app/view/app.dart#L622)
- Cubit convention examples: [tracks_cubit.dart](../../lib/looper/cubit/tracks_cubit.dart) /
  [tracks_state.dart](../../lib/looper/cubit/tracks_state.dart),
  [control_cubit.dart](../../lib/control/cubit/control_cubit.dart) /
  [control_state.dart](../../lib/control/cubit/control_state.dart),
  simple-cubit pattern: [high_contrast_cubit.dart](../../lib/looper/cubit/high_contrast_cubit.dart)
- Cubit test convention: [high_contrast_cubit_test.dart](../../test/looper/cubit/high_contrast_cubit_test.dart)
- Reduced-motion precedent: [tracks_chrome.dart:320-322](../../lib/looper/view/tracks_chrome.dart#L320),
  [setup_surface.dart:216-218](../../lib/setup/setup_surface.dart#L216),
  [window_chrome.dart:350-352](../../lib/window/window_chrome.dart#L350)
- Console/kiosk mode gate: [console_mode.dart](../../lib/common/console_mode.dart),
  [tracks_view.dart:103-112](../../lib/looper/view/tracks_view.dart#L103)
- Local BlocProvider scoping precedent: [looper_page.dart](../../lib/looper/view/looper_page.dart)
- Aperture-vs-full-screen render path: [pedal_faceplate.dart:93-107](../../lib/pedal/view/pedal_faceplate.dart#L93)
- Build/test gotchas: `docs/PROGRESS.md` "How to build / test"
