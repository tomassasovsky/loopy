import 'dart:async';
import 'dart:ui';

import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/app/loopy_navigator.dart';
import 'package:loopy/bluetooth/bluetooth_cubit.dart';
import 'package:loopy/bluetooth/bluetooth_tray_panel.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/cubit/settings_tray_cubit.dart';
import 'package:loopy/looper/view/coming_soon_stub.dart';
import 'package:loopy/looper/view/signal_graph/signal_graph.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/wifi/wifi_cubit.dart';
import 'package:loopy/wifi/wifi_tray_panel.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:wifi_repository/wifi_repository.dart';

/// The console's slide-down quick-access tray (Control-Center style): a small
/// pull-tab [_TrayHandle] pinned at the top edge at all times — tap or drag
/// it down to reveal a near-fullscreen translucent sheet holding small,
/// top-anchored destination tiles (Settings, Signal/FX graph, WiFi,
/// Bluetooth, Tuner stub) beside a compact vertical brightness slider;
/// WiFi/Bluetooth expand in-place over the tiles until Back; tap the scrim
/// or drag the handle back up to dismiss.
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
    // touchscreen with a translucent scrim (see `_TrayPanel`), not a small
    // dropdown; the tiles inside stay small and top-anchored rather than
    // stretching to fill that space (see `_TrayPanel`'s layout).
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
              child: const _TrayPanel(),
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
  static const double height = 21;

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
              borderRadius: BorderRadius.circular(2.5),
            ),
          ),
        ),
      ),
    );
  }
}

/// The tray's contents once open — near-fullscreen frosted sheet. Home shows
/// compact Control-Center tiles + brightness; WiFi/Bluetooth expand *inside*
/// the sheet (animated destination swap) rather than pushing a full-screen
/// route.
class _TrayPanel extends StatelessWidget {
  const _TrayPanel();

  /// Fixed tile footprint — real Control Center tiles stay small no matter
  /// how large the sheet behind them is. Taller than it is wide, to leave
  /// room for the label under the icon.
  static const double _tileWidth = 72;
  static const double _tileHeight = 100;
  static const double _gap = 12;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final state = context.watch<SettingsTrayCubit>().state;
    final cubit = context.read<SettingsTrayCubit>();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: surface.background.withValues(alpha: 0.78),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Semantics(
                    button: true,
                    label: l10n.dismiss,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: cubit.closeTray,
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 40),
                    // Home stays content-sized + centered; WiFi/BT use a
                    // fixed [_RadioDivision] footprint so they don't float
                    // as a tight blob in the middle of the sheet.
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: reduceMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 240),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) {
                          // Vertical handoff: incoming rises from below.
                          final offset =
                              Tween<Offset>(
                                begin: const Offset(0, 0.12),
                                end: Offset.zero,
                              ).animate(
                                CurvedAnimation(
                                  parent: animation,
                                  curve: Curves.easeOutCubic,
                                ),
                              );
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: offset,
                              child: child,
                            ),
                          );
                        },
                        child: KeyedSubtree(
                          key: ValueKey(state.destination),
                          child: switch (state.destination) {
                            SettingsTrayDestination.home =>
                              SingleChildScrollView(
                                child: _TrayHome(
                                  state: state,
                                  cubit: cubit,
                                ),
                              ),
                            SettingsTrayDestination.wifi => _RadioDivision(
                              child: WifiTrayPanel(
                                onBack: cubit.showHome,
                              ),
                            ),
                            SettingsTrayDestination.bluetooth => _RadioDivision(
                              child: BluetoothTrayPanel(
                                onBack: cubit.showHome,
                              ),
                            ),
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Fixed footprint for the in-tray WiFi / Bluetooth faces — sizing only;
/// no extra card chrome. Lists scroll inside the panel.
class _RadioDivision extends StatelessWidget {
  const _RadioDivision({required this.child});

  /// Designated panel size (1080p console Control Center).
  static const Size size = Size(520, 680);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size.width,
      height: size.height,
      child: child,
    );
  }
}

/// Home face: destination tiles + brightness slider.
class _TrayHome extends StatelessWidget {
  const _TrayHome({required this.state, required this.cubit});

  final SettingsTrayState state;
  final SettingsTrayCubit cubit;

  static const double _tileWidth = _TrayPanel._tileWidth;
  static const double _tileHeight = _TrayPanel._tileHeight;
  static const double _gap = _TrayPanel._gap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final wifi = context.watch<WifiCubit>().state;
    final bluetooth = context.watch<BluetoothCubit>().state;
    const blockHeight = _tileHeight * 2 + _gap;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: _tileWidth,
                  height: _tileHeight,
                  child: _TrayTile(
                    key: const Key('settingsTray_settings'),
                    icon: Icons.settings_outlined,
                    label: l10n.settingsTooltip,
                    isOn: false,
                    onTap: state.isNavigating
                        ? null
                        : () => unawaited(
                            _navigate(context, openLoopySettings),
                          ),
                  ),
                ),
                const SizedBox(width: _gap),
                SizedBox(
                  width: _tileWidth,
                  height: _tileHeight,
                  child: _TrayTile(
                    key: const Key('settingsTray_signal'),
                    icon: Icons.account_tree_outlined,
                    label: l10n.signalTooltip,
                    isOn: false,
                    onTap: state.isNavigating
                        ? null
                        : () => unawaited(
                            _navigate(context, () => showSignalPage(context)),
                          ),
                  ),
                ),
                const SizedBox(width: _gap),
                SizedBox(
                  width: _tileWidth,
                  height: _tileHeight,
                  child: _TrayTile(
                    key: const Key('settingsTray_wifi'),
                    // On = radio up (`enabled`), not association (`connected`).
                    icon: wifi.status.enabled ? Icons.wifi : Icons.wifi_off,
                    // Caption: SSID when associated, else the generic label.
                    label: wifi.status.connected && wifi.status.ssid.isNotEmpty
                        ? wifi.status.ssid
                        : l10n.trayWifiLabel,
                    semanticLabel:
                        wifi.status.connected && wifi.status.ssid.isNotEmpty
                        ? '${l10n.trayWifiLabel}, ${wifi.status.ssid}'
                        : l10n.trayWifiLabel,
                    isOn: wifi.supported && wifi.status.enabled,
                    onTap: wifi.supported && !wifi.busy
                        ? () => unawaited(_toggleWifi(context))
                        : null,
                    onLongPress: cubit.openWifi,
                  ),
                ),
              ],
            ),
            const SizedBox(height: _gap),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: _tileWidth,
                  height: _tileHeight,
                  child: _TrayTile(
                    key: const Key('settingsTray_bluetooth'),
                    // On = adapter powered, not discoverable/advertising.
                    icon: bluetooth.status.powered
                        ? Icons.bluetooth
                        : Icons.bluetooth_disabled,
                    // Caption: peer name when Connected, else the generic label.
                    label:
                        bluetooth.status.connected &&
                            bluetooth.status.device.isNotEmpty
                        ? bluetooth.status.device
                        : l10n.trayBluetoothLabel,
                    semanticLabel:
                        bluetooth.status.connected &&
                            bluetooth.status.device.isNotEmpty
                        ? '${l10n.trayBluetoothLabel}, ${bluetooth.status.device}'
                        : l10n.trayBluetoothLabel,
                    isOn: bluetooth.supported && bluetooth.status.powered,
                    onTap: bluetooth.supported && !bluetooth.busy
                        ? () => unawaited(_toggleBluetooth(context))
                        : null,
                    onLongPress: cubit.openBluetooth,
                  ),
                ),
                const SizedBox(width: _gap),
                SizedBox(
                  width: _tileWidth,
                  height: _tileHeight,
                  child: _TrayTile(
                    key: const Key('settingsTray_tuner'),
                    icon: Icons.graphic_eq,
                    label: l10n.trayTunerLabel,
                    isOn: false,
                    onTap: () => unawaited(
                      showComingSoonStub(
                        context,
                        feature: l10n.trayTunerLabel,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(width: _gap),
        SizedBox(
          width: 56,
          height: blockHeight,
          child: _BrightnessSliderTile(
            value: state.brightness,
            onChanged: (value) => unawaited(cubit.setBrightness(value)),
          ),
        ),
      ],
    );
  }
}

/// Runs a tray nav-button push (`openLoopySettings` or `showSignalPage`,
/// unchanged from the `S`/`G` keyboard shortcuts and desktop toolbar — both
/// pick up the app-wide fade + scale-up transition from
/// `AppTheme`'s `pageTransitionsTheme`). Closes the tray synchronously —
/// before [push] resolves — and holds the `isNavigating` guard for the
/// push's duration even if it throws, so a failed navigation can never leave
/// both nav tiles stuck disabled.
Future<void> _navigate(
  BuildContext context,
  Future<void> Function() push,
) async {
  final cubit = context.read<SettingsTrayCubit>()
    ..closeTray()
    ..beginNavigating();
  try {
    await push();
  } finally {
    if (context.mounted) cubit.endNavigating();
  }
}

/// Tap toggle for WiFi: radio on/off. Turning **on** also opens the in-tray
/// WiFi panel so the user can pick a network.
Future<void> _toggleWifi(BuildContext context) async {
  final wifi = context.read<WifiCubit>();
  final tray = context.read<SettingsTrayCubit>();
  final turningOn = !wifi.state.status.enabled;
  await wifi.toggleEnabled();
  if (!context.mounted) return;
  if (turningOn && wifi.state.status.enabled) tray.openWifi();
}

/// Tap toggle for Bluetooth: adapter power. Turning **on** also opens the
/// in-tray Bluetooth panel.
Future<void> _toggleBluetooth(BuildContext context) async {
  final bluetooth = context.read<BluetoothCubit>();
  final tray = context.read<SettingsTrayCubit>();
  final turningOn = !bluetooth.state.status.powered;
  await bluetooth.togglePowered();
  if (!context.mounted) return;
  if (turningOn && bluetooth.state.status.powered) tray.openBluetooth();
}

/// One Control Center tile: round glass button + caption. Color is a dual
/// state — [isOn] uses [SurfaceTheme.accent], otherwise the shared off color
/// ([SurfaceTheme.textSecondary]). Destinations that cannot be "on" pass
/// `isOn: false`. Null [onTap] dims the tile (nav-in-flight / unsupported
/// radio); [onLongPress] still opens config when set.
class _TrayTile extends StatelessWidget {
  const _TrayTile({
    required this.icon,
    required this.label,
    required this.isOn,
    required this.onTap,
    this.onLongPress,
    this.semanticLabel,
    super.key,
  });

  final IconData icon;
  final String label;

  /// Dual-state tint: accent when on, shared off color when off.
  final bool isOn;

  /// Null renders the tile dimmed — nav push in flight, or unsupported radio.
  final VoidCallback? onTap;

  /// Long-press opens in-tray config (WiFi / Bluetooth).
  final VoidCallback? onLongPress;

  /// Accessibility label; defaults to [label] when null.
  final String? semanticLabel;

  /// Circle diameter — independent of the tile's overall footprint (which
  /// also has to fit the caption below), same as before the caption existed.
  static const _circleSize = 72.0;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final accent = isOn ? surface.accent : surface.textSecondary;
    // Tappable when either gesture is available (long-press alone still works
    // for unsupported radios that can open the config face).
    final interactive = onTap != null || onLongPress != null;
    return FocusableTapTarget(
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel: semanticLabel ?? label,
      selected: isOn,
      borderRadius: _circleSize / 2,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: interactive ? 1 : 0.4,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: _circleSize,
              height: _circleSize,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: isOn ? 0.28 : 0.14),
                ),
                child: Center(child: Icon(icon, color: accent, size: 26)),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: accent,
                fontSize: 10,
                height: 1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The brightness control, Control-Center style: a tall bar, built by
/// rotating a plain [Slider] a quarter turn — `RotatedBox` rotates
/// hit-testing along with painting, so the drag gesture lands correctly
/// without any custom gesture math. [Slider] already brings its own tap,
/// drag, and keyboard handling, unlike the hand-rolled `SignalKnob`; only
/// its semantics need replacing (see [_BrightnessSliderTileState] below).
/// Brightness is persisted and applied via [SettingsTrayCubit.setBrightness].
class _BrightnessSliderTile extends StatefulWidget {
  const _BrightnessSliderTile({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_BrightnessSliderTile> createState() => _BrightnessSliderTileState();
}

class _BrightnessSliderTileState extends State<_BrightnessSliderTile> {
  /// The step announced by the accessibility increase/decrease actions —
  /// independent of [Slider]'s own *physical*-keyboard step, which is
  /// platform-dependent (`_adjustmentUnit` in the Flutter SDK's
  /// `slider.dart`: 10% on iOS/macOS, 5% elsewhere) and out of our control.
  static const double _step = 0.05;

  final _focusNode = FocusNode(debugLabel: 'settingsTray_brightness');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _increase() => widget.onChanged((widget.value + _step).clamp(0.0, 1.0));

  void _decrease() => widget.onChanged((widget.value - _step).clamp(0.0, 1.0));

  static String _percent(double value) => '${(value * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return RotatedBox(
      key: const Key('settingsTray_brightness'),
      // -90°: dragging up (screen-space) increases the slider's own
      // left-to-right value.
      quarterTurns: 3,
      // Slider sets its own semantics boundary — an ancestor label never
      // merges into it, always landing as a second, disjoint node — so its
      // semantics are excluded and replaced wholesale here with one node a
      // screen reader actually reads as "Brightness, 80%" rather than two
      // unconnected stops. A GestureDetector requests focus on tap-down
      // (Slider only does that as a side effect of its own recognizers
      // winning the gesture arena, which an outer detector can't rely on).
      child: Semantics(
        // `container: true` — otherwise this merges upward into whatever
        // ancestor Semantics happens to be in scope (the tray's own scrim
        // dismiss button included), instead of staying its own node.
        container: true,
        slider: true,
        label: l10n.trayBrightnessLabel,
        value: _percent(widget.value),
        increasedValue: _percent((widget.value + _step).clamp(0.0, 1.0)),
        decreasedValue: _percent((widget.value - _step).clamp(0.0, 1.0)),
        onIncrease: _increase,
        onDecrease: _decrease,
        child: ExcludeSemantics(
          // A `Listener` (not a `GestureDetector`) — Slider's own drag
          // recognizer resolves the gesture arena eagerly (on pointer-down,
          // for a responsive drag-to-set-value feel), rejecting a competing
          // `TapGestureRecognizer` before its `onTapDown` ever fires. A raw
          // pointer listener sits outside that arena entirely, so it always
          // sees the down event regardless of which recognizer wins it.
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _focusNode.requestFocus(),
            // A translucent capsule behind the bar, matching the tiles'
            // frosted-card look — a bare `Slider` on its own reads as a
            // stray line floating over the panel, not a real control.
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: surface.accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 18,
                    activeTrackColor: surface.accent,
                    inactiveTrackColor: surface.accent.withValues(alpha: 0.12),
                    thumbColor: Colors.white,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 11,
                      elevation: 2,
                    ),
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: Slider(
                    focusNode: _focusNode,
                    value: widget.value,
                    onChanged: widget.onChanged,
                    label: _percent(widget.value),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
