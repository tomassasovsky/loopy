import 'package:flutter/material.dart';
import 'package:segno/theme/theme.dart';

/// One chain on the Signal face, as a card: what it is, where it sits, where
/// it goes, what is loaded on it, and whether you hear it.
///
/// **A card-as-tile, which the console vocabulary does not have.** Every other
/// domain draws a list of 70px rows, because on those faces a row is a setting
/// and a setting is a line. Here the thing being drawn is a *chain*, and a
/// chain answers six questions at once — a row would have to pick two of them
/// and bury the rest behind a disclosure. So this stays in the Signal feature
/// until a second domain asks for it, which is the rule `console_surface.dart`
/// has followed since Network.
///
/// The card is 202 wide on the three list tabs and full width on master (one
/// card, so nothing to sit beside). Height is **content-driven**: the mockups
/// draw 196 with a one-line chain summary and 215 with a two-line one, which
/// is one card whose fifth row wraps inside its 166px measure, not two sizes.
///
/// Not interactive yet. Selection, and the panel it opens, are the next PR of
/// this slice; a card that highlighted with nothing to show would be a state
/// with no consequence.
class SignalCard extends StatelessWidget {
  /// Creates a [SignalCard].
  const SignalCard({
    required this.name,
    required this.coordinate,
    required this.routesTo,
    required this.rack,
    required this.summary,
    this.monitor,
    this.width = defaultWidth,
    super.key,
  });

  /// The chain's name — the track's, the input's, or `master out`.
  final String name;

  /// Where it sits: `track 3 · lane A`, `input 1`, `main`. Set in the mono
  /// face, because it is a coordinate rather than a name someone chose.
  final String coordinate;

  /// What it feeds, drawn after an arrow: `mix`, `recorder`, `outputs`.
  final String routesTo;

  /// The loaded rack's name, or `no rack`.
  final String rack;

  /// The rack's chain in one line, or `tap to load one`.
  final String summary;

  /// The monitor line, or null to omit the row entirely.
  ///
  /// **Absence is modelled, not defaulted.** A card with no rack has no chain
  /// to hear and so draws no monitor line at all — the mockups give the vacant
  /// `bass` card five children where `rhythm` has six. An *input* card is the
  /// exception and always passes one: whether you hear yourself is a fact
  /// about the jack, not about the chain on it.
  final SignalMonitorLine? monitor;

  /// The card's width. Full width on the master tab, where there is one card.
  final double? width;

  /// Width on the three list tabs, as the mockups draw it.
  static const double defaultWidth = 202;

  /// Gap between two cards in a row.
  static const double gap = 12;

  /// Inside padding.
  static const double padding = 18;

  /// Gap between two facts.
  static const double rowGap = 10;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final line = monitor;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: surface.cardHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: surface.line),
      ),
      padding: const EdgeInsets.all(padding - 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: rowGap,
        children: [
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 18,
              height: 1.17,
              leadingDistribution: TextLeadingDistribution.even,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            coordinate,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: surface.textMuted,
              fontFamily: SurfaceTheme.monoFont,
              fontSize: 13,
              height: 1.15,
              letterSpacing: 0.26,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
          _RoutingLine(label: routesTo),
          Text(
            rack,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: surface.textMuted,
              fontSize: 16,
              height: 1.13,
              leadingDistribution: TextLeadingDistribution.even,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            summary,
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 14,
              height: 1.35,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
          if (line != null)
            Text(
              line.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                // ON and AUTO are both "you will hear this", so both take the
                // accent; OFF recedes to the muted ink the card's other
                // secondary facts are set in.
                color: line.audible ? surface.accent : surface.textMuted,
                fontSize: 13,
                height: 1.23,
                letterSpacing: 0.78,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
        ],
      ),
    );
  }
}

/// A card's monitor row: what it says, and whether it says something audible.
class SignalMonitorLine {
  /// Creates a [SignalMonitorLine].
  const SignalMonitorLine({required this.label, required this.audible});

  /// `MONITOR: ON` / `AUTO` / `OFF`.
  final String label;

  /// Whether this mode can put the input in the monitor path — true for both
  /// ON and AUTO, since AUTO's answer depends on the arm rather than on the
  /// setting, and a line that greyed out while armed would contradict itself.
  final bool audible;
}

/// `→ mix` — the arrow and what it points at, on one baseline.
class _RoutingLine extends StatelessWidget {
  const _RoutingLine({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 5,
      children: [
        Text(
          '→',
          style: TextStyle(
            color: surface.textMuted,
            fontSize: 14,
            height: 1.21,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: surface.textMuted,
              fontSize: 13,
              height: 1.23,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
        ),
      ],
    );
  }
}

/// The pill under the tab strip saying what editing on this tab *costs*.
///
/// Two tones, and the difference is the whole point of the face: a chain on
/// the loop, track or master stage only changes what you hear, while an input
/// chain is copied onto the lane at record and so changes what new takes will
/// store. That is `FxScope.consequence`'s own distinction, set as a pill
/// instead of as the prose the FX dock carried it in.
class SignalScopeChip extends StatelessWidget {
  /// Creates a [SignalScopeChip].
  const SignalScopeChip({
    required this.label,
    required this.printed,
    super.key,
  });

  /// The chip's text.
  final String label;

  /// Whether this stage prints into the take — the record tone.
  final bool printed;

  /// The chip's height, as the mockups draw it.
  static const double height = 24;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: printed ? surface.recDeep : surface.control,
        borderRadius: BorderRadius.circular(height),
        border: Border.all(
          color: printed ? surface.rec : surface.borderStrong,
        ),
      ),
      child: Center(
        widthFactor: 1,
        child: Transform.translate(
          offset: const Offset(0, 1),
          child: Text(
            label,
            style: TextStyle(
              color: printed ? surface.rec : surface.textSecondary,
              fontSize: 12,
              height: 1.5,
              letterSpacing: 0.72,
              leadingDistribution: TextLeadingDistribution.even,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
