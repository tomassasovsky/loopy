/// The console's shared row/card vocabulary, drawn to the `NETWORK / *`
/// screens in `segno-ui.pen`.
///
/// Lives beside the domain rather than inside either face so the two tabs of
/// one domain cannot drift apart the way the two former tray panels had — one
/// had a wrapping card and the other deliberately did not, one used
/// `SetupGroupLabel` and the other a bare `Row`, and nothing but attention
/// held them together.
///
/// Everything here is layout with two exceptions, [NetworkSwitch] and
/// [NetworkCard]'s inset; both carry their reasoning on the class.
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
const double kNetworkRowHeight = 70;

/// Horizontal inset of a row's content — also the left edge every title,
/// banner and switch in a card lines up on.
const double kNetworkRowInset = 20;

/// Width reserved for a row's disclosure marker.
const double kNetworkDisclosureWidth = 11;

/// The gap between a row's content and its trailing marks.
const double kNetworkRowGap = 14;

/// How long a row takes to open or shut.
///
/// One duration for every transition on this surface — the row growing, its
/// tint arriving, the marker turning — so a single tap reads as one movement
/// instead of three that happen to start together.
const Duration kNetworkMotion = Duration(milliseconds: 180);

/// [kNetworkMotion], or nothing where the platform asks for no motion.
Duration networkMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : kNetworkMotion;

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
class NetworkExpansion extends StatefulWidget {
  /// Creates a [NetworkExpansion].
  const NetworkExpansion({
    required this.expanded,
    required this.child,
    super.key,
  });

  /// Whether [child] is showing.
  final bool expanded;

  /// The block that grows and shrinks.
  final Widget child;

  @override
  State<NetworkExpansion> createState() => _NetworkExpansionState();
}

class _NetworkExpansionState extends State<NetworkExpansion>
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
      duration: kNetworkMotion,
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
  void didUpdateWidget(NetworkExpansion old) {
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
class NetworkCard extends StatelessWidget {
  /// Creates a [NetworkCard].
  const NetworkCard({required this.children, super.key});

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
class NetworkDisclosure extends StatelessWidget {
  /// Creates a [NetworkDisclosure].
  ///
  /// [expanded] null draws nothing and keeps the space.
  const NetworkDisclosure({this.expanded, super.key});

  /// Whether the row this marks is open; null when the row does not open.
  final bool? expanded;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final open = expanded;
    return SizedBox(
      width: kNetworkDisclosureWidth,
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

/// One row: `title / subtitle` on the left, an optional state word and a
/// disclosure marker on the right.
///
/// The state word is a single lower-case word (`connected`, `saved`, `open`,
/// `paired`) in the mono face — it is a machine readout about the row, not a
/// sentence about it, and the mockups set it as one.
class NetworkRow extends StatelessWidget {
  /// Creates a [NetworkRow].
  const NetworkRow({
    required this.title,
    this.subtitle,
    this.state,
    this.expanded,
    this.trailing,
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

  /// The state word at the trailing edge, if the row has one.
  final String? state;

  /// Disclosure state; null for a row that shows no marker at all. See
  /// [NetworkDisclosure] for why every row in a group passes one.
  final bool? expanded;

  /// A control that replaces the state word and marker — a [NetworkSwitch],
  /// for a row that IS a setting rather than a thing that opens.
  final Widget? trailing;

  /// Tap action, or null for a row that is only a readout.
  final VoidCallback? onTap;

  /// Whether to paint the hairline below. False on the last row of a card.
  final bool showDivider;

  /// Overrides the announced label; defaults to title + subtitle + state.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final label =
        semanticLabel ??
        [title, subtitle, state].whereType<String>().join(', ');

    final row = Container(
      height: kNetworkRowHeight,
      padding: const EdgeInsets.symmetric(horizontal: kNetworkRowInset),
      decoration: showDivider
          ? BoxDecoration(
              border: Border(
                bottom: BorderSide(color: surface.borderHairline),
              ),
            )
          : null,
      child: Row(
        children: [
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
                    color: surface.textPrimary,
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
            const SizedBox(width: kNetworkRowGap),
            control,
          ] else ...[
            if (state case final word?) ...[
              const SizedBox(width: kNetworkRowGap),
              Text(
                word,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: surface.textSecondary,
                  fontFamily: SurfaceTheme.monoFont,
                  fontSize: 14,
                  height: 1.14,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
            ],
            const SizedBox(width: kNetworkRowGap),
            NetworkDisclosure(expanded: expanded),
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
class NetworkExpandedRow extends StatelessWidget {
  /// Creates a [NetworkExpandedRow].
  const NetworkExpandedRow({
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
      duration: networkMotion(context),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        // Transparent rather than absent while shut: a null decoration would
        // rebuild the box on every open and lose the colour lerp.
        color: expanded ? surface.control : surface.control.withAlpha(0),
        borderRadius: BorderRadius.circular(NetworkCard.radius),
        border: Border.all(
          color: expanded ? surface.borderSubtle : Colors.transparent,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row,
          NetworkExpansion(
            expanded: expanded,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                kNetworkRowInset,
                0,
                kNetworkRowInset,
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
class NetworkActionChip extends StatelessWidget {
  /// Creates a [NetworkActionChip].
  const NetworkActionChip({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
    super.key,
  });

  /// Visible caption.
  final String label;

  /// Leading glyph.
  final IconData icon;

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
                Icon(icon, size: 17, color: tint),
                const SizedBox(width: 10),
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
class NetworkFaceHeader extends StatelessWidget {
  /// Creates a [NetworkFaceHeader].
  const NetworkFaceHeader({
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
class NetworkIconButton extends StatefulWidget {
  /// Creates a [NetworkIconButton].
  const NetworkIconButton({
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
  State<NetworkIconButton> createState() => _NetworkIconButtonState();
}

class _NetworkIconButtonState extends State<NetworkIconButton>
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
  void didUpdateWidget(NetworkIconButton oldWidget) {
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
class NetworkSwitch extends StatelessWidget {
  /// Creates a [NetworkSwitch].
  const NetworkSwitch({
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
enum NetworkBannerTone {
  /// Something is in flight — amber.
  pending,

  /// Something just failed — red.
  failure,
}

/// A strip at the top of a list saying what is in flight or what just failed.
///
/// A banner and not a dialog: the flow it describes is *about* the list, so it
/// belongs in the list rather than over it — and the rows stay live behind it,
/// which a modal would not allow. One banner carries a whole flow; its dot and
/// its action change with the phase.
class NetworkBanner extends StatelessWidget {
  /// Creates a [NetworkBanner].
  const NetworkBanner({
    required this.message,
    required this.tone,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  /// What is happening, in the words a toast would have used.
  final String message;

  /// Which phase this is.
  final NetworkBannerTone tone;

  /// The action's caption — "Cancel" while pending, "Try again" after.
  final String? actionLabel;

  /// The action.
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final dot = switch (tone) {
      NetworkBannerTone.pending => surface.warning,
      NetworkBannerTone.failure => surface.rec,
    };
    return Container(
      color: surface.background,
      padding: const EdgeInsets.symmetric(
        horizontal: kNetworkRowInset,
        vertical: 14,
      ),
      child: Row(
        children: [
          Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: kNetworkRowGap),
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
          if (actionLabel case final caption?) ...[
            const SizedBox(width: kNetworkRowGap),
            NetworkSmallButton(label: caption, onPressed: onAction),
          ],
        ],
      ),
    );
  }
}

/// A short, low-emphasis button — the banner's Cancel / Try again.
class NetworkSmallButton extends StatelessWidget {
  /// Creates a [NetworkSmallButton].
  const NetworkSmallButton({
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
class NetworkEmptyCard extends StatelessWidget {
  /// Creates a [NetworkEmptyCard].
  const NetworkEmptyCard({required this.message, super.key});

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
        borderRadius: BorderRadius.circular(NetworkCard.radius),
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

/// Confirms forgetting something named in [title]; resolves true when the
/// user goes through with it.
///
/// **Destructive confirms; reversible does not.** Forgetting deletes a
/// credential nothing else holds, so it asks. Disconnecting is undone by
/// tapping the row again, so it does not — a confirm on a reversible action
/// teaches people to dismiss confirms.
Future<bool> showNetworkForgetDialog(
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
                    key: const Key('network_forget_cancel'),
                    label: l10n.networkKeepIt,
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                  ),
                  const SizedBox(width: 10),
                  _DialogButton(
                    key: const Key('network_forget_confirm'),
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
