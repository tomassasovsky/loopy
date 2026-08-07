import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/high_contrast_cubit.dart';
import 'package:segno/looper/cubit/refresh_rate_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/shortcuts_help_sheet.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/cubit/waveform_window_cubit.dart';

/// The Display tab: what the screens do.
///
/// Three switches, one pick-one, and a row into the shortcut legend — all of
/// it settings the app already owned, drawn where `SYSTEM / display` puts
/// them.
///
/// The one thing that is not a setting is the failure: **the second window not
/// opening sits at the top of the list the setting lives in, not in a toast.**
/// It says what the toast says, in the toast's own words, so one condition
/// never reads two ways, and it carries a retry.
class DisplaySystemTab extends StatefulWidget {
  /// Creates a [DisplaySystemTab].
  const DisplaySystemTab({super.key});

  @override
  State<DisplaySystemTab> createState() => _DisplaySystemTabState();
}

class _DisplaySystemTabState extends State<DisplaySystemTab> {
  /// Whether the refresh-rate row is showing its choices.
  bool _rateOpen = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final waveform = context.watch<WaveformWindowCubit>().state;
    final highContrast = context.watch<HighContrastCubit>().state;
    final showIndicators = context.watch<TracksCubit>().state.showIndicators;
    final refreshHz = context.watch<RefreshRateCubit>().state;

    return KeyedSubtree(
      key: const Key('system_display_tab'),
      child: ConsoleFace(
        previewKey: const Key('system_display_upcoming'),
        // HELP is one 70px card under a caption.
        lastGroupExtent:
            ConsolePinnedGroupLabel.extent +
            kConsoleRowHeight +
            ConsoleCard.borderExtent,
        groups: [
          ConsoleGroup(
            caption: l10n.viewGroupLabel,
            blocks: [
              ConsoleCard(
                children: [
                  if (waveform.openFailed)
                    ConsoleBanner(
                      key: const Key('system_waveform_failed_banner'),
                      message: l10n.waveformWindowFailedBanner,
                      tone: ConsoleBannerTone.failure,
                      actions: [
                        ConsoleSmallButton(
                          key: const Key('system_waveform_retry'),
                          label: l10n.consoleTryAgain,
                          onPressed: context
                              .read<WaveformWindowCubit>()
                              .retryOpen,
                        ),
                      ],
                    ),
                  ConsoleRow(
                    key: const Key('system_waveform_row'),
                    title: l10n.waveformWindowTitle,
                    subtitle: l10n.waveformWindowSubtitle,
                    trailing: ConsoleSwitch(
                      key: const Key('system_waveform_switch'),
                      value: waveform.enabled,
                      semanticLabel: l10n.waveformWindowTitle,
                      onChanged: (on) => unawaited(
                        context.read<WaveformWindowCubit>().setEnabled(
                          value: on,
                        ),
                      ),
                    ),
                  ),
                  ConsoleRow(
                    key: const Key('system_high_contrast_row'),
                    title: l10n.highContrastTitle,
                    subtitle: l10n.highContrastSubtitle,
                    trailing: ConsoleSwitch(
                      key: const Key('system_high_contrast_switch'),
                      value: highContrast,
                      semanticLabel: l10n.highContrastTitle,
                      onChanged: (on) => unawaited(
                        context.read<HighContrastCubit>().setEnabled(value: on),
                      ),
                    ),
                  ),
                  ConsoleRow(
                    key: const Key('system_track_indicators_row'),
                    title: l10n.trackIndicatorsTitle,
                    subtitle: l10n.trackIndicatorsSubtitle,
                    showDivider: false,
                    trailing: ConsoleSwitch(
                      key: const Key('system_track_indicators_switch'),
                      value: showIndicators,
                      semanticLabel: l10n.trackIndicatorsTitle,
                      onChanged: (on) => unawaited(
                        context.read<TracksCubit>().setShowIndicators(
                          value: on,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          ConsoleGroup(
            caption: l10n.systemPerformanceGroup,
            blocks: [
              ConsoleCard(
                children: [
                  ConsoleRow(
                    key: const Key('system_refresh_rate_row'),
                    title: l10n.systemRefreshRateTitle,
                    subtitle: l10n.systemRefreshRateSubtitle,
                    value: l10n.refreshRateHz(refreshHz),
                    expanded: _rateOpen,
                    fill: _rateOpen ? surface.control : null,
                    showDivider: false,
                    onTap: () => setState(() => _rateOpen = !_rateOpen),
                  ),
                  ConsoleChooser.grid(
                    key: const Key('system_refresh_rate_chooser'),
                    open: _rateOpen,
                    // A grid, not a row list: `30 Hz` is a bare token, and a
                    // token has nothing to put in a row's width.
                    grid: ConsoleChipGrid<int>(
                      selected: {refreshHz},
                      options: [
                        for (final hz in RefreshRateCubit.options)
                          ConsoleSegment(
                            value: hz,
                            label: l10n.refreshRateHz(hz),
                            optionKey: Key('system_refresh_rate_$hz'),
                          ),
                      ],
                      onTap: (hz) {
                        unawaited(context.read<RefreshRateCubit>().setHz(hz));
                        // A pick-one: the question is answered, so it shuts.
                        setState(() => _rateOpen = false);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
          ConsoleGroup(
            caption: l10n.systemHelpGroup,
            blocks: [
              ConsoleCard(
                children: [
                  ConsoleRow(
                    key: const Key('system_shortcuts_row'),
                    title: l10n.a11yShortcutsHelp,
                    // `false`, not null: the row opens the legend, so it
                    // carries the marker that says a row does something.
                    expanded: false,
                    showDivider: false,
                    onTap: () => unawaited(showShortcutsHelp(context)),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
