import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/system/cubit/console_facts_cubit.dart';
import 'package:segno/update/cubit/update_cubit.dart';

/// The About tab of the console's System domain, drawn to `SYSTEM / about`:
/// what this console is, what it is running, and the legal line.
///
/// Rows whose fact this build cannot know are LEFT OUT rather than drawn with
/// a dash: a desktop build is not a console, and a serial number that is not
/// there is not a serial number that is blank.
class AboutSystemTab extends StatelessWidget {
  /// Creates an [AboutSystemTab].
  const AboutSystemTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final facts = context.watch<ConsoleFactsCubit>().state.facts;
    final update = context.watch<UpdateCubit>().state;
    final audio = context.watch<AudioSetupCubit>().state;
    final status = audio.engineStatus;

    final console = <Widget>[
      if (facts.name.isNotEmpty)
        ConsoleRow(
          key: const Key('about_name'),
          title: l10n.systemAboutName,
          value: facts.name,
          showDisclosure: false,
        ),
      if (facts.serial.isNotEmpty)
        ConsoleRow(
          key: const Key('about_serial'),
          title: l10n.systemAboutSerial,
          value: facts.serial,
          showDisclosure: false,
        ),
      ConsoleRow(
        key: const Key('about_app'),
        title: l10n.systemAboutApp,
        subtitle: update.channel,
        value: update.currentVersion == null
            ? l10n.emDash
            : l10n.updatesVersionValue('${update.currentVersion}'),
        showDisclosure: false,
      ),
      if (facts.systemImage.isNotEmpty)
        ConsoleRow(
          key: const Key('about_image'),
          title: l10n.systemAboutImage,
          value: facts.systemImage,
          showDisclosure: false,
        ),
    ];

    final hardware = <Widget>[
      ConsoleRow(
        key: const Key('about_interface'),
        title: l10n.systemAboutInterface,
        subtitle: status.sampleRate > 0
            ? '${l10n.sampleRateKhzLabel(status.sampleRate)} · '
                  '${l10n.bufferFrames(status.bufferFrames)}'
            : null,
        value: status.deviceName.isEmpty ? l10n.emDash : status.deviceName,
        showDisclosure: false,
      ),
      if (facts.panel.isNotEmpty)
        ConsoleRow(
          key: const Key('about_panel'),
          title: l10n.systemAboutPanel,
          value: facts.panel,
          showDisclosure: false,
        ),
    ];

    return KeyedSubtree(
      key: const Key('about_system_tab'),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConsoleGroupLabel(l10n.systemThisConsoleGroup),
            const SizedBox(height: 10),
            ConsoleCard(children: _dividers(console)),
            const SizedBox(height: 14),
            ConsoleGroupLabel(l10n.systemHardwareGroup),
            const SizedBox(height: 10),
            ConsoleCard(children: _dividers(hardware)),
            const SizedBox(height: 14),
            ConsoleGroupLabel(l10n.systemLegalGroup),
            const SizedBox(height: 10),
            ConsoleCard(
              children: [
                ConsoleRow(
                  key: const Key('about_licence'),
                  title: l10n.systemAboutLicence,
                  value: 'GPLv3',
                  onTap: () => showLicensePage(context: context),
                ),
                ConsoleRow(
                  key: const Key('about_notices'),
                  divider: false,
                  title: l10n.systemAboutNotices,
                  onTap: () => showLicensePage(context: context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The card's last row carries no hairline — which row that is depends on
  /// what this build knows, so it is decided here rather than at each row.
  static List<Widget> _dividers(List<Widget> rows) => [
    for (var i = 0; i < rows.length; i++)
      if (i == rows.length - 1 && rows[i] is ConsoleRow)
        _withoutDivider(rows[i] as ConsoleRow)
      else
        rows[i],
  ];

  static Widget _withoutDivider(ConsoleRow row) => ConsoleRow(
    key: row.key,
    title: row.title,
    subtitle: row.subtitle,
    value: row.value,
    onTap: row.onTap,
    showDisclosure: row.showDisclosure,
    divider: false,
  );
}
