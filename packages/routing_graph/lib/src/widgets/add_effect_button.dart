import 'package:flutter/material.dart';
import 'package:routing_graph/src/theme/routing_graph_theme.dart';

/// The "add an effect" button at the end of a chain. Keeps an opaque disc
/// behind the icon so the routing wire passing through is masked, not visible
/// through the button's hole.
class AddEffectButton extends StatelessWidget {
  /// Creates an add-effect button.
  const AddEffectButton({
    required this.buttonKey,
    required this.accentColor,
    required this.full,
    required this.onAdd,
    required this.tooltip,
    super.key,
  });

  /// The button's key (caller-supplied).
  final Key buttonKey;

  /// The row's accent colour.
  final Color accentColor;

  /// Whether the chain is full (button disabled).
  final bool full;

  /// Adds an effect to the row.
  final VoidCallback onAdd;

  /// The enabled-state tooltip (the disabled tooltip is "Chain is full").
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Opaque disc sized to the icon's ring, so the routing wire is
            // masked behind the button without any fill showing past it.
            Container(
              width: 19,
              height: 19,
              decoration: BoxDecoration(
                color: context.routingGraph.surface,
                shape: BoxShape.circle,
              ),
            ),
            IconButton(
              key: buttonKey,
              iconSize: 24,
              padding: EdgeInsets.zero,
              color: accentColor,
              constraints: const BoxConstraints.tightFor(width: 24, height: 24),
              style: IconButton.styleFrom(
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              tooltip: full ? 'Chain is full' : tooltip,
              icon: const Icon(Icons.add_circle_outline),
              onPressed: full ? null : onAdd,
            ),
          ],
        ),
      ),
    );
  }
}
