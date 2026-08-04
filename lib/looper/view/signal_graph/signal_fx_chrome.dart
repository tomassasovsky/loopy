import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/signal_graph/signal_style.dart';
import 'package:segno/theme/surface_theme.dart';

/// Chrome shared by every FX surface — the rack's device cards, the dock
/// header, and the stage summary rows. It exists so the four stages cannot
/// drift apart: one power control, one disabled dim, one reading of a plugin's
/// attention state, one provenance badge.

/// The **one** power control on every FX surface (D-POWER, R23): the host-side
/// enable, identical for a built-in device, a hosted plugin, and a whole chain.
/// A plugin's own bypass parameter never drives it.
///
/// The state rides the BUTTON's own semantics node (via [MergeSemantics]), not
/// a wrapper around it: a wrapper that forms its own boundary leaves the
/// focusable node announcing only the tooltip, so a screen-reader user hears
/// the action and never the on/off state R23 exists to state out loud.
class FxPowerToggle extends StatelessWidget {
  /// Creates an [FxPowerToggle].
  const FxPowerToggle({
    required this.toggleKey,
    required this.enabled,
    required this.onChanged,
    required this.semanticLabel,
    required this.tooltip,
    this.iconSize = 15,
    super.key,
  });

  /// A stable key on the toggle (for tests).
  final Key toggleKey;

  /// Whether the target is currently engaged.
  final bool enabled;

  /// Called with the flipped state.
  final void Function({required bool enabled}) onChanged;

  /// The state, in words — announced rather than left to the lit colour.
  final String semanticLabel;

  /// The action this tap performs.
  final String tooltip;

  /// The glyph size; the chain-level control sits a touch larger than a card's.
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return MergeSemantics(
      child: Semantics(
        key: toggleKey,
        toggled: enabled,
        label: semanticLabel,
        child: IconButton(
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          iconSize: iconSize,
          color: enabled ? surface.accent : surface.textTertiary,
          tooltip: tooltip,
          icon: Icon(enabled ? Icons.power_settings_new : Icons.power_off),
          onPressed: () => onChanged(enabled: !enabled),
        ),
      ),
    );
  }
}

/// Dims a powered-off subtree through the [SurfaceTheme] disabled token (R26)
/// — the single source of disabled dimming, so no widget hardcodes an opacity
/// and the high-contrast variant can dim less.
///
/// **Never nest one inside another**: two levels multiply into a far deeper dim
/// than the token, and they bury the warning states that must stay readable.
/// Dim the smallest honest unit — a card's body (never its header, which stays
/// workable), or an individual summary chip.
class FxDisabledDim extends StatelessWidget {
  /// Creates an [FxDisabledDim]; [enabled] false dims [child].
  const FxDisabledDim({
    required this.enabled,
    required this.child,
    super.key,
  });

  /// Whether the subtree is engaged (true renders at full strength).
  final bool enabled;

  /// The subtree to dim.
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: enabled ? 1 : context.surface.disabledOpacity,
    duration: Durations.short3,
    child: child,
  );
}

/// The attention state of a chain entry, when it has one — the ONE reading of
/// a hosted plugin's placeholder states, shared by the rack's device card and
/// the stage summary rows so the two can never disagree about the same plugin.
///
/// Precedence matches the card's own branch order: a still-scanning plugin (F5)
/// reads as loading rather than failed; an unresolved one distinguishes
/// "rejected" (D-BUS) from "missing" (D-MISS); a resolved one may still flag
/// version drift. Null for anything rendering normally.
({IconData icon, String message})? fxPluginStatus(
  AppLocalizations l10n,
  TrackEffect effect,
) {
  if (effect is! PluginEffect) return null;
  if (effect.loading) {
    return (icon: Icons.hourglass_empty, message: l10n.signalPluginLoading);
  }
  if (effect.unavailable) {
    return (
      icon: Icons.warning_amber_rounded,
      message: fxPluginPlaceholderReason(
        l10n,
        loading: false,
        unsupported: effect.unsupported,
      ),
    );
  }
  if (effect.versionChanged) {
    return (
      icon: Icons.info_outline,
      message: l10n.signalPluginVersionChanged,
    );
  }
  return null;
}

/// The placeholder card's explanatory line, and the summary chip's tooltip for
/// the same state — declared once so the two always say the same thing.
String fxPluginPlaceholderReason(
  AppLocalizations l10n, {
  required bool loading,
  required bool unsupported,
}) {
  if (loading) return l10n.signalPluginLoading;
  return unsupported
      ? l10n.signalPluginUnsupported
      : l10n.signalPluginUnavailable;
}

/// The **inherited** marker on a loop-stage chain (A6/R13): this take's chain
/// was copied by value from the listed hardware [inputs] when it was recorded.
///
/// Provenance, not a live link — nothing propagates in either direction once
/// the copy is made. The marker's lifetime is the domain's call (part 3a): it
/// survives edits that keep the copied slots, including reorders and parameter
/// changes, and drops when the chain is replaced wholesale, since by then it
/// describes nothing that survived.
class InheritedFxBadge extends StatelessWidget {
  /// Creates an [InheritedFxBadge] for the source [inputs], in input order.
  const InheritedFxBadge({
    required this.badgeKey,
    required this.inputs,
    super.key,
  });

  /// A stable key on the badge (for tests).
  final Key badgeKey;

  /// The hardware inputs the chain was copied from, in input order.
  final List<int> inputs;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final sources = inputs.map((i) => l10n.inputChannelLabel(i + 1)).join(', ');
    final provenance = l10n.signalInheritedFrom(sources);
    return Semantics(
      label: provenance,
      child: Tooltip(
        message: provenance,
        child: Container(
          key: badgeKey,
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: surface.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.south_east, size: 11, color: surface.textTertiary),
              const SizedBox(width: 4),
              Text(
                l10n.signalInherited,
                style: signalMono(color: surface.textTertiary, size: 9),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
