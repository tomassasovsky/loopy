import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/cubit/settings_tray_cubit.dart';
import 'package:loopy/looper/view/tray/tray_metrics.dart';
import 'package:loopy/theme/theme.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;

/// The open tray's navigation spine: a persistent vertical rail listing every
/// in-tray destination, with the selected one filling the sheet beside it.
///
/// This is the seam the rest of the console redesign (#442) hangs off — a new
/// config surface becomes "add a [SettingsTrayDestination] and an entry here",
/// not "push another full-screen route away from the performance view".
///
/// Only destinations that render *inside* the tray belong here. Settings and
/// the Signal page still push full-screen routes and so stay tiles on the
/// home face: a rail item that navigated away would lie about what the rail
/// is.
class TrayNavigationRail extends StatelessWidget {
  /// Creates a [TrayNavigationRail].
  const TrayNavigationRail({super.key});

  /// Rail width. Wide enough for the icon plus a two-line caption at the tile
  /// caption's own size, so a rail item and a tile read as the same species
  /// of control.
  static const double _width = 84;

  static const double _itemGap = 4;

  /// The glyph for [destination].
  ///
  /// An exhaustive `switch`, deliberately — the rail is built by iterating
  /// [SettingsTrayDestination.values], so a part that adds a destination gets
  /// a compile error here instead of a rail that silently omits its own
  /// panel. `TrayPanel`'s face switch already fails this way; the rail must
  /// too, or a destination can be reachable in code and invisible on screen.
  static IconData _iconFor(SettingsTrayDestination destination) =>
      switch (destination) {
        SettingsTrayDestination.home => Icons.tune,
        SettingsTrayDestination.pedal => Icons.piano_outlined,
        SettingsTrayDestination.tuner => Icons.graphic_eq,
        SettingsTrayDestination.wifi => Icons.wifi,
        SettingsTrayDestination.bluetooth => Icons.bluetooth,
      };

  /// The caption for [destination]. Exhaustive for the same reason as
  /// [_iconFor].
  static String _labelFor(
    AppLocalizations l10n,
    SettingsTrayDestination destination,
  ) => switch (destination) {
    SettingsTrayDestination.home => l10n.trayHomeLabel,
    SettingsTrayDestination.pedal => l10n.trayPedalLabel,
    SettingsTrayDestination.tuner => l10n.trayTunerLabel,
    SettingsTrayDestination.wifi => l10n.trayWifiLabel,
    SettingsTrayDestination.bluetooth => l10n.trayBluetoothLabel,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final destination = context.watch<SettingsTrayCubit>().state.destination;
    final cubit = context.read<SettingsTrayCubit>();

    return SizedBox(
      width: _width,
      // The rail absorbs taps that miss an item. Without this they fall
      // through to the panel's full-bleed dismiss detector and close the
      // tray — fine for the home face's tile grid (Control Center dismisses
      // on a miss), wrong for a persistent navigation surface you are aiming
      // at.
      //
      // `excludeFromSemantics` because this detector exists purely to stop
      // pointers: left in the tree it collapses the whole rail into one
      // tappable node whose activation does nothing, so a screen reader
      // offers a no-op action over the real items.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: () {},
        child: Semantics(
          explicitChildNodes: true,
          label: l10n.a11yTrayRail,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                right: BorderSide(
                  color: surface.line.withValues(alpha: 0.4),
                ),
              ),
            ),
            child: SingleChildScrollView(
              // The drag handle rides at the open panel's bottom edge, over
              // the rail's last band — pad past it so a future destination
              // cannot land under a control that closes the tray.
              padding: const EdgeInsets.only(bottom: kTrayHandleHeight),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final target in SettingsTrayDestination.values) ...[
                    const SizedBox(height: _itemGap),
                    _RailItem(
                      key: Key('settingsTrayRail_${target.name}'),
                      icon: _iconFor(target),
                      label: _labelFor(l10n, target),
                      selected: destination == target,
                      onTap: () => cubit.showDestination(target),
                    ),
                  ],
                  const SizedBox(height: _itemGap),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One rail entry: icon over caption, accent-tinted and pill-backed while it
/// is the showing destination.
class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  static const double _radius = 14;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final tint = selected ? surface.accent : surface.textSecondary;
    return FocusableTapTarget(
      onTap: onTap,
      semanticLabel: label,
      selected: selected,
      borderRadius: _radius,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_radius),
          color: selected
              ? surface.accent.withValues(alpha: 0.18)
              : Colors.transparent,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: tint, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tint,
                fontSize: 10,
                height: 1.1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
