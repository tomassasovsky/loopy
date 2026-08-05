import 'dart:async';

import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/bluetooth/bluetooth_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/view/tray/tray.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/wifi/wifi_cubit.dart';
import 'package:wifi_repository/wifi_repository.dart';

/// The console's slide-down quick-access tray (Control-Center style): a small
/// pull-tab [_TrayHandle] pinned at the top edge at all times — tap or drag
/// it down to reveal a near-fullscreen translucent sheet. The open sheet is a
/// [TrayPanel]: a persistent navigation rail down the left, and the
/// destination it selects (home tiles + brightness, Tuner, WiFi, Bluetooth)
/// filling the rest. Tap the scrim or drag the handle back up to dismiss.
///
/// Hand-rolled (not the `anydrawer` package's route-based drawer): the
/// slide needs to track the drag continuously, following the finger frame
/// by frame, which `anydrawer` can't do for an *opening* drag — its
/// `AnyDrawerController`/`AnyDrawerRegion` only support threshold-then-snap
/// (accumulate the drag, and only on release play a fixed animation).
/// `dragEnabled` drag-to-*dismiss* on an already-open `anydrawer` drawer
/// does track the finger, but only because it writes straight into that
/// route's own `AnimationController` — a controller that doesn't exist
/// until the route is pushed, so there's no way to reuse that trick for the
/// reveal-from-closed gesture this tray needs.
///
/// Overlaid as a `Stack` sibling of `TracksView`'s content (see
/// `tracks_view.dart`), not a route — it paints over the tracks grid rather
/// than navigating away from it.
class SettingsTray extends StatefulWidget {
  /// Creates a [SettingsTray].
  ///
  /// Optional [wifiRepository] / [bluetoothRepository] override the
  /// [RepositoryProvider] values — used by screenshot previews and tests.
  const SettingsTray({
    super.key,
    this.wifiRepository,
    this.bluetoothRepository,
  });

  /// Optional WiFi repository override.
  final WifiRepository? wifiRepository;

  /// Optional Bluetooth repository override.
  final BluetoothRepository? bluetoothRepository;

  @override
  State<SettingsTray> createState() => _SettingsTrayState();
}

class _SettingsTrayState extends State<SettingsTray> {
  /// True for the lifetime of a handle drag. While true, the panel height and
  /// scrim opacity track the pointer with no animation (every frame is a
  /// fresh, instant target); once the drag ends the next change animates,
  /// giving the settle its motion. A tap-triggered toggle (no drag) always
  /// animates.
  bool _dragging = false;

  WifiCubit? _wifi;
  BluetoothCubit? _bluetooth;

  WifiRepository _wifiRepository() {
    if (widget.wifiRepository != null) return widget.wifiRepository!;
    try {
      return context.read<WifiRepository>();
    } on ProviderNotFoundException {
      return const WifiRepository(client: UnsupportedWifiClient());
    }
  }

  BluetoothRepository _bluetoothRepository() {
    if (widget.bluetoothRepository != null) {
      return widget.bluetoothRepository!;
    }
    try {
      return context.read<BluetoothRepository>();
    } on ProviderNotFoundException {
      return const BluetoothRepository(client: UnsupportedBluetoothClient());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wifi == null) {
      final wifi = WifiCubit(repository: _wifiRepository());
      unawaited(wifi.load());
      _wifi = wifi;
    }
    if (_bluetooth == null) {
      final bluetooth = BluetoothCubit(repository: _bluetoothRepository());
      unawaited(bluetooth.load());
      _bluetooth = bluetooth;
    }
  }

  @override
  void dispose() {
    unawaited(_wifi?.close() ?? Future<void>.value());
    unawaited(_bluetooth?.close() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<SettingsTrayCubit>().state;
    final cubit = context.read<SettingsTrayCubit>();
    final motion = _dragging || MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);

    // Full-height, like iOS Control Center — the tray covers the entire
    // touchscreen with a translucent scrim (see [TrayPanel]), not a small
    // dropdown; the tiles inside stay small and top-anchored rather than
    // stretching to fill that space (see [TrayPanel]'s layout).
    final trayHeight = MediaQuery.sizeOf(context).height.clamp(340.0, 3000.0);

    return Stack(
      fit: StackFit.expand,
      children: [
        // The scrim: a flat dim, opacity-animated (it never moves — only
        // ever fades) — dismisses on tap, hit-testable (and in the
        // semantics tree — IgnorePointer.ignoringSemantics mirrors
        // `ignoring` by default) only once the tray has any visible extent,
        // so it never blocks touches to TracksView, or a screen reader's
        // tap-to-dismiss, while fully closed.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: state.dragProgress <= 0,
            child: GestureDetector(
              key: const Key('settingsTray_scrim'),
              behavior: HitTestBehavior.opaque,
              onTap: cubit.closeTray,
              child: Semantics(
                button: true,
                label: l10n.dismiss,
                child: AnimatedOpacity(
                  duration: motion,
                  opacity: state.dragProgress * 0.5,
                  child: const ColoredBox(color: Colors.black),
                ),
              ),
            ),
          ),
        ),
        // The panel itself: unlike the scrim, this genuinely translates —
        // a fixed-height card whose top edge slides from fully off-screen
        // (`-trayHeight`, tucked behind the handle) down to `0`, dragging
        // its whole contents down as one rigid body rather than wiping a
        // clip boundary over a stationary layout (an opacity/height fade
        // reads as content *appearing in place*, not as something sliding).
        AnimatedPositioned(
          duration: motion,
          curve: Curves.easeOut,
          top: (state.dragProgress.clamp(0.0, 1.0) - 1) * trayHeight,
          left: 0,
          right: 0,
          height: trayHeight,
          // Off-screen (top + height <= 0) while closed — also drop it from
          // the semantics tree then, so a screen reader never lands on
          // buttons with no visible extent.
          child: ExcludeSemantics(
            excluding: state.dragProgress <= 0,
            child: MultiBlocProvider(
              providers: [
                BlocProvider<WifiCubit>.value(value: _wifi!),
                BlocProvider<BluetoothCubit>.value(value: _bluetooth!),
              ],
              child: const TrayPanel(),
            ),
          ),
        ),
        // The handle rides down with the drawer — resting at the very top
        // of the screen while closed, and at the drawer's own bottom edge
        // (fully inside it, not hanging off past the screen) once open —
        // rather than staying pinned at the top while the drawer grows out
        // from under it, so there's always a pull tab right at the sheet's
        // visible edge to drag closed.
        AnimatedPositioned(
          duration: motion,
          curve: Curves.easeOut,
          top:
              state.dragProgress.clamp(0.0, 1.0) *
              (trayHeight - _TrayHandle.height),
          left: 0,
          right: 0,
          child: _TrayHandle(
            progress: state.dragProgress.clamp(0.0, 1.0),
            duration: motion,
            onDragStart: () => setState(() => _dragging = true),
            // Reads `cubit.state` (always current) rather than the
            // `state` closed over from this build — several pointer-move
            // events can fire back-to-back before the next rebuild, and
            // accumulating from a build-time snapshot would drop all but
            // the last delta in that batch instead of summing them.
            onDragUpdate: (dy) => cubit.dragTo(
              cubit.state.dragProgress + dy / trayHeight,
            ),
            onDragEnd: () {
              cubit.settleFromDrag();
              setState(() => _dragging = false);
            },
            onTap: cubit.toggle,
          ),
        ),
      ],
    );
  }
}

/// The always-visible pull tab pinned at the top edge. Owns ALL drag
/// recognition for the tray — confined here (rather than spread over the
/// full tray body) so the brightness slider inside the open panel owns its
/// own gesture arena outright, with no competing recognizer over its hit
/// area. If a future change widens the tray's own drag region, that
/// isolation breaks silently — keep drag handling on this widget alone.
class _TrayHandle extends StatelessWidget {
  const _TrayHandle({
    required this.progress,
    required this.duration,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onTap,
  });

  /// Live/settled drag progress (`0..1`) — tints the pill as the tray opens,
  /// so the handle itself previews the motion rather than sitting as a
  /// static affordance.
  final double progress;

  /// Reduced-motion-aware duration for the pill's colour lerp (zero during
  /// an active drag, so it tracks the pointer).
  final Duration duration;

  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onTap;

  /// Total rendered height (padding + pill) — [SettingsTray] needs this to
  /// position the handle at the drawer's own bottom edge, not just its own
  /// intrinsic size, since it's wrapped in an `AnimatedPositioned` with no
  /// `bottom`/`height` of its own.
  ///
  /// Shared with the navigation rail, which pads its scroll view past this
  /// band so no rail item can sit under the handle. Change it here and the
  /// rail follows.
  static const double height = kTrayHandleHeight;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final tint = Color.lerp(surface.textTertiary, surface.accent, progress)!;
    return Semantics(
      button: true,
      label: l10n.a11yTrayHandle,
      child: GestureDetector(
        key: const Key('settingsTray_handle'),
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (_) => onDragStart(),
        onVerticalDragUpdate: (details) => onDragUpdate(details.delta.dy),
        onVerticalDragEnd: (_) => onDragEnd(),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8),
          color: Colors.transparent,
          alignment: Alignment.topCenter,
          child: AnimatedContainer(
            duration: duration,
            width: 40,
            height: 5,
            decoration: BoxDecoration(
              color: tint,
              borderRadius: BorderRadius.circular(SurfaceTheme.radius2),
            ),
          ),
        ),
      ),
    );
  }
}
