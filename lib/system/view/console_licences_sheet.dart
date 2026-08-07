import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// Opens the open-source notices as a console panel.
///
/// Flutter's own `showLicensePage` is a Material master-detail route: an app
/// bar, a back chevron, list tiles, and a second page per package. Every one
/// of those is a thing this console does not have — **the rail is always on
/// screen, so a back chevron is a second navigation surface**, and a row that
/// pushes a page loses the list it came from.
///
/// So the notices are drawn the way every other list on this console is: rows
/// that open **in place**, one at a time, inside the same centred panel the
/// per-track routing dialog uses. It is a long document rather than a set of
/// settings, which is why it is a panel and not a tab — but a long document
/// is still a list, and this console already knows how to draw one.
///
/// [packages] is handed in rather than read here, because the row that opens
/// this panel already prints how many there are: `LicenseRegistry.licenses`
/// re-runs every collector on each access, and Flutter's own re-decompresses
/// and re-parses the whole NOTICES asset — so a second walk would make the
/// appliance pay that twice per visit for a list it has already read.
Future<void> showConsoleLicences(
  BuildContext context, {
  required Future<List<ConsoleLicencePackage>> packages,
}) {
  final surface = context.surface;
  return showDialog<void>(
    context: context,
    barrierColor: surface.scrim,
    builder: (_) => _ConsoleLicencesSheet(packages: packages),
  );
}

/// Walks the licence registry once, keyed by package.
///
/// Rebuilt into a package-keyed list rather than held as entries: one package
/// can register several licences, and the row is the package. The caller holds
/// the future and passes it to [showConsoleLicences], so one walk serves both
/// the count and the list.
Future<List<ConsoleLicencePackage>> readConsoleLicencePackages() async {
  final byPackage = <String, List<List<LicenseParagraph>>>{};
  await for (final entry in LicenseRegistry.licenses) {
    final paragraphs = entry.paragraphs.toList();
    for (final package in entry.packages) {
      byPackage.putIfAbsent(package, () => []).add(paragraphs);
    }
  }
  final names = byPackage.keys.toList()..sort();
  return [
    for (final name in names) ConsoleLicencePackage(name, byPackage[name]!),
  ];
}

/// One package and the licences it ships under.
@immutable
class ConsoleLicencePackage {
  /// Creates a [ConsoleLicencePackage].
  const ConsoleLicencePackage(this.name, this.paragraphs);

  /// The package's name, as the registry reports it.
  final String name;

  /// Every licence's paragraphs, in registry order, one list per licence.
  final List<List<LicenseParagraph>> paragraphs;
}

class _ConsoleLicencesSheet extends StatefulWidget {
  const _ConsoleLicencesSheet({required this.packages});

  /// The one walk of the registry, already in flight or already done.
  final Future<List<ConsoleLicencePackage>> packages;

  @override
  State<_ConsoleLicencesSheet> createState() => _ConsoleLicencesSheetState();
}

class _ConsoleLicencesSheetState extends State<_ConsoleLicencesSheet> {
  /// The panel's width. Wider than the routing dialog's, because this holds
  /// paragraphs rather than rows — but well short of the sheet, since a
  /// licence set at a 1,600px measure is unreadable.
  static const double _width = 940;

  /// Inset from the screen edge, as the routing dialog's scrim is.
  static const double _scrimInset = 60;

  List<ConsoleLicencePackage>? _packages;

  /// Which package is showing its text, or null when none is.
  String? _open;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Takes the walk the About face already started, rather than making its
  /// own.
  Future<void> _load() async {
    final packages = await widget.packages;
    if (!mounted) return;
    setState(() => _packages = packages);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final packages = _packages;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(_scrimInset),
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _width),
            child: Container(
              key: const Key('console_licences_sheet'),
              padding: const EdgeInsets.all(25),
              decoration: BoxDecoration(
                color: surface.card,
                borderRadius: BorderRadius.circular(17),
                border: Border.all(color: surface.borderStrong),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.aboutNoticesRow,
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 19,
                      height: 1.16,
                      leadingDistribution: TextLeadingDistribution.even,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: kConsoleLabelGap),
                  Text(
                    // Silent until the walk finishes: a count of nothing is
                    // not a count of zero.
                    packages == null
                        ? l10n.licencesReading
                        : l10n.aboutNoticesCount(packages.length),
                    style: TextStyle(
                      color: surface.textSecondary,
                      fontSize: 16,
                      height: 1.55,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                  ),
                  const SizedBox(height: kConsoleGroupGap),
                  // Flexible, not Expanded: a registry with three entries
                  // still shrinks to its content, and nothing scrolls until
                  // the list runs out of room.
                  Flexible(
                    child: packages == null
                        ? const SizedBox.shrink()
                        : ConsoleCard(
                            fill: surface.background,
                            children: [
                              // The flex goes INSIDE the card, and that is the
                              // whole trick. `ConsoleCard` is a
                              // `Column(mainAxisSize: min)`, which hands a
                              // plain child UNBOUNDED height — so a
                              // `shrinkWrap` list there sizes to its full
                              // content, overflows the cap the outer
                              // [Flexible] applies, and has no viewport left
                              // to scroll. A `Flexible` here bounds it to what
                              // the panel actually has, and `shrinkWrap` then
                              // means "no taller than the content" rather than
                              // "as tall as the content": three packages draw
                              // a card three rows tall, and a hundred and
                              // fifty scroll.
                              Flexible(
                                child: ListView.builder(
                                  key: const Key('console_licences_list'),
                                  padding: EdgeInsets.zero,
                                  shrinkWrap: true,
                                  itemCount: packages.length,
                                  itemBuilder: (context, index) => _row(
                                    context,
                                    packages[index],
                                    last: index == packages.length - 1,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                  const SizedBox(height: kConsoleGroupGap),
                  // A Row, not an Align: the panel's Column stretches its
                  // children, and a stretched button spans the whole panel.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      ConsoleDialogButton(
                        key: const Key('console_licences_close'),
                        label: l10n.close,
                        tone: ConsoleDialogTone.accent,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    ConsoleLicencePackage package, {
    required bool last,
  }) {
    final l10n = context.l10n;
    final surface = context.surface;
    final open = _open == package.name;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConsoleRow(
          key: Key('console_licence_${package.name}'),
          title: package.name,
          state: l10n.licenceCount(package.paragraphs.length),
          expanded: open,
          fill: open ? surface.control : null,
          // The last row keeps its hairline while it is OPEN: the drawer under
          // it is what the line now separates.
          showDivider: !last || open,
          onTap: () => setState(() => _open = open ? null : package.name),
        ),
        ConsoleChooser(
          key: Key('console_licence_drawer_${package.name}'),
          open: open,
          children: [
            Padding(
              padding: ConsoleChooser.gridInset,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (index, licence)
                      in package.paragraphs.indexed) ...[
                    if (index > 0)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 14),
                        child: ConsoleGroupLabel('· · ·'),
                      ),
                    for (final paragraph in licence)
                      Padding(
                        padding: EdgeInsets.only(
                          left: _indent(paragraph),
                          bottom: 12,
                        ),
                        child: Text(
                          paragraph.text,
                          textAlign:
                              paragraph.indent ==
                                  LicenseParagraph.centeredIndent
                              ? TextAlign.center
                              : TextAlign.left,
                          style: TextStyle(
                            color: surface.textSecondary,
                            fontSize: 14,
                            height: 1.5,
                            leadingDistribution: TextLeadingDistribution.even,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// A licence paragraph's own indent, in the units the registry reports it.
  static double _indent(LicenseParagraph paragraph) =>
      paragraph.indent == LicenseParagraph.centeredIndent
      ? 0
      : paragraph.indent * 14.0;
}
