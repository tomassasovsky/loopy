import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
import 'package:segno/system/cubit/console_facts_cubit.dart';
import 'package:segno/update/cubit/update_cubit.dart';

/// The About tab: what this console is, what hardware it has, and the legal
/// line.
///
/// The only face on this console that is purely a readout, and it earns that
/// because there is nowhere else the serial of the box you are standing over
/// could go.
///
/// **Rows whose fact this build does not have are left out, not drawn with a
/// dash.** A desktop is not a console, and a serial number that is not there
/// is not a serial number that is blank. That has one structural consequence
/// the face has to own: which row is a card's LAST row depends on what the
/// build knows, so the card decides where the final hairline goes rather than
/// each row declaring it.
class AboutSystemTab extends StatefulWidget {
  /// Creates an [AboutSystemTab].
  const AboutSystemTab({super.key});

  @override
  State<AboutSystemTab> createState() => _AboutSystemTabState();
}

class _AboutSystemTabState extends State<AboutSystemTab> {
  /// How many distinct packages the licence registry carries, or null until
  /// the walk finishes.
  ///
  /// Counted rather than hard-coded: the figure beside "Open-source notices"
  /// is the size of the list the row opens, and a constant would drift from it
  /// the first time a dependency landed.
  int? _packages;

  @override
  void initState() {
    super.initState();
    unawaited(context.read<ConsoleFactsCubit>().load());
    unawaited(_countPackages());
  }

  Future<void> _countPackages() async {
    final packages = <String>{};
    await for (final licence in LicenseRegistry.licenses) {
      packages.addAll(licence.packages);
    }
    if (mounted) setState(() => _packages = packages.length);
  }

  Future<void> _rename(String current) async {
    final l10n = context.l10n;
    final cubit = context.read<ConsoleFactsCubit>();
    final name = await showConsoleRenameSheet(
      context,
      title: l10n.aboutRenameTitle,
      subtitle: l10n.aboutNameRow,
      current: current,
      fieldLabel: l10n.aboutNameRow,
      // An empty name is meaningful here: it hands the box back the name the
      // appliance shipped with, rather than leaving it called nothing.
      allowEmpty: true,
    );
    if (name == null) return;
    await cubit.rename(name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final facts = context.watch<ConsoleFactsCubit>().state;
    final update = context.watch<UpdateCubit>().state;
    final pedalVersion = context.watch<PedalCubit>().state.firmwareVersion;
    final engine = context.watch<AudioSetupCubit>().state.engineStatus;
    final packages = _packages;

    final thisConsole = _card([
      if (facts.consoleName.isNotEmpty)
        ({required last}) => ConsoleRow(
          key: const Key('system_about_name'),
          title: l10n.aboutNameRow,
          value: facts.consoleName,
          expanded: false,
          // The one tappable row of this card, so it takes the marker — and
          // the readouts beside it keep the gutter rather than each ending at
          // a different edge. The mockup draws no gutter here at all, which
          // leaves a rename you can only find by tapping a row that looks
          // exactly like the readouts around it.
          showDivider: !last,
          onTap: () => unawaited(_rename(facts.consoleName)),
        ),
      if (facts.facts.serial.isNotEmpty)
        ({required last}) => ConsoleRow(
          key: const Key('system_about_serial'),
          title: l10n.aboutSerialRow,
          value: facts.facts.serial,
          showDivider: !last,
        ),
      // Dropped whole when the build knows neither its version nor the channel
      // it follows: a row reading just the app's name states nothing.
      if (update.currentVersion != null || update.channel.isNotEmpty)
        ({required last}) => ConsoleRow(
          key: const Key('system_about_app'),
          title: l10n.appMenuLabel,
          subtitle: update.channel.isEmpty
              ? null
              : l10n.aboutChannelSubtitle(update.channel),
          value: update.currentVersion == null
              ? null
              : l10n.updatesVersionValue('${update.currentVersion}'),
          showDivider: !last,
        ),
      if (facts.facts.systemImage.isNotEmpty)
        ({required last}) => ConsoleRow(
          key: const Key('system_about_image'),
          title: l10n.aboutSystemImageRow,
          value: facts.facts.systemImage,
          showDivider: !last,
        ),
    ]);

    final hardware = _card([
      if (pedalVersion != null)
        ({required last}) => ConsoleRow(
          key: const Key('system_about_pedal'),
          title: l10n.aboutPedalFirmwareRow,
          subtitle: l10n.aboutPedalFirmwareSubtitle,
          value: l10n.aboutProtocolVersion(pedalVersion),
          showDisclosure: false,
          showDivider: !last,
        ),
      // Off the ENGINE's own report, not the requested config: what this row
      // states is what the interface is running at, and a build with nothing
      // open has no interface to name rather than one running at 0 Hz.
      if (engine.isConnected && engine.deviceName.isNotEmpty)
        ({required last}) => ConsoleRow(
          key: const Key('system_about_interface'),
          title: l10n.aboutAudioInterfaceRow,
          subtitle: engine.sampleRate > 0
              ? l10n.aboutAudioInterfaceSubtitle(
                  engine.sampleRate / 1000,
                  engine.bufferFrames,
                )
              : null,
          value: engine.deviceName,
          showDisclosure: false,
          showDivider: !last,
        ),
      if (facts.facts.panel.isNotEmpty)
        ({required last}) => ConsoleRow(
          key: const Key('system_about_panel'),
          title: l10n.aboutPanelRow,
          value: facts.facts.panel,
          showDisclosure: false,
          showDivider: !last,
        ),
    ]);

    final legal = _card([
      ({required last}) => ConsoleRow(
        key: const Key('system_about_licence'),
        title: l10n.aboutLicenceRow,
        // A readout, not a destination: the licence this build ships under is
        // a fact, and there is no licence document inside the app to open.
        // The notices row below is the one that goes somewhere, which is why
        // this one keeps the gutter without claiming the marker.
        value: l10n.aboutLicenceValue,
        showDivider: !last,
      ),
      ({required last}) => ConsoleRow(
        key: const Key('system_about_notices'),
        title: l10n.aboutNoticesRow,
        // Null until the walk finishes, and null if it found nothing: `0
        // components` is a figure no one measured.
        value: (packages ?? 0) == 0 ? null : l10n.aboutNoticesCount(packages!),
        expanded: false,
        showDivider: !last,
        onTap: () => showLicensePage(
          context: context,
          applicationName: l10n.appMenuLabel,
          applicationVersion: '${update.currentVersion ?? ''}',
        ),
      ),
    ]);

    return KeyedSubtree(
      key: const Key('system_about_tab'),
      child: ConsoleFace(
        previewKey: const Key('system_about_upcoming'),
        lastGroupExtent:
            ConsolePinnedGroupLabel.extent + kConsoleRowHeight * 2 + 2,
        groups: [
          if (thisConsole != null)
            ConsoleGroup(
              caption: l10n.systemThisConsoleGroup,
              blocks: [thisConsole],
            ),
          if (hardware != null)
            ConsoleGroup(
              caption: l10n.systemHardwareGroup,
              blocks: [hardware],
            ),
          // Never null: the licence is a fact of the build, not of the rig.
          ConsoleGroup(caption: l10n.systemLegalGroup, blocks: [legal!]),
        ],
      ),
    );
  }

  /// Builds a card from the rows that survived, and tells the LAST survivor
  /// that it is last.
  ///
  /// The rows arrive as builders taking `last` rather than as widgets, because
  /// whether a row is last depends on which facts this build happens to have —
  /// a row that decides its own closing hairline is a row that is wrong on the
  /// next rig. Null when nothing survived: a card with no rows is a 2px line.
  static Widget? _card(List<ConsoleRow Function({required bool last})> rows) {
    if (rows.isEmpty) return null;
    return ConsoleCard(
      children: [
        for (final (index, row) in rows.indexed)
          row(last: index == rows.length - 1),
      ],
    );
  }
}
