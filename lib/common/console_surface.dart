/// The console's shared row/card vocabulary, drawn to the mockups.
///
/// Every tray domain is the same surface with different nouns — a card of
/// 70px rows, each `title / subtitle` on the left and `value ›` on the right,
/// one of which can open to reveal its actions. Faces build from these pieces
/// rather than each drawing its own, so the tabs of one domain cannot drift
/// apart the way the two former radio panels had, and one domain cannot drift
/// from the next.
///
/// Named for the console rather than a domain since the Control face (#516)
/// became the second caller; it started life as the Network domain's own.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// Row height from the mockups (`row-h`). Big enough to hit while standing
/// over a floor console.
const double kConsoleRowHeight = 70;

/// Card corner radius for the tray faces.
const double _cardRadius = 12;

/// A card wrapping a group of [ConsoleRow]s.
///
/// The 1px inset is the mockups' own: rows paint their hairline edge-to-edge,
/// and the inset keeps that hairline inside the rounded corner instead of
/// cutting across it.
class ConsoleCard extends StatelessWidget {
  /// Creates a [ConsoleCard].
  const ConsoleCard({required this.children, this.bordered = false, super.key});

  /// The rows.
  final List<Widget> children;

  /// Whether to draw the outer border. The mockups border the Bluetooth
  /// visibility card and leave the primary list of a face unbordered.
  final bool bordered;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface.cardHigh,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: bordered ? Border.all(color: surface.line) : null,
      ),
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_cardRadius - 1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// One row of a [ConsoleCard]: `title / subtitle` with a right-hand value and
/// a disclosure marker.
///
/// The marker is part of the row rather than a per-item decision — the
/// mockups reserve the gutter for every row in a group so the titles of rows
/// that have no chevron still line up with those that do.
class ConsoleRow extends StatelessWidget {
  /// Creates a [ConsoleRow].
  const ConsoleRow({
    required this.title,
    this.subtitle,
    this.value,
    this.onTap,
    this.trailing,
    this.expanded = false,
    this.showDisclosure = true,
    this.divider = true,
    this.selected = false,
    this.indented = false,
    this.centred = false,
    this.leading,
    this.valueColor,
    super.key,
  });

  /// Primary label — an SSID, a device name, or a setting.
  final String title;

  /// Secondary line: the address, the signal, why it cannot be joined.
  final String? subtitle;

  /// Right-hand status word ("connected", "saved", "open").
  final String? value;

  /// Tapping opens the row. Null makes it inert (but still readable).
  final VoidCallback? onTap;

  /// Replaces the value + disclosure pair — used by the switch rows.
  final Widget? trailing;

  /// Whether this row is the open one, which turns the marker downwards.
  final bool expanded;

  /// Whether to reserve the disclosure gutter at all.
  final bool showDisclosure;

  /// Whether to paint the bottom hairline. False on a group's last row.
  final bool divider;

  /// Whether this row is the current choice in a pick list — tinted, the way
  /// the mockups mark the target a switch already drives.
  final bool selected;

  /// Whether to indent the title, for a row that belongs INSIDE the row above
  /// it (an effect within a rack).
  final bool indented;

  /// Whether to centre the title instead of aligning it left. For a row that
  /// is an action rather than an item — "Show individual effects".
  final bool centred;

  /// Optional glyph before the title — a state dot, in the mockups.
  final Widget? leading;

  /// Overrides the value's colour. A missing target takes the warning tone:
  /// in the muted grey of an empty slot it reads as "nothing set here", which
  /// is a different (and wrong) fact.
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final line = subtitle;
    final status = value;

    final content = Padding(
      padding: EdgeInsets.fromLTRB(indented ? 42 : 20, 14, 20, 15),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: centred
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: centred
                        ? surface.textSecondary
                        : surface.textPrimary,
                    fontSize: 17,
                    // Tight leading, from the mockups: title + subtitle have
                    // to clear 41px between the row's 14/15 padding, which
                    // Roboto's default 1.4 line height does not.
                    height: 1.2,
                  ),
                ),
                if (line != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: surface.textMuted,
                      fontSize: 14,
                      height: 1.2,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null)
            Padding(
              padding: const EdgeInsets.only(left: 14),
              child: trailing,
            )
          else ...[
            if (status != null)
              Padding(
                padding: const EdgeInsets.only(left: 14),
                child: Text(
                  status,
                  style: TextStyle(
                    color: valueColor ?? surface.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ),
            if (showDisclosure)
              Padding(
                padding: const EdgeInsets.only(left: 14),
                child: ConsoleDisclosure(expanded: expanded),
              ),
          ],
        ],
      ),
    );

    final row = SizedBox(
      height: kConsoleRowHeight,
      child: onTap == null
          ? content
          // Scopes the ink to this row. Without a Material of its own the
          // splash paints on whatever Material is above the tray, which the
          // card's own fill then hides — a tap with no feedback at all.
          : Material(
              type: MaterialType.transparency,
              child: InkWell(onTap: onTap, child: content),
            ),
    );

    // One animated box for BOTH the selection tint and the hairline, and the
    // hairline goes while the row is open.
    //
    // Both used to be hard switches: the line under a row vanished on the
    // frame the row was tapped and came back the frame it shut, flashing
    // across a card whose tint was still fading. Painted as a
    // `foregroundDecoration` so the 1px line never insets the row.
    return AnimatedContainer(
      duration: consoleMotion(context),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: selected ? surface.accentSurface : Colors.transparent,
      ),
      foregroundDecoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: divider && !expanded
                ? surface.borderHairline
                : Colors.transparent,
          ),
        ),
      ),
      child: row,
    );
  }
}

/// The row disclosure marker: a small solid triangle, pointing right while the
/// row is closed and down while it is open.
class ConsoleDisclosure extends StatelessWidget {
  /// Creates a [ConsoleDisclosure].
  const ConsoleDisclosure({required this.expanded, super.key});

  /// Whether the row it belongs to is open.
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return AnimatedRotation(
      duration: consoleMotion(context),
      curve: Curves.easeOutCubic,
      turns: expanded ? 0.25 : 0,
      child: Icon(
        Icons.arrow_right,
        size: 18,
        color: context.surface.textMuted,
      ),
    );
  }
}

/// An opened row: the row itself over a right-aligned strip of its actions,
/// the pair tinted and lifted out of the list as one card.
class ConsoleExpandedRow extends StatelessWidget {
  /// Creates a [ConsoleExpandedRow].
  const ConsoleExpandedRow({
    required this.row,
    required this.actions,
    this.expanded = true,
    this.onTap,
    super.key,
  });

  /// The row, built with the same `expanded` flag so its disclosure marker
  /// turns in step with the strip opening.
  final Widget row;

  /// Action chips, in reading order. Built only while [expanded]; the strip
  /// animates down to nothing when they go.
  final List<Widget> actions;

  /// Whether the actions are showing.
  ///
  /// Kept as a flag rather than swapping this widget in and out at the call
  /// site: a row that only exists while open cannot animate INTO existence,
  /// and the tint would snap on a frame before the strip started moving.
  final bool expanded;

  /// Toggles the row.
  ///
  /// Held HERE rather than on [row] so the press lights the whole card. An
  /// ink well only ever splashes within its own box, so a tap handled by the
  /// row would leave the strip below it dark — the card would light in two
  /// halves. The chips have ink of their own and swallow their own taps.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final motion = consoleMotion(context);
    return AnimatedContainer(
      duration: motion,
      curve: expanded ? Curves.easeOutCubic : Curves.easeInCubic,
      decoration: BoxDecoration(
        color: expanded ? surface.control : Colors.transparent,
        borderRadius: BorderRadius.circular(_cardRadius),
      ),
      // The border is painted OVER the row, not around it. A border in
      // `decoration` insets whatever it wraps, so the title and its chips
      // would step a pixel sideways and back every time the row opened —
      // which is exactly the kind of movement an open should not have.
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(
          color: expanded ? surface.borderSubtle : Colors.transparent,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        // Clipped to the card, so a splash never squares off its corners.
        borderRadius: BorderRadius.circular(_cardRadius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(_cardRadius),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              row,
              ConsoleExpansion(
                expanded: expanded,
                child: Padding(
                  key: const Key('console_row_actions'),
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      for (final action in actions) ...[
                        if (action != actions.first) const SizedBox(width: 10),
                        action,
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How long an open/close takes on the console's surfaces.
///
/// One value, because a row whose tint arrives at a different speed from the
/// strip inside it reads as two things happening rather than one.
const Duration kConsoleMotion = Duration(milliseconds: 180);

/// [kConsoleMotion], or nothing where the platform asks for no motion.
Duration consoleMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : kConsoleMotion;

/// Grows [child] in from nothing and shrinks it away again.
///
/// Height only: the width is the row's, and animating that too would drag the
/// card's edge around. The content is clipped while it moves, so a chip strip
/// slides out from under the row it belongs to rather than overflowing it.
///
/// Stateful rather than an [AnimatedSize] over a swapped child, because
/// closing has to animate too: a caller that stops building its actions the
/// moment a row shuts would leave this shrinking an empty box, which reads as
/// the chips vanishing and the gap collapsing afterwards. The last child is
/// held for exactly as long as the close takes, then dropped — so a shut row
/// has nothing of its own in the tree, and nothing tappable.
class ConsoleExpansion extends StatefulWidget {
  /// Creates a [ConsoleExpansion].
  const ConsoleExpansion({
    required this.expanded,
    required this.child,
    super.key,
  });

  /// Whether [child] is showing.
  final bool expanded;

  /// The block that grows and shrinks.
  final Widget child;

  @override
  State<ConsoleExpansion> createState() => _ConsoleExpansionState();
}

class _ConsoleExpansionState extends State<ConsoleExpansion>
    with SingleTickerProviderStateMixin {
  /// Built in [initState], not as a `late final` initialiser: a lazy field is
  /// created on first TOUCH, and a row that closes without ever having opened
  /// touches it first in [dispose] — where creating a ticker looks up
  /// `TickerMode` on an element that is already going away.
  late final AnimationController _controller;

  /// Opens fast and settles; closes without the overshooting ease-out, which
  /// on the way back looks like the strip hesitating before it goes.
  late final CurvedAnimation _size;

  /// The content fades over the back half of the growth and the front half of
  /// the shrink, so it is never fully lit while the box is still short.
  late final CurvedAnimation _fade;

  /// The child to keep drawing while closing. Null once the close finishes.
  Widget? _closing;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: kConsoleMotion,
      value: widget.expanded ? 1 : 0,
    );
    _size = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _fade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.35, 1),
      reverseCurve: const Interval(0.45, 1),
    );
  }

  @override
  void didUpdateWidget(ConsoleExpansion old) {
    super.didUpdateWidget(old);
    if (widget.expanded == old.expanded) return;
    if (widget.expanded) {
      _closing = null;
      unawaited(_controller.forward());
    } else {
      // Hold what was showing so the close has something to shrink.
      _closing = old.child;
      unawaited(
        _controller.reverse().whenComplete(() {
          if (mounted) setState(() => _closing = null);
        }),
      );
    }
  }

  @override
  void dispose() {
    _size.dispose();
    _fade.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = widget.expanded ? 1 : 0;
    }
    final child = widget.expanded ? widget.child : _closing;
    if (child == null) return const SizedBox(width: double.infinity);
    return ClipRect(
      child: SizeTransition(
        sizeFactor: _size,
        // Anchored to the top: the strip slides out from under its row rather
        // than growing from the middle.
        alignment: Alignment.topCenter,
        child: FadeTransition(opacity: _fade, child: child),
      ),
    );
  }
}

/// A pill button inside an opened row — Disconnect, Forget, Connect.
class ConsoleActionChip extends StatelessWidget {
  /// Creates a [ConsoleActionChip].
  const ConsoleActionChip({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
    super.key,
  });

  /// Button text.
  final String label;

  /// Leading glyph.
  final IconData icon;

  /// Null disables the chip while the radio is busy.
  final VoidCallback? onPressed;

  /// Draws the chip in the record red — used by Forget, which deletes
  /// credentials.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final tint = destructive ? surface.rec : surface.textSecondary;
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: surface.cardHigh,
        shape: StadiumBorder(
          side: BorderSide(color: destructive ? surface.recLine : surface.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: tint),
                const SizedBox(width: 10),
                Text(label, style: TextStyle(color: tint, fontSize: 14)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The face's title row: the radio's name, an optional live status beside it,
/// and the rescan + power controls.
///
/// Power lives here rather than in the list because it governs whether there
/// is a list at all — switched off, this row is the entire face.
class ConsoleFaceHeader extends StatelessWidget {
  /// Creates a [ConsoleFaceHeader].
  const ConsoleFaceHeader({
    required this.title,
    required this.powered,
    required this.onPoweredChanged,
    this.status,
    this.onRescan,
    this.scanning = false,
    this.rescanKey,
    this.powerKey,
    super.key,
  });

  /// "WiFi" / "Bluetooth".
  final String title;

  /// Live status beside the title ("joining Studio 5G", "could not join …").
  final String? status;

  /// Radio state.
  final bool powered;

  /// Null while a power change is in flight.
  final ValueChanged<bool>? onPoweredChanged;

  /// Null hides the rescan button entirely — as the mockups do while the
  /// radio is off.
  final VoidCallback? onRescan;

  /// Spins the rescan glyph.
  final bool scanning;

  /// Key for the rescan button.
  final Key? rescanKey;

  /// Key for the power switch.
  final Key? powerKey;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final line = status;
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (line != null) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                line,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: surface.textMuted, fontSize: 14),
              ),
            ),
          ],
          const Spacer(),
          if (onRescan != null) ...[
            _RescanButton(
              key: rescanKey,
              onPressed: onRescan,
              scanning: scanning,
            ),
            const SizedBox(width: 10),
          ],
          ConsoleSwitch(
            key: powerKey,
            value: powered,
            onChanged: onPoweredChanged,
          ),
        ],
      ),
    );
  }
}

class _RescanButton extends StatelessWidget {
  const _RescanButton({
    required this.onPressed,
    required this.scanning,
    super.key,
  });

  final VoidCallback? onPressed;
  final bool scanning;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Tooltip(
      message: l10n.networkRescanTooltip,
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: surface.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: scanning ? null : onPressed,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Center(
              child: scanning
                  ? SizedBox(
                      width: 19,
                      height: 19,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: surface.textSecondary,
                      ),
                    )
                  : Icon(
                      Icons.refresh,
                      size: 19,
                      color: surface.textSecondary,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The console's switch: a 53x31 pill with a 25px knob.
///
/// Hand-drawn rather than Material's `Switch`, which carries its own 40x24
/// geometry, ripple and thumb elevation — none of which the mockups have, and
/// all of which read as borrowed once the switch sits in a list row.
class ConsoleSwitch extends StatelessWidget {
  /// Creates a [ConsoleSwitch].
  const ConsoleSwitch({
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    super.key,
  });

  /// On/off.
  final bool value;

  /// Null disables the switch (busy, or unsupported).
  final ValueChanged<bool>? onChanged;

  /// Accessible name, since the switch carries no visible label of its own.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final enabled = onChanged != null;
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: semanticLabel,
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: GestureDetector(
          onTap: enabled ? () => onChanged!(!value) : null,
          child: AnimatedContainer(
            duration: consoleMotion(context),
            curve: Curves.easeOutCubic,
            width: 53,
            height: 31,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: value ? surface.accent : surface.control,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: value ? surface.accent : surface.line),
            ),
            child: AnimatedAlign(
              duration: consoleMotion(context),
              curve: Curves.easeOutCubic,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 25,
                height: 25,
                decoration: BoxDecoration(
                  color: value ? surface.onAccent : surface.textSecondary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The banner that rides at the top of the list while something is in flight
/// or has just failed: a state dot, the message, and the one action that
/// answers it.
class ConsoleBanner extends StatelessWidget {
  /// Creates a [ConsoleBanner].
  const ConsoleBanner({
    required this.message,
    required this.actionLabel,
    required this.onAction,
    this.failed = false,
    this.actionKey,
    this.secondaryLabel,
    this.onSecondary,
    super.key,
  });

  /// What is happening, in a sentence.
  final String message;

  /// The action's label — Cancel while in flight, Try again after a failure.
  final String actionLabel;

  /// Runs the action.
  final VoidCallback onAction;

  /// Colours the dot red rather than amber.
  final bool failed;

  /// Key for the action button.
  final Key? actionKey;

  /// A second, affirmative action beside the first — the replace prompt's
  /// "Replace" against its "Keep".
  final String? secondaryLabel;

  /// Runs [secondaryLabel]'s action.
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return DecoratedBox(
      decoration: BoxDecoration(color: surface.background),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 14, 20, 14),
        child: Row(
          children: [
            Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: failed ? surface.rec : surface.warning,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: surface.textSecondary, fontSize: 16),
              ),
            ),
            const SizedBox(width: 14),
            if (secondaryLabel != null) ...[
              ConsoleSmallButton(
                label: secondaryLabel!,
                onPressed: onSecondary,
              ),
              const SizedBox(width: 10),
            ],
            ConsoleSmallButton(
              key: actionKey,
              label: actionLabel,
              onPressed: onAction,
            ),
          ],
        ),
      ),
    );
  }
}

/// A small bordered button — the banner's Cancel / Try again, and the join
/// sheet's Cancel.
class ConsoleSmallButton extends StatelessWidget {
  /// Creates a [ConsoleSmallButton].
  const ConsoleSmallButton({
    required this.label,
    required this.onPressed,
    this.large = false,
    super.key,
  });

  /// Button text.
  final String label;

  /// Runs the action.
  final VoidCallback? onPressed;

  /// The sheet's slightly larger form (40px tall, 15px label).
  final bool large;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Material(
      color: surface.cardHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: surface.borderStrong),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 14,
            vertical: large ? 10 : 7,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: large ? 15 : 14,
            ),
          ),
        ),
      ),
    );
  }
}

/// The face when there is nothing to list: a bordered, empty card carrying one
/// line of explanation.
class ConsoleEmptyCard extends StatelessWidget {
  /// Creates a [ConsoleEmptyCard].
  const ConsoleEmptyCard({required this.message, super.key});

  /// Why the list is empty.
  final String message;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(color: surface.line),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: surface.textSecondary, fontSize: 16),
          ),
        ),
      ),
    );
  }
}

/// Confirmation for an action that throws away a credential — forgetting a
/// network's passphrase, or a device's pairing.
///
/// Returns true when the destructive button is chosen. Disconnect has no
/// confirm of its own: it is undone by tapping the row again, while this is
/// not.
Future<bool> showConsoleForgetDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  Key? confirmKey,
}) async {
  final surface = context.surface;
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: surface.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(17),
        side: BorderSide(color: surface.borderStrong),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 528),
        child: Padding(
          padding: const EdgeInsets.all(25),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: surface.textPrimary,
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                body,
                style: TextStyle(color: surface.textSecondary, fontSize: 16),
              ),
              const SizedBox(height: 19),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ConsoleSmallButton(
                    label: l10n.networkKeepItAction,
                    large: true,
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                  ),
                  const SizedBox(width: 10),
                  _DestructiveButton(
                    key: confirmKey,
                    label: confirmLabel,
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return confirmed ?? false;
}

class _DestructiveButton extends StatelessWidget {
  const _DestructiveButton({
    required this.label,
    required this.onPressed,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Material(
      color: surface.rec,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text(
            label,
            style: TextStyle(
              color: surface.onAccent,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// A group heading above a card — the mockups' small, letter-spaced caption.
class ConsoleGroupLabel extends StatelessWidget {
  /// Creates a [ConsoleGroupLabel].
  const ConsoleGroupLabel(this.text, {super.key});

  /// The heading, rendered in caps.
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: context.surface.textMuted,
        fontSize: 13,
        letterSpacing: 1.2,
      ),
    );
  }
}

/// A labelled horizontal bar with a numeric readout — the console's form of a
/// calibration control (a MIDI mapping's travel or threshold).
///
/// A bar rather than a knob: these are set once with a finger on a touch
/// panel, and a knob's rotational gesture is the wrong shape for that. The
/// caret marks the value so the bar reads as a scale rather than a meter.
class ConsoleValueBar extends StatelessWidget {
  /// Creates a [ConsoleValueBar].
  const ConsoleValueBar({
    required this.label,
    required this.value,
    required this.readout,
    required this.onChanged,
    super.key,
  });

  /// Caption down the left — LO, HI, THRESH.
  final String label;

  /// Normalized `0..1` position.
  final double value;

  /// What the value is, in its own units.
  final String readout;

  /// Called with the new normalized value as the finger moves.
  final ValueChanged<double> onChanged;

  static const double _height = 44;
  static const double _labelWidth = 92;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Row(
      children: [
        SizedBox(
          width: _labelWidth,
          child: Text(
            label,
            style: TextStyle(
              color: surface.textMuted,
              fontSize: 13,
              letterSpacing: 0.6,
            ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              void report(Offset local) => onChanged(
                (local.dx / constraints.maxWidth).clamp(0.0, 1.0),
              );
              return Semantics(
                slider: true,
                label: label,
                value: readout,
                child: GestureDetector(
                  onTapDown: (details) => report(details.localPosition),
                  onHorizontalDragUpdate: (details) =>
                      report(details.localPosition),
                  child: Container(
                    height: _height,
                    decoration: BoxDecoration(
                      color: surface.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: surface.line),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: value.clamp(0.0, 1.0),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: surface.accentSurface,
                              border: Border(
                                right: BorderSide(color: surface.accent),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 14),
        SizedBox(
          width: 44,
          child: Text(
            readout,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 14,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// One choice in a [ConsoleSegmented].
@immutable
class ConsoleSegment<T> {
  /// Creates a [ConsoleSegment].
  const ConsoleSegment({required this.value, required this.label});

  /// The value this segment picks.
  final T value;

  /// Its caption.
  final String label;
}

/// A two-or-three-way choice drawn as adjoining pills — Toggle / Momentary.
///
/// Distinct from the tab strip, which navigates: this one sets a value, so the
/// selected segment is filled rather than tinted.
class ConsoleSegmented<T> extends StatelessWidget {
  /// Creates a [ConsoleSegmented].
  const ConsoleSegmented({
    required this.options,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  /// The choices, in display order.
  final List<ConsoleSegment<T>> options;

  /// The current value.
  final T selected;

  /// Called with the chosen value.
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final option in options) ...[
          if (option != options.first) const SizedBox(width: 8),
          Semantics(
            button: true,
            selected: option.value == selected,
            child: Material(
              color: option.value == selected
                  ? surface.accent
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => onChanged(option.value),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 17,
                    vertical: 10,
                  ),
                  child: Text(
                    option.label,
                    style: TextStyle(
                      color: option.value == selected
                          ? surface.onAccent
                          : surface.textSecondary,
                      fontSize: 16,
                      fontWeight: option.value == selected
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// One entry in a [showConsolePickerSheet].
@immutable
class ConsolePickerOption<T> {
  /// Creates a [ConsolePickerOption].
  const ConsolePickerOption({required this.value, required this.label});

  /// What choosing this returns.
  final T value;

  /// Its caption.
  final String label;
}

/// Asks for one of [options], as a sheet of the console's own rows.
///
/// Not `PopupMenuButton`: a Material menu opens a small floating card wherever
/// the tap landed, sized for a mouse. Every list in this tray is the same
/// 70px row on a card, and a target picker is a list like any other.
Future<T?> showConsolePickerSheet<T>(
  BuildContext context, {
  required String title,
  required List<ConsolePickerOption<T>> options,
  T? selected,
}) {
  final surface = context.surface;
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: surface.scrim,
    isScrollControlled: true,
    constraints: const BoxConstraints(),
    builder: (sheetContext) => DecoratedBox(
      decoration: BoxDecoration(
        color: surface.card,
        border: Border(top: BorderSide(color: surface.borderStrong)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(19, 20, 19, 19),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: surface.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 13),
              Flexible(
                child: SingleChildScrollView(
                  child: ConsoleCard(
                    children: [
                      for (final option in options)
                        ConsoleRow(
                          key: Key('console_picker_${option.label}'),
                          title: option.label,
                          selected: option.value == selected,
                          showDisclosure: false,
                          divider: option != options.last,
                          onTap: () =>
                              Navigator.of(sheetContext).pop(option.value),
                        ),
                    ],
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

/// The design system's `MiniToggleGroup`: a small bordered pair of segments,
/// the chosen one filled with the control tone rather than the accent.
///
/// Distinct from [ConsoleSegmented], which is the loud form used where the
/// choice IS the content (a mapping's Toggle/Momentary). This one is a
/// qualifier sitting beside a group caption — the pedal's A/B bank, the same
/// control the stage header uses — and shouting it in accent would outweigh
/// the group it labels.
class ConsoleMiniToggle<T> extends StatelessWidget {
  /// Creates a [ConsoleMiniToggle].
  const ConsoleMiniToggle({
    required this.options,
    required this.selected,
    required this.onChanged,
    this.semanticLabel,
    super.key,
  });

  /// The choices, in display order. Two or three at most: each segment is
  /// sized for a single character.
  final List<ConsoleSegment<T>> options;

  /// The current value.
  final T selected;

  /// Called with the chosen value.
  final ValueChanged<T> onChanged;

  /// Names what the group is choosing, since the segments are bare letters.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      label: semanticLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: surface.line),
        ),
        child: Padding(
          padding: const EdgeInsets.all(1),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in options)
                  Semantics(
                    button: true,
                    selected: option.value == selected,
                    child: Material(
                      color: option.value == selected
                          ? surface.control
                          : Colors.transparent,
                      child: InkWell(
                        onTap: () => onChanged(option.value),
                        child: SizedBox(
                          width: 38,
                          height: 31,
                          child: Center(
                            child: Text(
                              option.label,
                              style: TextStyle(
                                color: option.value == selected
                                    ? surface.textPrimary
                                    : surface.textMuted,
                                fontSize: 14,
                              ),
                            ),
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
