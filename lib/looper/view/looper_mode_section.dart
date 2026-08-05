import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/loop/looper_mode_change.dart';
import 'package:segno/setup/setup_surface.dart';
import 'package:segno/theme/surface_theme.dart';

/// The looper feature's own mode-picker settings surface (index plan's UI
/// conventions — same "lives in the looper feature, not `audio_setup`"
/// posture as `TempoSettingsSection`): the five-mode axis
/// (Multi/Sync/Song/Band/Free, D4).
///
/// Mode is read live from [LooperBloc]'s `TransportState` (like
/// `TempoSettingsSection` reads tempo/click state), so a controller/pedal- or
/// session-load-driven mode change shows up immediately with no second cache.
///
/// D4 UX: switching mode while any track has content would otherwise be a
/// SILENT no-op (the engine rejects it, D4's content lock) — this section
/// never lets that happen. Selecting a different mode while
/// [LooperState.hasContent] shows an explicit confirmation dialog
/// (confirm-then-clear-then-switch); selecting the mode already active, or
/// switching with nothing recorded, applies immediately.
class LooperModeSection extends StatelessWidget {
  /// Creates a [LooperModeSection].
  const LooperModeSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final looperState = context.watch<LooperBloc>().state;
    final mode = looperState.transport.looperMode;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.looperModeIntro, style: context.setupBody),
        const SizedBox(height: 28),
        SetupGroupLabel(l10n.looperModeGroupLabel),
        const SizedBox(height: 12),
        _ModePicker(
          selected: mode,
          onSelected: (next) => unawaited(
            requestLooperModeChange(context, current: mode, next: next),
          ),
        ),
      ],
    );
  }
}

/// The five-mode selector (Multi/Sync/Song/Band/Free) as a vertical radio list.
class _ModePicker extends StatelessWidget {
  const _ModePicker({required this.selected, required this.onSelected});

  final LooperMode selected;
  final ValueChanged<LooperMode> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final labels = {
      for (final mode in LooperMode.values) mode: looperModeLabels(l10n, mode),
    };
    return Column(
      key: const Key('looperMode_list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < LooperMode.values.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _ModeListTile(
            mode: LooperMode.values[i],
            label: labels[LooperMode.values[i]]!.$1,
            subtitle: labels[LooperMode.values[i]]!.$2,
            selected: LooperMode.values[i] == selected,
            onTap: () => onSelected(LooperMode.values[i]),
          ),
        ],
      ],
    );
  }
}

/// One mode row: title + subtitle + radio indicator, styled like other setup
/// cards (not a raw Material [ListTile]).
class _ModeListTile extends StatelessWidget {
  const _ModeListTile({
    required this.mode,
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final LooperMode mode;
  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return FocusableTapTarget(
      key: Key('looperMode_option_${mode.name}'),
      onTap: onTap,
      selected: selected,
      borderRadius: 14,
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 160),
        padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
        decoration: BoxDecoration(
          color: selected ? surface.cardHigh : surface.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? surface.accent : surface.line,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: selected ? surface.accent : surface.textPrimary,
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
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 22,
              color: selected ? surface.accent : surface.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}
