import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/view/fx_editor/fx_block_chip.dart';
import 'package:loopy/looper/view/signal_graph/signal_style.dart';
import 'package:loopy/theme/surface_theme.dart';

/// Which kind of block the "+" adds.
enum _AddChoice {
  /// A built-in DSP effect.
  effect,

  /// A hosted VST3/CLAP plugin (opens the browser).
  plugin,
}

/// The FX chain laid out left→right as `IN → blocks → + → OUT`. Each block is a
/// tappable [FxBlockChip] (selects it for the inspector) and a long-press
/// drag target (re-sequences the chain — processing order is signal order). The
/// trailing "+" adds a built-in effect or a plugin, and disables at the chain
/// cap. An empty chain is `IN → + → OUT`, not an error.
class FxChainStrip extends StatelessWidget {
  /// Creates an [FxChainStrip].
  const FxChainStrip({
    required this.effects,
    required this.selectedIndex,
    required this.canAdd,
    required this.onSelect,
    required this.onReorder,
    required this.onAddEffect,
    required this.onAddPlugin,
    super.key,
  });

  /// The chain in processing order.
  final List<TrackEffect> effects;

  /// The currently selected block index, or null when nothing is selected.
  final int? selectedIndex;

  /// Whether another block fits below the chain cap.
  final bool canAdd;

  /// Selects the block at the given index for editing.
  final ValueChanged<int> onSelect;

  /// Reorders the block at `from` to `to`.
  final void Function(int from, int to) onReorder;

  /// Appends a built-in effect.
  final VoidCallback onAddEffect;

  /// Appends a plugin (opens the browser).
  final VoidCallback onAddPlugin;

  /// A drop onto the gap [insertAt] (an index in the current list). Adjacent
  /// gaps are no-ops; otherwise normalise to the post-removal target.
  void _reorderTo(int from, int insertAt) {
    if (insertAt == from || insertAt == from + 1) return;
    onReorder(from, insertAt > from ? insertAt - 1 : insertAt);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _EndCap(label: l10n.fxEditorChainIn),
          for (var i = 0; i < effects.length; i++) ...[
            _DropGap(
              gapKey: Key('fxChain_drop_$i'),
              insertAt: i,
              onDrop: _reorderTo,
            ),
            _DraggableBlock(
              index: i,
              chip: FxBlockChip(
                chipKey: Key('fxChain_block_$i'),
                effect: effects[i],
                selected: selectedIndex == i,
                onTap: () => onSelect(i),
              ),
            ),
          ],
          _DropGap(
            gapKey: Key('fxChain_drop_${effects.length}'),
            insertAt: effects.length,
            onDrop: _reorderTo,
          ),
          _AddBlockButton(
            canAdd: canAdd,
            onAddEffect: onAddEffect,
            onAddPlugin: onAddPlugin,
          ),
          const SizedBox(width: 8),
          _EndCap(label: l10n.fxEditorChainOut),
        ],
      ),
    );
  }
}

/// A fixed `IN` / `OUT` terminal on the chain strip — a quiet neutral pill.
class _EndCap extends StatelessWidget {
  const _EndCap({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: surface.surface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: surface.line),
      ),
      child: Text(
        label,
        style: signalLabel(color: surface.textTertiary),
      ),
    );
  }
}

/// Wraps a block chip so a long-press lifts it for reorder; a plain tap still
/// falls through to the chip's own select.
class _DraggableBlock extends StatelessWidget {
  const _DraggableBlock({required this.index, required this.chip});

  final int index;
  final Widget chip;

  @override
  Widget build(BuildContext context) {
    return LongPressDraggable<int>(
      data: index,
      feedback: Material(color: Colors.transparent, child: chip),
      childWhenDragging: Opacity(opacity: 0.3, child: chip),
      child: chip,
    );
  }
}

/// The gap between blocks, doubling as a [DragTarget]: it widens while a block
/// hovers and drops it in at that slot on release.
class _DropGap extends StatelessWidget {
  const _DropGap({
    required this.gapKey,
    required this.insertAt,
    required this.onDrop,
  });

  final Key gapKey;
  final int insertAt;
  final void Function(int from, int insertAt) onDrop;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return DragTarget<int>(
      key: gapKey,
      onWillAcceptWithDetails: (d) =>
          d.data != insertAt && d.data + 1 != insertAt,
      onAcceptWithDetails: (d) => onDrop(d.data, insertAt),
      builder: (context, candidate, rejected) {
        final active = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: Durations.short3,
          width: active ? 22 : 8,
          height: 44,
          alignment: Alignment.center,
          child: active
              ? Container(
                  width: 3,
                  height: 40,
                  decoration: BoxDecoration(
                    color: surface.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                )
              : const SizedBox.shrink(),
        );
      },
    );
  }
}

/// The trailing "+" — a menu of *add effect* / *add plugin*, disabled at cap.
class _AddBlockButton extends StatelessWidget {
  const _AddBlockButton({
    required this.canAdd,
    required this.onAddEffect,
    required this.onAddPlugin,
  });

  final bool canAdd;
  final VoidCallback onAddEffect;
  final VoidCallback onAddPlugin;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final tint = canAdd ? surface.textSecondary : surface.textTertiary;
    return PopupMenuButton<_AddChoice>(
      key: const Key('fxChain_add'),
      enabled: canAdd,
      tooltip: l10n.signalAddEffect,
      color: surface.cardHigh,
      shape: signalMenuShape(surface),
      elevation: 10,
      position: PopupMenuPosition.under,
      onSelected: (choice) => switch (choice) {
        _AddChoice.effect => onAddEffect(),
        _AddChoice.plugin => onAddPlugin(),
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _AddChoice.effect,
          height: 40,
          child: Text(
            l10n.signalAddEffect,
            style: signalLabel(color: surface.textPrimary, size: 13),
          ),
        ),
        PopupMenuItem(
          value: _AddChoice.plugin,
          height: 40,
          child: Text(
            l10n.signalAddPlugin,
            style: signalLabel(color: surface.textPrimary, size: 13),
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: surface.line),
        ),
        child: Icon(Icons.add, size: 18, color: tint),
      ),
    );
  }
}
