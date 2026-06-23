import 'package:flutter/material.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/view/signal_graph/signal_style.dart';
import 'package:loopy/theme/surface_theme.dart';

/// The output-routing control on an input or take row (D6): one **lit chip per
/// routed output**, each wearing that output's hue and removing the route on
/// tap, plus a trailing **"+" picker** that opens a menu of all outputs as
/// toggles — so a row never grows into a wide chip strip at 16 outputs.
class SignalRoutingChips extends StatelessWidget {
  /// Creates a [SignalRoutingChips].
  const SignalRoutingChips({
    required this.routes,
    required this.outputCount,
    required this.onToggle,
    this.keyPrefix = 'signalRoutes',
    super.key,
  });

  /// The output channels this row currently sends to.
  final List<int> routes;

  /// The number of available output channels.
  final int outputCount;

  /// Toggles routing to the given output channel on/off.
  final ValueChanged<int> onToggle;

  /// Selector namespace for tests.
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (routes.isEmpty)
          Text(
            l10n.signalNotRouted,
            style: signalMono(color: surface.textTertiary, size: 10),
          ),
        for (final o in routes)
          _Chip(
            chipKey: Key('${keyPrefix}_chip_$o'),
            color: outputColor(surface, o),
            label: l10n.outputChannelLabel(o + 1),
            semanticLabel: l10n.signalUnrouteOutput(o + 1),
            onTap: () => onToggle(o),
          ),
        _AddRouteButton(
          buttonKey: Key('${keyPrefix}_add'),
          outputCount: outputCount,
          routes: routes,
          onToggle: onToggle,
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.chipKey,
    required this.color,
    required this.label,
    required this.semanticLabel,
    required this.onTap,
  });

  final Key chipKey;
  final Color color;
  final String label;
  final String semanticLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Tooltip(
        message: semanticLabel,
        child: InkWell(
          key: chipKey,
          onTap: onTap,
          borderRadius: BorderRadius.circular(7),
          child: Semantics(
            button: true,
            label: semanticLabel,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: color.withValues(alpha: 0.55)),
              ),
              child: Text(
                '→ ${label.replaceAll(RegExp('[^0-9]'), '')}',
                // mockup .chip: colour-mix(rc 88%, white) — a touch brighter.
                style: signalMono(
                  color: Color.alphaBlend(
                    Colors.white.withValues(alpha: 0.14),
                    color,
                  ),
                  size: 10,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The "+" affordance: a popup menu of every output, checked when routed.
class _AddRouteButton extends StatelessWidget {
  const _AddRouteButton({
    required this.buttonKey,
    required this.outputCount,
    required this.routes,
    required this.onToggle,
  });

  final Key buttonKey;
  final int outputCount;
  final List<int> routes;
  final ValueChanged<int> onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return PopupMenuButton<int>(
      key: buttonKey,
      tooltip: l10n.signalRouteTooltip,
      onSelected: onToggle,
      color: kSignalMenu,
      shape: signalMenuShape(),
      elevation: 10,
      menuPadding: const EdgeInsets.symmetric(vertical: 5),
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        for (var o = 0; o < outputCount; o++)
          CheckedPopupMenuItem<int>(
            key: Key('signalRoutes_menu_$o'),
            value: o,
            checked: routes.contains(o),
            child: Text(
              l10n.signalRouteToOutput(o + 1),
              style: signalMono(
                color: routes.contains(o)
                    ? outputColor(surface, o)
                    : surface.textPrimary,
                size: 12,
              ),
            ),
          ),
      ],
      // A quiet add-chip in the mockup's `.fx.add` vocabulary (dashed-feel,
      // tertiary) rather than a boxy icon button.
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: kSignalLine2),
        ),
        child: Text('+', style: signalMono(color: surface.textTertiary)),
      ),
    );
  }
}
