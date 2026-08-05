import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/view/tray/tray_metrics.dart';
import 'package:segno/theme/theme.dart';

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

  /// Rail width. Sized for an icon beside a full-size label, because the rail
  /// is a navigation spine and should read as one — a column of icon-over-
  /// caption tiles reads as more of the tile grid the rail exists to replace.
  ///
  /// From the redesign mockups (#490); the earlier 84px stacked form was built
  /// without them, since the decision record carries no diagrams.
  static const double _width = 165;

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
        // The mockups' Control glyph: a foot controller, not a keyboard —
        // the domain covers the floor pedal and whatever MIDI box is beside
        // it, neither of which is a piano.
        SettingsTrayDestination.control => Icons.videogame_asset_outlined,
        SettingsTrayDestination.tuner => Icons.graphic_eq,
        // An antenna, not a WiFi fan or a Bluetooth rune: the entry is both
        // radios, and either radio's own glyph would read as only that one.
        SettingsTrayDestination.network => Icons.settings_input_antenna,
      };

  /// The caption for [destination]. Exhaustive for the same reason as
  /// [_iconFor].
  static String _labelFor(
    AppLocalizations l10n,
    SettingsTrayDestination destination,
  ) => switch (destination) {
    SettingsTrayDestination.home => l10n.trayHomeLabel,
    SettingsTrayDestination.control => l10n.trayControlLabel,
    SettingsTrayDestination.tuner => l10n.trayTunerLabel,
    SettingsTrayDestination.network => l10n.trayNetworkLabel,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final destination = context.watch<SettingsTrayCubit>().state.destination;
    final cubit = context.read<SettingsTrayCubit>();

    // Clamped rather than fixed: a sheet narrower than the rail's natural
    // width would otherwise overflow the item Row. Real on a small display,
    // not only in a test harness.
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? math.min(_width, constraints.maxWidth)
            : _width;
        return SizedBox(
          width: width,
          // The rail absorbs taps that miss an item. Without this they fall
          // through to the panel's full-bleed dismiss detector and close the
          // tray — fine for the home face's tile grid (Control Center
          // dismisses on a miss), wrong for a persistent navigation
          // surface you are aiming at.
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
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: _itemGap,
                      children: [
                        for (final target
                            in SettingsTrayDestination.values) ...[
                          // Stretch so every pill spans the rail: pills
                          // sized to their own text read as chips, not
                          // as rows of one list.
                          _RailItem(
                            key: Key('settingsTrayRail_${target.name}'),
                            icon: _iconFor(target),
                            label: _labelFor(l10n, target),
                            selected: destination == target,
                            onTap: () => cubit.showDestination(target),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One rail entry: icon beside label, accent-tinted and pill-backed while it
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

  static const double _radius = 24;

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
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 11),
        margin: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_radius),
          color: selected
              ? surface.accent.withValues(alpha: 0.18)
              : Colors.transparent,
        ),
        // Icon beside the label, one row per destination. The label is at
        // reading size rather than caption size: this is the surface you aim
        // at to change what the sheet is showing, not a dense tile.
        child: Row(
          children: [
            Icon(icon, color: tint, size: 20),
            const SizedBox(width: 9),
            Expanded(
              child: Transform.translate(
                offset: const Offset(0, 1),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tint,
                    fontSize: 14,
                    height: 1.1,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
