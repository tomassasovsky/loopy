import 'package:flutter/material.dart';
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
    this.semanticLabel,
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

  /// The widget the target wraps (the visual presentation).
  final Widget child;

  /// The accessible name announced by screen readers. When set, the child's own
  /// semantics are excluded so the target reads as one labelled control.
  final String? semanticLabel;

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
    final enabled = widget.onTap != null;
    final ring = widget.focusColor ?? context.routingGraph.textPrimary;
    return Semantics(
      container: true,
      button: widget.button ? true : null,
      enabled: widget.button ? enabled : null,
      selected: widget.selected,
      label: widget.semanticLabel,
      excludeSemantics: widget.semanticLabel != null,
      child: FocusableActionDetector(
        enabled: enabled,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        shortcuts: _activators,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        onShowFocusHighlight: (value) {
          if (value != _focused) setState(() => _focused = value);
        },
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.borderRadius + 2),
              border: Border.all(
                color: _focused ? ring : Colors.transparent,
                width: 2,
              ),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
