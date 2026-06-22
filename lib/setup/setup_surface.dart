import 'package:flutter/material.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;

/// Tabular figures keep numeric values vertically aligned in status tables.
const _setupNumerals = [FontFeature.tabularFigures()];

/// Shared typography for stepped setup surfaces (audio onboarding, settings).
/// These `const` tokens are used in `const` call sites; their colours mirror
/// [SurfaceTheme.dark]'s `text*` tokens.
const setupKicker = TextStyle(
  fontSize: 11,
  fontWeight: FontWeight.w700,
  letterSpacing: 1.8,
  color: Color(0xFF5B5D67), // SurfaceTheme.dark.textTertiary
);

const setupTitle = TextStyle(
  color: Color(0xFFF3F4F7), // SurfaceTheme.dark.textPrimary
  fontSize: 26,
  fontWeight: FontWeight.w700,
  letterSpacing: -0.5,
);

const setupBody = TextStyle(
  color: Color(0xFF989AA4), // SurfaceTheme.dark.textSecondary
  fontSize: 14,
  height: 1.45,
);

/// The accent-tinted slider styling shared by the effect-chain editors (lane
/// strips and per-input monitors) — a thin track with a small accent thumb.
const setupSliderTheme = SliderThemeData(
  trackHeight: 3,
  activeTrackColor: Color(0xFF3B82F6), // SurfaceTheme.dark.accent
  inactiveTrackColor: Color(0xFF272730), // SurfaceTheme.dark.line
  thumbColor: Color(0xFF3B82F6),
  overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
  thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
);

/// Section label with a trailing rule, matching the audio setup controls.
class SetupGroupLabel extends StatelessWidget {
  const SetupGroupLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Row(
      children: [
        Text(label, style: setupKicker.copyWith(color: surface.textSecondary)),
        const SizedBox(width: 10),
        Expanded(child: Divider(color: surface.line, height: 1)),
      ],
    );
  }
}

/// Card-style toggle row used in onboarding and settings.
class SetupToggleRow extends StatelessWidget {
  const SetupToggleRow({
    required this.toggleKey,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final Key toggleKey;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
      decoration: BoxDecoration(
        color: surface.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: surface.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: surface.textSecondary,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Switch(
            key: toggleKey,
            value: value,
            onChanged: onChanged,
            activeThumbColor: surface.onAccent,
            activeTrackColor: surface.accent,
            inactiveThumbColor: surface.textSecondary,
            inactiveTrackColor: surface.cardHigh,
            trackOutlineColor: WidgetStatePropertyAll(surface.line),
          ),
        ],
      ),
    );
  }
}

/// One choice in a [SetupOptionRow].
class SetupOption<T> {
  /// Creates a [SetupOption] carrying [value], shown as [label] (+ optional
  /// [sub]). [optionKey] keys the tappable card for tests.
  const SetupOption({
    required this.value,
    required this.label,
    this.sub = '',
    this.optionKey,
  });

  /// The value selected when this option is tapped.
  final T value;

  /// The primary text shown on the card.
  final String label;

  /// An optional secondary line under [label].
  final String sub;

  /// An optional widget key for the tappable card.
  final Key? optionKey;
}

/// A row of equal-width, single-select option cards — the multi-choice
/// counterpart to [SetupToggleRow]. Mirrors the audio-onboarding option style.
class SetupOptionRow<T> extends StatelessWidget {
  /// Creates a [SetupOptionRow] over [options], highlighting [selected] and
  /// reporting taps through [onSelected].
  const SetupOptionRow({
    required this.options,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  /// The selectable options, laid out left-to-right.
  final List<SetupOption<T>> options;

  /// The currently selected value.
  final T selected;

  /// Called with an option's value when its card is tapped.
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < options.length; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i == options.length - 1 ? 0 : 8),
              child: _OptionCard<T>(
                option: options[i],
                selected: options[i].value == selected,
                onTap: () => onSelected(options[i].value),
              ),
            ),
          ),
      ],
    );
  }
}

class _OptionCard<T> extends StatelessWidget {
  const _OptionCard({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final SetupOption<T> option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return FocusableTapTarget(
      key: option.optionKey,
      onTap: onTap,
      selected: selected,
      borderRadius: 12,
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
        decoration: BoxDecoration(
          color: selected ? surface.cardHigh : surface.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? surface.accent : surface.line,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              option.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? surface.accent : surface.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                fontFeatures: _setupNumerals,
              ),
            ),
            if (option.sub.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                option.sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected
                      ? surface.accent.withValues(alpha: 0.7)
                      : surface.textTertiary,
                  fontSize: 10.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A row of toggle chips for selecting a channel bitmask (bit c => channel c,
/// labelled 1-based). Tapping a chip flips that channel in the mask.
class SetupChannelChips extends StatelessWidget {
  /// Creates [SetupChannelChips] over [channelCount] channels, highlighting the
  /// channels set in [mask] and reporting the new mask through [onChanged].
  const SetupChannelChips({
    required this.channelCount,
    required this.mask,
    required this.onChanged,
    this.keyPrefix,
    super.key,
  });

  /// Number of hardware channels to show.
  final int channelCount;

  /// The current bitmask (bit c => channel c selected).
  final int mask;

  /// Called with the toggled mask when a chip is tapped.
  final ValueChanged<int> onChanged;

  /// Optional key prefix; chip c gets `Key('<prefix>_<c>')`.
  final String? keyPrefix;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var c = 0; c < channelCount; c++)
          _ChannelChip(
            key: keyPrefix == null ? null : Key('${keyPrefix}_$c'),
            label: '${c + 1}',
            selected: (mask & (1 << c)) != 0,
            onTap: () => onChanged(mask ^ (1 << c)),
          ),
      ],
    );
  }
}

class _ChannelChip extends StatelessWidget {
  const _ChannelChip({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return FocusableTapTarget(
      onTap: onTap,
      selected: selected,
      borderRadius: 10,
      child: Container(
        width: 42,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? surface.cardHigh : surface.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? surface.accent : surface.line,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? surface.accent : surface.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
            fontFeatures: _setupNumerals,
          ),
        ),
      ),
    );
  }
}

/// Tappable settings row with chevron, for navigation actions.
class SetupNavRow extends StatelessWidget {
  const SetupNavRow({
    required this.rowKey,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.icon = Icons.chevron_right,
    super.key,
  });

  final Key rowKey;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Material(
      color: surface.card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: rowKey,
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: surface.line),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: surface.textSecondary,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(icon, size: 20, color: surface.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

/// A bordered card of label/value rows, used for read-only status (the audio
/// running panel and the in-settings audio status). Values use tabular figures
/// so numbers stay aligned.
class SetupInfoTable extends StatelessWidget {
  /// Creates a [SetupInfoTable] from `(label, value)` [rows].
  const SetupInfoTable({required this.rows, super.key});

  /// The label/value pairs, rendered one per row in order.
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      decoration: BoxDecoration(
        color: surface.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: surface.line),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
              decoration: BoxDecoration(
                border: i == rows.length - 1
                    ? null
                    : Border(bottom: BorderSide(color: surface.line)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      rows[i].$1,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: surface.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      rows[i].$2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        fontFeatures: _setupNumerals,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Editable track-name row in the settings list.
class SetupTrackNameRow extends StatelessWidget {
  const SetupTrackNameRow({
    required this.rowKey,
    required this.channel,
    required this.name,
    required this.onTap,
    super.key,
  });

  final Key rowKey;
  final int channel;
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Material(
      color: surface.card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: rowKey,
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: surface.line),
          ),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: surface.cardHigh,
                  shape: BoxShape.circle,
                  border: Border.all(color: surface.line),
                ),
                child: Text(
                  '${channel + 1}',
                  style: TextStyle(
                    color: surface.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              Icon(Icons.edit_outlined, size: 16, color: surface.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}
