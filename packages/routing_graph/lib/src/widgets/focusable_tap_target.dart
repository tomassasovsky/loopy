import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:routing_graph/src/theme/routing_graph_theme.dart';

/// A keyboard- and screen-reader-accessible tap target for the custom-painted
/// routing graphs, where the interactive elements (port chips, nodes, cards)
/// are not Material widgets and would otherwise be pointer-only.
///
/// Wraps [child] so it is:
/// - **keyboard focusable** and activatable with Enter/Space (WCAG 2.1.1),
/// - drawn with a **visible focus ring** when focused (2.4.7 / 1.4.11), and
/// - exposed to assistive tech with a button role plus optional
///   [semanticLabel] and [selected] state (4.1.2).
///
/// It deliberately avoids `InkWell`/`Material` so it can sit directly on the
/// graph canvas's `Stack`. When [onTap] is null the target is inert (no focus,
/// no pointer, reported disabled).
class FocusableTapTarget extends StatefulWidget {
  /// Creates an accessible tap target.
  const FocusableTapTarget({
    required this.onTap,
    required this.child,
    this.onLongPress,
    this.semanticLabel,
    this.customSemanticsActions,
    this.selected,
    this.button = true,
    this.borderRadius = 6,
    this.focusColor,
    this.focusNode,
    this.autofocus = false,
    super.key,
  });

  /// What activating the target does. Null makes it inert (disabled).
  final VoidCallback? onTap;

  /// Optional long-press action (e.g. open config while tap toggles).
  final VoidCallback? onLongPress;

  /// The widget the target wraps (the visual presentation).
  final Widget child;

  /// The accessible name announced by screen readers. When set, the child's own
  /// semantics are excluded so the target reads as one labelled control.
  final String? semanticLabel;

  /// Extra actions published on THIS target's node, for a control the target
  /// contains but cannot expose on its own.
  ///
  /// [semanticLabel] excludes the child's semantics, which is right for the
  /// text it wraps and wrong for an interactive slot inside it — a row whose
  /// leading glyph is its own tap target loses that target entirely. Naming
  /// the inner action here puts it back on the node the reader focuses, which
  /// wrapping the whole target in a `Semantics` cannot do: the target is a
  /// merge boundary, so an outer annotation lands on a parent node instead.
  final Map<CustomSemanticsAction, VoidCallback>? customSemanticsActions;

  /// Toggle/selected state exposed to assistive tech (e.g. a wired port).
  final bool? selected;

  /// Whether to expose the button role (true) or leave the role unset (false).
  final bool button;

  /// Corner radius of the focus ring (the child's own radius + 2 dp).
  final double borderRadius;

  /// The focus-ring colour. Defaults to the routing-graph primary text colour,
  /// which clears 3:1 against the dark canvas (1.4.11).
  final Color? focusColor;

  /// An optional external focus node (for ordered traversal).
  final FocusNode? focusNode;

  /// Whether this target should autofocus.
  final bool autofocus;

  @override
  State<FocusableTapTarget> createState() => _FocusableTapTargetState();
}

class _FocusableTapTargetState extends State<FocusableTapTarget> {
  bool _focused = false;

  static const _activators = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
  };

  @override
  Widget build(BuildContext context) {
    // Interactive when either gesture is wired — long-press alone is valid
    // (e.g. Control Center radio tiles: tap toggles when supported, hold opens
    // config even when the radio stack is absent).
    final enabled = widget.onTap != null || widget.onLongPress != null;
    final ring = widget.focusColor ?? context.routingGraph.textPrimary;
    // The visual child's own text would otherwise duplicate (or replace) the
    // supplied accessible name, so it is hidden from semantics — but ONLY the
    // visual, never the GestureDetector's tap action, which the screen reader
    // needs to activate the control. MergeSemantics folds the label node and
    // the tap-action node into one button.
    final visual = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.borderRadius + 2),
        border: Border.all(
          color: _focused ? ring : Colors.transparent,
          width: 2,
        ),
      ),
      child: widget.semanticLabel != null
          ? ExcludeSemantics(child: widget.child)
          : widget.child,
    );
    return MergeSemantics(
      child: Semantics(
        button: widget.button ? true : null,
        enabled: widget.button ? enabled : null,
        selected: widget.selected,
        label: widget.semanticLabel,
        customSemanticsActions: widget.customSemanticsActions,
        child: FocusableActionDetector(
          enabled: enabled,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
          shortcuts: _activators,
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                (widget.onTap ?? widget.onLongPress)?.call();
                return null;
              },
            ),
          },
          onShowFocusHighlight: (value) {
            if (value != _focused) setState(() => _focused = value);
          },
          child: GestureDetector(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            behavior: HitTestBehavior.opaque,
            child: visual,
          ),
        ),
      ),
    );
  }
}
