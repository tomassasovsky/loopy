/// The console's shared row/card vocabulary, drawn to the `NETWORK / *` and
/// `CONTROL / *` screens in `segno-ui.pen`.
///
/// Started life as `lib/network/network_surface.dart`, beside the one domain
/// that had it, so the two tabs of that domain could not drift apart the way
/// the two former tray panels had — one had a wrapping card and the other
/// deliberately did not, one used `SetupGroupLabel` and the other a bare
/// `Row`, and nothing but attention held them together. It moved here, and
/// dropped its `Network` prefix, the moment a second domain read from it: a
/// primitive named after one caller invites the next caller to copy it
/// instead.
///
/// **The rule this promotion set:** a primitive lives here once a second
/// domain reads it, and keeps no domain in its name.
///
/// Everything here is layout with two exceptions, [ConsoleSwitch] and
/// [ConsoleCard]'s inset; both carry their reasoning on the class.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// Height of one list row.
///
/// Fixed rather than intrinsic: a row is a touch target on a console operated
/// while standing over it, and a row that shrinks when its subtitle is absent
/// makes the target depend on the data.
const double kConsoleRowHeight = 70;

/// Horizontal inset of a row's content — also the left edge every title,
/// banner and switch in a card lines up on.
const double kConsoleRowInset = 20;

/// Width reserved for a row's disclosure marker.
const double kConsoleDisclosureWidth = 11;

/// The gap between a row's content and its trailing marks.
const double kConsoleRowGap = 14;

/// How long a row takes to open or shut.
///
/// One duration for every transition on this surface — the row growing, its
/// tint arriving, the marker turning — so a single tap reads as one movement
/// instead of three that happen to start together.
const Duration kConsoleMotion = Duration(milliseconds: 180);

/// [kConsoleMotion], or nothing where the platform asks for no motion.
Duration consoleMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : kConsoleMotion;

/// Grows [child] in from nothing and shrinks it away again.
///
/// Height only: the width is the row's, and animating that too would drag the
/// card's edge around. The content is clipped while it moves, so the action
/// strip slides out from under the row it belongs to rather than overflowing
/// it.
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

/// A group of rows: one rounded, bordered card with hairlines between rows.
///
/// The 1px inset is load-bearing rather than decorative. Rows paint their
/// own hairline edge to edge, and without the inset that hairline crosses the
/// rounded corner instead of stopping inside it.
class ConsoleCard extends StatelessWidget {
  /// Creates a [ConsoleCard].
  const ConsoleCard({required this.children, super.key});

  /// The rows, in display order.
  final List<Widget> children;

  /// Corner radius of the card.
  static const double radius = 12;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface.cardHigh,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: surface.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius - 1),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// The marker at a row's trailing edge saying the row does something.
///
/// `false` draws `▸` and `true` draws `▾`; **null** draws nothing and keeps
/// the space. The gutter is reserved **per group** rather than per row, so a
/// row without a marker still lines its trailing edge up with the rows that
/// have one — reserving per row instead makes a list's edge move as its
/// contents change state.
class ConsoleDisclosure extends StatelessWidget {
  /// Creates a [ConsoleDisclosure].
  ///
  /// [expanded] null draws nothing and keeps the space.
  const ConsoleDisclosure({this.expanded, super.key});

  /// Whether the row this marks is open; null when the row does not open.
  final bool? expanded;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final open = expanded;
    return SizedBox(
      width: kConsoleDisclosureWidth,
      child: open == null
          ? const SizedBox.shrink()
          : Text(
              open ? '▾' : '▸',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: surface.textMuted,
                fontFamily: SurfaceTheme.monoFont,
                fontSize: 13,
                height: 1.15,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
    );
  }
}

/// One row: `title / subtitle` on the left, an optional readout and a
/// disclosure marker on the right.
///
/// Two kinds of readout, because the mockups set them in two faces and mean
/// two things by them. [state] is a single lower-case word (`connected`,
/// `saved`, `sweep`, `switch`) in the mono face — a machine readout ABOUT the
/// row. [value] is a name the user recognises (`Dirty rhythm`, `Nektar
/// Pacer`) and is set in the text face like everything else they typed.
class ConsoleRow extends StatelessWidget {
  /// Creates a [ConsoleRow].
  const ConsoleRow({
    required this.title,
    this.subtitle,
    this.state,
    this.value,
    this.valueColor,
    this.titleColor,
    this.leading,
    this.mark,
    this.expanded,
    this.showDisclosure = true,
    this.trailing,
    this.fill,
    this.indented = false,
    this.onTap,
    this.showDivider = true,
    this.semanticLabel,
    super.key,
  });

  /// Left-hand primary line.
  final String title;

  /// Left-hand secondary line. Omitted entirely when null — an unknown fact
  /// is not drawn as a blank one.
  final String? subtitle;

  /// The mono readout word at the trailing edge, if the row has one.
  final String? state;

  /// The proportional readout at the trailing edge — a name rather than a
  /// state word. Drawn after [state] when a row carries both.
  final String? value;

  /// Tint for [state] and [value]; defaults to [SurfaceTheme.textSecondary].
  /// A binding whose target is gone passes the warning tone here — rendering
  /// it in the muted grey of "unassigned" would state a different and wrong
  /// fact.
  final Color? valueColor;

  /// Tint for [title]; defaults to [SurfaceTheme.textPrimary].
  final Color? titleColor;

  /// A glyph ahead of the title.
  final Widget? leading;

  /// A glyph after the readout — the check on the target a switch is already
  /// bound to. A **check, not a tint**: tint already means "the row you
  /// opened" on this surface, and one mark cannot carry two meanings.
  final Widget? mark;

  /// Disclosure state; null for a row that shows no marker at all. See
  /// [ConsoleDisclosure] for why every row in a group passes one.
  final bool? expanded;

  /// Whether to reserve the disclosure gutter at all. False for a list where
  /// **no** row opens — the assign list acts on the tap — so its readouts sit
  /// against the card edge instead of against an empty column.
  final bool showDisclosure;

  /// A control that replaces the readouts and the marker — a [ConsoleSwitch],
  /// for a row that IS a setting rather than a thing that opens.
  final Widget? trailing;

  /// The row's own fill: [SurfaceTheme.accentSurface] for the switch being
  /// assigned, [SurfaceTheme.control] for a mapping opened in place. Animated,
  /// so a tap tints the row rather than repainting it between two frames.
  final Color? fill;

  /// Whether this row is one step in — an effect slot listed under the chain
  /// it belongs to.
  final bool indented;

  /// Tap action, or null for a row that is only a readout.
  final VoidCallback? onTap;

  /// Whether to paint the hairline below. False on the last row of a card.
  final bool showDivider;

  /// Overrides the announced label; defaults to title + subtitle + readouts.
  final String? semanticLabel;

  /// Left inset of an [indented] row.
  static const double indentedInset = 40;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final label =
        semanticLabel ??
        [title, subtitle, state, value].whereType<String>().join(', ');
    final readout = valueColor ?? surface.textSecondary;

    final row = AnimatedContainer(
      duration: consoleMotion(context),
      curve: Curves.easeOut,
      height: kConsoleRowHeight,
      padding: EdgeInsets.only(
        left: indented ? indentedInset : kConsoleRowInset,
        right: kConsoleRowInset,
      ),
      // Transparent rather than absent while untinted, so the colour lerps
      // instead of the box being rebuilt without one.
      decoration: BoxDecoration(color: fill ?? surface.control.withAlpha(0)),
      // The hairline is painted OVER the row, not around it: a border in
      // `decoration` insets what it wraps, so a divider that comes and goes
      // with an open row would step the content half a pixel each way.
      foregroundDecoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: showDivider ? surface.borderHairline : Colors.transparent,
          ),
        ),
      ),
      child: Row(
        children: [
          if (leading case final glyph?) ...[
            glyph,
            const SizedBox(width: kConsoleRowGap),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: titleColor ?? surface.textPrimary,
                    fontSize: 17,
                    height: 1.18,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                ),
                if (subtitle case final sub?) ...[
                  const SizedBox(height: 2),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: surface.textMuted,
                      fontSize: 14,
                      height: 1.21,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing case final control?) ...[
            const SizedBox(width: kConsoleRowGap),
            control,
          ] else ...[
            if (state case final word?) ...[
              const SizedBox(width: kConsoleRowGap),
              Text(
                word,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: readout,
                  fontFamily: SurfaceTheme.monoFont,
                  fontSize: 14,
                  height: 1.14,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
            ],
            if (value case final name?) ...[
              const SizedBox(width: kConsoleRowGap),
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: readout,
                    fontSize: 14,
                    height: 1.21,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                ),
              ),
            ],
            if (mark case final glyph?) ...[
              const SizedBox(width: kConsoleRowGap),
              glyph,
            ],
            if (showDisclosure) ...[
              const SizedBox(width: kConsoleRowGap),
              ConsoleDisclosure(expanded: expanded),
            ],
          ],
        ],
      ),
    );

    if (onTap == null) {
      return Semantics(label: label, child: row);
    }
    return FocusableTapTarget(
      onTap: onTap,
      semanticLabel: label,
      child: InkWell(onTap: onTap, child: row),
    );
  }
}

/// The caption over a group of rows — `TRANSPORT SWITCHES`, `MIDI FOOT
/// CONTROLLER`.
///
/// Upper-cased by the caller through its own string, not by this widget: a
/// locale where the group name is not upper-cased must be able to say so, and
/// `toUpperCase()` here would take that away.
class ConsoleGroupLabel extends StatelessWidget {
  /// Creates a [ConsoleGroupLabel].
  const ConsoleGroupLabel(this.label, {super.key});

  /// The caption.
  final String label;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Text(
      label,
      style: TextStyle(
        color: surface.textMuted,
        fontSize: 13,
        height: 1.23,
        // The mockups set these captions at 1.2 on one tab and 0.91 on the
        // other. One value, since a caption is one thing: the wider tracking
        // is what three of the five screens carry.
        letterSpacing: 1.2,
        leadingDistribution: TextLeadingDistribution.even,
      ),
    );
  }
}

/// A sentence of explanation under a group label — what the group is for, or
/// what the protocol below it says.
class ConsoleProse extends StatelessWidget {
  /// Creates a [ConsoleProse].
  const ConsoleProse(this.text, {super.key});

  /// The sentence.
  final String text;

  /// The width the mockups wrap this prose at. Left free rather than
  /// stretched to the pane: a 1700px measure is unreadable, and the mockups
  /// wrap it well short of the edge.
  static const double maxWidth = 923;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxWidth),
      child: Text(
        text,
        style: TextStyle(
          color: surface.textMuted,
          fontSize: 14,
          height: 1.5,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
    );
  }
}

/// A row that can open in place: the row itself over a tinted, bordered card
/// of its actions.
///
/// Rows open **in place**, one at a time. A tap that pushes a sheet loses the
/// list it came from, and on a console the list is the context for the action.
///
/// Always in the tree, open or shut, so opening is a transition rather than a
/// swap. Building the shut state as a bare row and the open state as this
/// widget makes the tint, the border and the whole action strip appear between
/// two frames, which on a 70px row reads as the list jolting.
class ConsoleExpandedRow extends StatelessWidget {
  /// Creates a [ConsoleExpandedRow].
  const ConsoleExpandedRow({
    required this.row,
    required this.actions,
    this.expanded = true,
    super.key,
  });

  /// The row, drawn with `expanded: true` when this is open.
  final Widget row;

  /// The action chips, laid out at the trailing edge.
  final List<Widget> actions;

  /// Whether the actions are showing.
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return AnimatedContainer(
      duration: consoleMotion(context),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        // Transparent rather than absent while shut: a null decoration would
        // rebuild the box on every open and lose the colour lerp.
        color: expanded ? surface.control : surface.control.withAlpha(0),
        borderRadius: BorderRadius.circular(ConsoleCard.radius),
        border: Border.all(
          color: expanded ? surface.borderSubtle : Colors.transparent,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row,
          ConsoleExpansion(
            expanded: expanded,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                kConsoleRowInset,
                0,
                kConsoleRowInset,
                14,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final (index, action) in actions.indexed) ...[
                    if (index > 0) const SizedBox(width: 10),
                    action,
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One action inside an opened row: a pill with an icon and a label.
///
/// [destructive] recolours the outline and the label rather than filling the
/// pill — a filled red chip inside a list row reads as a state the row is in.
class ConsoleActionChip extends StatelessWidget {
  /// Creates a [ConsoleActionChip].
  const ConsoleActionChip({
    required this.label,
    required this.onPressed,
    this.icon,
    this.destructive = false,
    super.key,
  });

  /// Visible caption.
  final String label;

  /// Leading glyph, or null for a chip that is only a word — the mapping
  /// editor's Relearn / Remove, where the pair sits under a control the row
  /// already names and a second glyph adds nothing to read.
  final IconData? icon;

  /// Tap action; null disables the chip.
  final VoidCallback? onPressed;

  /// Whether this action destroys something.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final tint = destructive ? surface.rec : surface.textSecondary;
    final edge = destructive ? surface.recLine : surface.line;
    return Opacity(
      opacity: onPressed == null ? surface.disabledOpacity : 1,
      child: FocusableTapTarget(
        onTap: onPressed,
        semanticLabel: label,
        borderRadius: 999,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            decoration: BoxDecoration(
              color: surface.cardHigh,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: edge),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon case final glyph?) ...[
                  Icon(glyph, size: 17, color: tint),
                  const SizedBox(width: 10),
                ],
                Text(
                  label,
                  style: TextStyle(
                    color: tint,
                    fontSize: 14,
                    height: 1.21,
                    leadingDistribution: TextLeadingDistribution.even,
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

/// A domain face's title row: its name, an optional live-state line, and that
/// surface's own controls.
///
/// The domain says its name **here**, not in a chrome bar above the tab strip.
/// The rail is always on screen, so a chrome bar would be a second navigation
/// surface, and a per-tab control (a rescan, a power switch) belongs to the
/// tab rather than to the domain — which puts the tabs first and the title
/// under them.
class ConsoleFaceHeader extends StatelessWidget {
  /// Creates a [ConsoleFaceHeader].
  const ConsoleFaceHeader({
    required this.title,
    this.status,
    this.actions = const [],
    super.key,
  });

  /// The face's name.
  final String title;

  /// A live-state line beside the title — "joining Studio 5G", "could not
  /// pair with AirTurn BT-200". Echoes what the banner says, at the one place
  /// the eye is already on.
  final String? status;

  /// The face's own controls, at the trailing edge.
  final List<Widget> actions;

  /// Height of the row; the rescan button's own height, so the title's
  /// baseline does not move when the button appears.
  static const double height = 38;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return SizedBox(
      height: height,
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 20,
              height: 1.15,
              leadingDistribution: TextLeadingDistribution.even,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: status == null
                ? const SizedBox.shrink()
                : Text(
                    status!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: surface.textMuted,
                      fontSize: 14,
                      height: 1.21,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                  ),
          ),
          for (final (index, action) in actions.indexed) ...[
            if (index > 0) const SizedBox(width: 10),
            action,
          ],
        ],
      ),
    );
  }
}

/// A square icon button for a face header — the rescan control.
///
/// Spins the glyph rather than swapping in a `CircularProgressIndicator`: the
/// control and its own busy state are the same object, so the button does not
/// move or resize when a scan starts.
class ConsoleIconButton extends StatefulWidget {
  /// Creates a [ConsoleIconButton].
  const ConsoleIconButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.spinning = false,
    super.key,
  });

  /// The glyph.
  final IconData icon;

  /// Tap action; null disables the button.
  final VoidCallback? onPressed;

  /// Hover/long-press explanation, and the announced label.
  final String tooltip;

  /// Whether the glyph should turn.
  final bool spinning;

  @override
  State<ConsoleIconButton> createState() => _ConsoleIconButtonState();
}

class _ConsoleIconButtonState extends State<ConsoleIconButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.spinning) unawaited(_spin.repeat());
  }

  @override
  void didUpdateWidget(ConsoleIconButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.spinning == oldWidget.spinning) return;
    if (widget.spinning) {
      unawaited(_spin.repeat());
    } else {
      _spin
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Tooltip(
      message: widget.tooltip,
      child: Opacity(
        opacity: widget.onPressed == null ? surface.disabledOpacity : 1,
        child: FocusableTapTarget(
          onTap: widget.onPressed,
          semanticLabel: widget.tooltip,
          borderRadius: 10,
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: surface.line),
              ),
              child: RotationTransition(
                turns: _spin,
                child: Icon(
                  widget.icon,
                  size: 19,
                  color: surface.textSecondary,
                ),
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
/// Hand-drawn rather than Material's [Switch], which brings its own 40x24
/// geometry, ripple and thumb elevation — none of which the mockups have, and
/// all of which read as borrowed once the switch is sitting in a list row
/// beside a hand-drawn card. #498 also settles that a boolean is a switch and
/// never the words "on" and "off".
class ConsoleSwitch extends StatelessWidget {
  /// Creates a [ConsoleSwitch].
  const ConsoleSwitch({
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    super.key,
  });

  /// Whether the switch is on.
  final bool value;

  /// Called with the new value; null disables the switch.
  final ValueChanged<bool>? onChanged;

  /// The announced label.
  final String? semanticLabel;

  /// Track size.
  static const Size trackSize = Size(53, 31);

  /// Knob diameter.
  static const double knobSize = 25;

  static const double _inset = 3;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final changed = onChanged;
    final pill = Opacity(
      opacity: changed == null ? surface.disabledOpacity : 1,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        width: trackSize.width,
        height: trackSize.height,
        decoration: BoxDecoration(
          color: value ? surface.accent : surface.control,
          borderRadius: BorderRadius.circular(trackSize.height),
          border: Border.all(color: value ? surface.accent : surface.line),
        ),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              top: _inset - 1,
              left: value
                  ? trackSize.width - knobSize - _inset - 1
                  : _inset - 1,
              child: Container(
                width: knobSize,
                height: knobSize,
                decoration: BoxDecoration(
                  color: value ? surface.onAccent : surface.textSecondary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Semantics(
      toggled: value,
      label: semanticLabel,
      child: FocusableTapTarget(
        onTap: changed == null ? null : () => changed(!value),
        borderRadius: trackSize.height,
        semanticLabel: semanticLabel,
        child: GestureDetector(
          onTap: changed == null ? null : () => changed(!value),
          child: pill,
        ),
      ),
    );
  }
}

/// The phase of whatever the list is currently doing.
enum ConsoleBannerTone {
  /// Something is in flight — amber.
  pending,

  /// Something just failed, or nothing is there to do it with — red.
  failure,

  /// A plain, settled fact about the list — green. The link is up.
  steady,
}

/// A strip at the top of a list saying what is in flight or what just failed.
///
/// A banner and not a dialog: the flow it describes is *about* the list, so it
/// belongs in the list rather than over it — and the rows stay live behind it,
/// which a modal would not allow. One banner carries a whole flow; its dot and
/// its action change with the phase.
class ConsoleBanner extends StatelessWidget {
  /// Creates a [ConsoleBanner].
  const ConsoleBanner({
    required this.message,
    required this.tone,
    this.actions = const [],
    super.key,
  });

  /// What is happening, in the words a toast would have used.
  final String message;

  /// Which phase this is.
  final ConsoleBannerTone tone;

  /// What the banner offers, if anything — Cancel while listening, Keep and
  /// Replace once a control that is already mapped has been caught. A banner
  /// that only explains (the idle notice at the head of the mapping list)
  /// carries none.
  final List<Widget> actions;

  /// The dot's diameter — also the reason the banner is 46px tall with no
  /// action and 61px with one: the button is taller than the sentence.
  static const double dotSize = 11;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final dot = switch (tone) {
      ConsoleBannerTone.pending => surface.warning,
      ConsoleBannerTone.failure => surface.rec,
      ConsoleBannerTone.steady => surface.success,
    };
    return Container(
      color: surface.background,
      // Indented past a row's own inset: the banner belongs to the list
      // rather than being one of its rows, and the mockups step it in on both
      // the Network and the Control faces to say so.
      padding: const EdgeInsets.fromLTRB(
        ConsoleRow.indentedInset,
        14,
        kConsoleRowInset,
        14,
      ),
      child: Row(
        children: [
          Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: kConsoleRowGap),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: surface.textSecondary,
                fontSize: 16,
                height: 1.13,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ),
          for (final action in actions) ...[
            const SizedBox(width: 10),
            action,
          ],
        ],
      ),
    );
  }
}

/// A short, low-emphasis button — the banner's Cancel / Try again.
class ConsoleSmallButton extends StatelessWidget {
  /// Creates a [ConsoleSmallButton].
  const ConsoleSmallButton({
    required this.label,
    required this.onPressed,
    super.key,
  });

  /// Visible caption, and the announced label.
  final String label;

  /// Tap action; null disables the button.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Opacity(
      opacity: onPressed == null ? surface.disabledOpacity : 1,
      child: FocusableTapTarget(
        onTap: onPressed,
        semanticLabel: label,
        borderRadius: 10,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 33,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: surface.cardHigh,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: surface.borderStrong),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 14,
                height: 1.21,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What a face draws where a list would be, when there is nothing to list.
///
/// Bordered and empty rather than a bare line of text: the shape of the list
/// stays, so an empty list reads as "nothing here" rather than as a face that
/// failed to draw.
class ConsoleEmptyCard extends StatelessWidget {
  /// Creates a [ConsoleEmptyCard].
  const ConsoleEmptyCard({required this.message, super.key});

  /// The sentence to show.
  final String message;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      height: 78,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ConsoleCard.radius),
        border: Border.all(color: surface.borderStrong),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: surface.textMuted,
          fontSize: 16,
          height: 1.13,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
    );
  }
}

/// A labelled bar that both reads and sets one `0..1` value — a mapping's LO,
/// HI, or threshold.
///
/// A bar rather than a knob: this sits in a list of 70px rows on a console
/// operated with a finger, and a knob is a mouse control that answers "which
/// way is up?" with a convention. The bar's leading edge IS the value, the
/// whole width is the target, and the readout is beside it in its own column
/// so the numbers under one another line up.
///
/// Stateful only for the duration of a drag: the value shown while a finger is
/// down is the finger's, so the bar tracks it at frame rate without waiting
/// for the write to come back through the cubit.
class ConsoleValueBar extends StatefulWidget {
  /// Creates a [ConsoleValueBar].
  const ConsoleValueBar({
    required this.label,
    required this.value,
    required this.readout,
    required this.onChanged,
    this.semanticLabel,
    super.key,
  });

  /// The caption at the leading edge.
  final String label;

  /// The current value, `0..1`.
  final double value;

  /// The value as the user's own units — `0..127` for a MIDI travel end.
  final String readout;

  /// Called with each new value during and at the end of a drag.
  final ValueChanged<double> onChanged;

  /// The announced label; defaults to [label].
  final String? semanticLabel;

  /// Height of the bar.
  static const double height = 53;

  /// Width of the caption column. Fixed so the bars of a stacked pair start
  /// on the same line whatever their captions are.
  static const double labelWidth = 106;

  /// Width of the readout column, on the same reasoning.
  static const double readoutWidth = 94;

  @override
  State<ConsoleValueBar> createState() => _ConsoleValueBarState();
}

class _ConsoleValueBarState extends State<ConsoleValueBar> {
  /// The value the finger is on, or null when nothing is dragging.
  double? _dragging;

  void _report(double width, double dx) {
    final next = (dx / width).clamp(0.0, 1.0);
    setState(() => _dragging = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final value = (_dragging ?? widget.value).clamp(0.0, 1.0);
    return Row(
      children: [
        SizedBox(
          width: ConsoleValueBar.labelWidth,
          child: Text(
            widget.label,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: surface.textMuted,
              fontSize: 13,
              height: 1.23,
              letterSpacing: 0.78,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
        ),
        const SizedBox(width: kConsoleRowGap),
        Expanded(
          child: Semantics(
            slider: true,
            label: widget.semanticLabel ?? widget.label,
            value: widget.readout,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _report(width, d.localPosition.dx),
                  onHorizontalDragStart: (d) =>
                      _report(width, d.localPosition.dx),
                  onHorizontalDragUpdate: (d) =>
                      _report(width, d.localPosition.dx),
                  onHorizontalDragEnd: (_) => setState(() => _dragging = null),
                  onHorizontalDragCancel: () =>
                      setState(() => _dragging = null),
                  child: Container(
                    height: ConsoleValueBar.height,
                    decoration: BoxDecoration(
                      color: surface.surface,
                      borderRadius: BorderRadius.circular(ConsoleCard.radius),
                      border: Border.all(color: surface.borderSubtle),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        ConsoleCard.radius - 1,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: AnimatedContainer(
                          duration: _dragging == null
                              ? consoleMotion(context)
                              : Duration.zero,
                          curve: Curves.easeOut,
                          width: (width - 2) * value,
                          decoration: BoxDecoration(
                            color: surface.accentSurface,
                            border: Border(
                              right: BorderSide(
                                color: surface.accent,
                                width: 2,
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
        ),
        const SizedBox(width: kConsoleRowGap),
        SizedBox(
          width: ConsoleValueBar.readoutWidth,
          child: Text(
            widget.readout,
            style: TextStyle(
              color: surface.textSecondary,
              fontFamily: SurfaceTheme.monoFont,
              fontSize: 14,
              height: 1.14,
              leadingDistribution: TextLeadingDistribution.even,
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

  /// The value reported when this segment is chosen.
  final T value;

  /// The visible caption.
  final String label;
}

/// A pick-one control for a short, symmetric pair — Toggle vs Momentary.
///
/// Not a `PillTabs` strip: those are the face's tabs, and a second strip in
/// the same shape, inside a row, would read as a second set of them.
class ConsoleSegmented<T> extends StatelessWidget {
  /// Creates a [ConsoleSegmented].
  const ConsoleSegmented({
    required this.segments,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  /// The choices, in display order.
  final List<ConsoleSegment<T>> segments;

  /// The current choice.
  final T selected;

  /// Called with the newly chosen value.
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return IntrinsicWidth(
      child: Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: surface.background,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (index, segment) in segments.indexed) ...[
              if (index > 0) const SizedBox(width: 5),
              Expanded(
                child: Semantics(
                  button: true,
                  selected: segment.value == selected,
                  label: segment.label,
                  child: InkWell(
                    onTap: () => onChanged(segment.value),
                    borderRadius: BorderRadius.circular(7),
                    child: AnimatedContainer(
                      duration: consoleMotion(context),
                      curve: Curves.easeOut,
                      height: 42,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      decoration: BoxDecoration(
                        color: segment.value == selected
                            ? surface.accent
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        segment.label,
                        style: TextStyle(
                          color: segment.value == selected
                              ? surface.onAccent
                              : surface.textSecondary,
                          fontSize: 16,
                          height: 1.13,
                          leadingDistribution: TextLeadingDistribution.even,
                          // One weight for both states, as everywhere on this
                          // surface: a weight change re-measures the label and
                          // the pair either side of it moves.
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The small pick-one that sits beside a caption it qualifies — the pedal's
/// A/B bank selector.
///
/// Smaller than [ConsoleSegmented] and outlined rather than filled, because it
/// is a *qualifier* on the list below it, not a setting of its own. It sits
/// next to the caption rather than at the far edge of the pane: floating it
/// right on a 1920px surface puts it a screen away from the words it changes.
class ConsoleMiniToggle<T> extends StatelessWidget {
  /// Creates a [ConsoleMiniToggle].
  const ConsoleMiniToggle({
    required this.segments,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  /// The choices, in display order.
  final List<ConsoleSegment<T>> segments;

  /// The current choice.
  final T selected;

  /// Called with the newly chosen value.
  final ValueChanged<T> onChanged;

  /// Height of the control.
  static const double height = 33;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      height: height,
      padding: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: surface.line),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final segment in segments)
              Semantics(
                button: true,
                selected: segment.value == selected,
                label: segment.label,
                child: InkWell(
                  onTap: () => onChanged(segment.value),
                  child: AnimatedContainer(
                    duration: consoleMotion(context),
                    curve: Curves.easeOut,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    color: segment.value == selected
                        ? surface.control
                        : Colors.transparent,
                    child: Text(
                      segment.label,
                      style: TextStyle(
                        color: segment.value == selected
                            ? surface.textPrimary
                            : surface.textMuted,
                        fontSize: 14,
                        height: 1.21,
                        leadingDistribution: TextLeadingDistribution.even,
                      ),
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

/// One entry offered by [showConsolePickerSheet].
@immutable
class ConsolePickerEntry<T> {
  /// Creates a [ConsolePickerEntry].
  const ConsolePickerEntry({
    required this.value,
    required this.title,
    this.state,
    this.indented = false,
  });

  /// The value returned when this entry is chosen.
  final T value;

  /// The entry's name.
  final String title;

  /// A mono readout at the trailing edge — where the entry sits in the rig.
  final String? state;

  /// Whether this entry is one step in under the one above it.
  final bool indented;
}

/// Asks the user to pick one of [entries]; resolves to the chosen value, or
/// null when the sheet is dismissed.
///
/// Built from the same [ConsoleRow]s as everything else rather than from
/// Material's popup menu. A popup is a mouse-sized floating card of 32px
/// items; every list on this console is a 70px row, and mixing the two makes
/// the picker read as a control borrowed from another input device.
///
/// The mockups draw no picker. This is derived from the rows around it, which
/// is the least it can be and still belong to the same surface.
Future<T?> showConsolePickerSheet<T>(
  BuildContext context, {
  required String title,
  required List<ConsolePickerEntry<T>> entries,
  T? current,
}) {
  final surface = context.surface;
  return showDialog<T>(
    context: context,
    barrierColor: surface.scrim,
    builder: (dialogContext) => Center(
      child: Material(
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 12),
                child: Text(
                  title,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 20,
                    height: 1.15,
                    leadingDistribution: TextLeadingDistribution.even,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: ConsoleCard(
                    children: [
                      for (final (index, entry) in entries.indexed)
                        ConsoleRow(
                          key: Key('console_picker_$index'),
                          title: entry.title,
                          state: entry.state,
                          indented: entry.indented,
                          showDisclosure: false,
                          mark: entry.value == current
                              ? const ConsoleCheck(
                                  key: Key('console_picker_current'),
                                )
                              : null,
                          showDivider: index < entries.length - 1,
                          onTap: () =>
                              Navigator.of(dialogContext).pop(entry.value),
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

/// The check that marks the target something is already pointed at.
class ConsoleCheck extends StatelessWidget {
  /// Creates a [ConsoleCheck].
  const ConsoleCheck({super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      '✓',
      style: TextStyle(
        color: context.surface.accent,
        fontSize: 15,
        height: 1.2,
        leadingDistribution: TextLeadingDistribution.even,
      ),
    );
  }
}

/// Confirms forgetting something named in [title]; resolves true when the
/// user goes through with it.
///
/// **Destructive confirms; reversible does not.** Forgetting deletes a
/// credential nothing else holds, so it asks. Disconnecting is undone by
/// tapping the row again, so it does not — a confirm on a reversible action
/// teaches people to dismiss confirms.
Future<bool> showConsoleForgetDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
}) async {
  final l10n = context.l10n;
  final surface = context.surface;
  final confirmed = await showDialog<bool>(
    context: context,
    barrierColor: surface.scrim,
    builder: (dialogContext) => Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 528,
          padding: const EdgeInsets.all(25),
          decoration: BoxDecoration(
            color: surface.card,
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: surface.borderStrong),
          ),
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
                style: TextStyle(
                  color: surface.textSecondary,
                  fontSize: 16,
                  height: 1.4,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
              const SizedBox(height: 19),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _DialogButton(
                    key: const Key('console_forget_cancel'),
                    label: l10n.networkKeepIt,
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                  ),
                  const SizedBox(width: 10),
                  _DialogButton(
                    key: const Key('console_forget_confirm'),
                    label: confirmLabel,
                    destructive: true,
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

class _DialogButton extends StatelessWidget {
  const _DialogButton({
    required this.label,
    required this.onPressed,
    this.destructive = false,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return FocusableTapTarget(
      onTap: onPressed,
      semanticLabel: label,
      borderRadius: 10,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 40,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: destructive ? surface.rec : surface.cardHigh,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: destructive ? surface.rec : surface.borderStrong,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: destructive ? surface.onAccent : surface.textPrimary,
              fontSize: 15,
              fontWeight: destructive ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}
