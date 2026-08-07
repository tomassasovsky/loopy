import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/update/cubit/update_cubit.dart';

/// The Updates tab: what build is running, what happens on its own, and the
/// one banner that carries the whole check → download → restart flow.
///
/// **Nothing downloads until asked.** The automatic switch only *looks*; its
/// subtitle says so and `UpdateCubit` enforces it. That is why the flow is one
/// banner rather than a row per phase: the offer has to be a thing you accept,
/// and a banner with one button is the smallest honest shape for that.
///
/// The banner's dot and action change with the phase and nothing else moves,
/// so a flow that runs for a minute does not relayout the face under the
/// finger waiting on it. Every phase drawn here is one `UpdateState` can
/// actually reach — the downloading bar included, which is fed by a real
/// stream of progress from the repository rather than a spinner standing in
/// for one.
class UpdatesSystemTab extends StatelessWidget {
  /// Creates an [UpdatesSystemTab].
  const UpdatesSystemTab({super.key});

  /// A card wrapping one row, plus its border.
  static const double _rowCard = kConsoleRowHeight + ConsoleCard.borderExtent;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<UpdateCubit>().state;
    final cubit = context.read<UpdateCubit>();
    final banner = _banner(context, state, cubit);
    final staged = state.phase == UpdatePhase.staged;

    return KeyedSubtree(
      key: const Key('system_updates_tab'),
      child: ConsoleFace(
        previewKey: const Key('system_updates_upcoming'),
        lastGroupExtent:
            ConsolePinnedGroupLabel.extent +
            _rowCard * 2 +
            kConsoleBlockGap +
            banner.height +
            (staged ? kConsoleBlockGap + _proseHeight : 0),
        groups: [
          // No caption: the running build and the channel it follows are the
          // face's subject, not a group of it, and `SYSTEM / update` draws
          // them straight under the tab strip.
          ConsoleGroup(
            blocks: [
              ConsoleCard(
                children: [
                  ConsoleRow(
                    key: const Key('system_installed_version_row'),
                    title: l10n.updatesInstalledVersionLabel,
                    value: state.currentVersion == null
                        ? null
                        : l10n.updatesVersionValue('${state.currentVersion}'),
                    showDisclosure: false,
                  ),
                  ConsoleRow(
                    key: const Key('system_channel_row'),
                    title: l10n.updatesChannelLabel,
                    value: state.channel.isEmpty ? null : state.channel,
                    showDisclosure: false,
                    showDivider: false,
                  ),
                ],
              ),
            ],
          ),
          ConsoleGroup(
            caption: l10n.systemAutomaticGroup,
            blocks: [
              ConsoleCard(
                children: [
                  ConsoleRow(
                    key: const Key('system_auto_check_row'),
                    title: l10n.updatesAutoCheckTitle,
                    subtitle: l10n.updatesAutoCheckSubtitle,
                    trailing: ConsoleSwitch(
                      key: const Key('system_auto_check_switch'),
                      value: state.autoCheck,
                      semanticLabel: l10n.updatesAutoCheckTitle,
                      onChanged: (on) =>
                          unawaited(cubit.setAutoCheck(value: on)),
                    ),
                  ),
                  ConsoleRow(
                    key: const Key('system_channel_switch_row'),
                    title: l10n.updatesExperimentalChannelTitle,
                    subtitle: l10n.updatesExperimentalChannelSubtitle,
                    showDivider: false,
                    trailing: ConsoleSwitch(
                      key: const Key('system_experimental_switch'),
                      value: state.channel == 'experimental',
                      semanticLabel: l10n.updatesExperimentalChannelTitle,
                      // Locked mid-download rather than hidden: the switch is
                      // still the answer to "which channel am I on", and
                      // switching would abandon a bundle already half staged.
                      onChanged: state.phase == UpdatePhase.downloading
                          ? null
                          : (on) => unawaited(
                              cubit.setExperimentalChannel(value: on),
                            ),
                    ),
                  ),
                ],
              ),
              ConsoleCard(children: [banner.widget]),
              if (staged) ConsoleProse(l10n.updatesRestartBusySubtitle),
            ],
          ),
        ],
      ),
    );
  }

  /// The one banner, and how tall it is — the caller needs the height to tell
  /// [ConsoleFace] when the last group's caption has risen into view.
  ({Widget widget, double height}) _banner(
    BuildContext context,
    UpdateState state,
    UpdateCubit cubit,
  ) {
    final l10n = context.l10n;
    final version = state.available?.version.toString() ?? '';

    // An unsupported platform gets the banner with NO action: the flow is not
    // there to offer, and a dead "Check now" is worse than none.
    if (!state.supported) {
      return _wrap(
        ConsoleBanner(
          key: const Key('system_update_banner'),
          message: l10n.updatesUnsupportedBanner,
          tone: ConsoleBannerTone.steady,
        ),
        _bareHeight,
      );
    }

    final check = ConsoleSmallButton(
      key: const Key('system_update_action'),
      label: l10n.updatesCheckNowTitle,
      onPressed: () => unawaited(cubit.check()),
    );

    return switch (state.phase) {
      // Idle and up-to-date keep their check action, so the row is never a
      // dead end — "nothing to do" is still a thing you can ask again.
      UpdatePhase.idle => _wrap(
        ConsoleBanner(
          key: const Key('system_update_banner'),
          message: l10n.updatesCheckNowSubtitle,
          tone: ConsoleBannerTone.steady,
          actions: [check],
        ),
        _actionHeight,
      ),
      UpdatePhase.upToDate => _wrap(
        ConsoleBanner(
          key: const Key('system_update_banner'),
          message: l10n.updatesUpToDateSubtitle(state.channel),
          tone: ConsoleBannerTone.steady,
          actions: [check],
        ),
        _actionHeight,
      ),
      UpdatePhase.checking => _wrap(
        ConsoleBanner(
          key: const Key('system_update_banner'),
          message: l10n.updatesCheckingLabel,
          tone: ConsoleBannerTone.pending,
        ),
        _bareHeight,
      ),
      UpdatePhase.available => _wrap(
        ConsoleBanner(
          key: const Key('system_update_banner'),
          message: l10n.updatesAvailableBanner(version),
          tone: ConsoleBannerTone.pending,
          actions: [
            ConsoleSmallButton(
              key: const Key('system_update_action'),
              label: l10n.updatesDownloadTitle,
              onPressed: () => unawaited(cubit.startDownload()),
            ),
          ],
        ),
        _actionHeight,
      ),
      UpdatePhase.downloading => _wrap(
        ConsoleBanner(
          key: const Key('system_update_banner'),
          message: l10n.updatesStagingBanner(
            version,
            (state.progress * 100).round(),
          ),
          tone: ConsoleBannerTone.pending,
          progress: state.progress,
        ),
        _progressHeight,
      ),
      UpdatePhase.staged => _wrap(
        ConsoleBanner(
          key: const Key('system_update_banner'),
          message: l10n.updatesStagedSubtitle(version),
          tone: ConsoleBannerTone.steady,
          actions: [
            ConsoleSmallButton(
              key: const Key('system_update_action'),
              label: l10n.updatesRestartNow,
              onPressed: () => unawaited(_confirmRestart(context, cubit)),
            ),
          ],
        ),
        _actionHeight,
      ),
      // A failed download is not a failed check, and saying so matters twice
      // over: the sentence names the wrong operation, and the retry runs the
      // wrong one — offering to look again for a build already on offer.
      UpdatePhase.error => _wrap(
        ConsoleBanner(
          key: const Key('system_update_banner'),
          message: switch (state.failure) {
            UpdateFailure.download => l10n.updatesDownloadFailedBanner(
              state.errorMessage ?? l10n.updatesCheckFailedReason,
            ),
            UpdateFailure.check || null => l10n.updatesCheckFailedBanner(
              state.errorMessage ?? l10n.updatesCheckFailedReason,
            ),
          },
          tone: ConsoleBannerTone.failure,
          actions: [
            ConsoleSmallButton(
              key: const Key('system_update_action'),
              label: l10n.consoleTryAgain,
              onPressed: () => unawaited(
                state.failure == UpdateFailure.download
                    ? cubit.startDownload()
                    : cubit.check(),
              ),
            ),
          ],
        ),
        _actionHeight,
      ),
    };
  }

  /// Restarting throws away whatever is in the rig, so it asks first — the
  /// same treatment every destructive action on this console gets. The prose
  /// under the banner says the same thing ahead of time; the dialog is what
  /// stops it happening on a mis-tap.
  Future<void> _confirmRestart(BuildContext context, UpdateCubit cubit) async {
    final l10n = context.l10n;
    final confirmed = await showConsoleConfirmDialog(
      context,
      title: l10n.updatesRestartNow,
      body: l10n.updatesRestartBusySubtitle,
      confirmLabel: l10n.updatesRestartNow,
    );
    if (confirmed) await cubit.applyAndRestart();
  }

  static ({Widget widget, double height}) _wrap(Widget widget, double height) =>
      (widget: widget, height: height + ConsoleCard.borderExtent);

  /// A banner that is only a sentence.
  static const double _bareHeight = 46;

  /// A banner with a button — the button is taller than the sentence.
  static const double _actionHeight = 61;

  /// A banner with the progress track under its sentence.
  static const double _progressHeight =
      _bareHeight + ConsoleBanner.progressGap + ConsoleBanner.progressHeight;

  /// One line of [ConsoleProse] at its 14px x 1.5.
  static const double _proseHeight = 21;
}
