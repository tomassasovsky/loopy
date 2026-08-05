import 'package:flutter/material.dart';
import 'package:segno/theme/theme.dart';

/// One choice in a [PillTabs] strip.
@immutable
class PillTab<T> {
  /// Creates a [PillTab].
  const PillTab({required this.value, required this.label, this.tooltip});

  /// The value reported when this tab is chosen.
  final T value;

  /// The visible caption.
  final String label;

  /// Optional hover/long-press explanation.
  final String? tooltip;
}

/// A single-select strip of pills — the console's tab idiom.
///
/// Material's `SegmentedButton` carries its own outline box, height and
/// selected-check, which read as borrowed from another app once a surface
/// moved inside the tray sheet next to the navigation rail (#492). This draws
/// from the theme's surface tokens instead, so a tab strip and a rail item are
/// visibly the same family of control.
///
/// Selection is announced explicitly rather than through the rail's
/// `FocusableTapTarget`: that widget carries a theme dependency this control
/// must not inherit, since a tab strip has to render anywhere a panel does —
/// including harnesses that pump it under a bare `MaterialApp`.
class PillTabs<T> extends StatelessWidget {
  /// Creates a [PillTabs].
  const PillTabs({
    required this.tabs,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  /// The choices, in display order.
  final List<PillTab<T>> tabs;

  /// The currently chosen value.
  final T selected;

  /// Called with the newly chosen value. Re-tapping the current tab is a no-op
  /// rather than a deselect: this is a tab strip, and there is no "none".
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final tab in tabs)
          _Pill(
            label: tab.label,
            tooltip: tab.tooltip,
            selected: tab.value == selected,
            onTap: () {
              if (tab.value == selected) return;
              onChanged(tab.value);
            },
            surface: surface,
          ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onTap,
    required this.surface,
  });

  final String label;
  final String? tooltip;
  final bool selected;
  final VoidCallback onTap;
  final SurfaceTheme surface;

  static const double _radius = 7;

  @override
  Widget build(BuildContext context) {
    final pill = Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(_radius),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_radius),
            color: selected
                ? surface.accent.withValues(alpha: 0.18)
                : Colors.transparent,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? surface.accent : surface.textSecondary,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
    final message = tooltip;
    if (message == null) return pill;
    return Tooltip(message: message, child: pill);
  }
}
