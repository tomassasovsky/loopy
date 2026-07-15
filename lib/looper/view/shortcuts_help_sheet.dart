import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:loopy/l10n/l10n.dart';

/// Opens the keyboard-shortcut legend for the Big Picture performance surface
/// as a dismissible [AlertDialog] (Esc / tap-outside close it). Surfaced by the
/// chrome's help button and by the `?` (Shift+/) key, so the shortcuts in
/// `TracksCommands.handleKey` — otherwise invisible to a new or screen-reader
/// user — become discoverable by pointer, keyboard, and assistive tech alike.
Future<void> showShortcutsHelp(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _ShortcutsHelpDialog(),
  );
}

/// A single legend entry: a platform-aware key [chip] and its [description].
/// [id] is a stable, locale/platform-independent handle for the row's key.
class _Shortcut {
  const _Shortcut(this.id, this.chip, this.description);

  /// Stable identifier used in the row's widget key.
  final String id;

  /// The key(s) shown in the chip (e.g. `Space`, `⌘Z`, `1–8`).
  final String chip;

  /// What the shortcut does.
  final String description;
}

/// The keyboard-shortcut legend, grouped Transport / Tracks / Navigation with
/// platform-correct modifiers (`⌘` on macOS, `Ctrl` elsewhere). Each row is one
/// merged [Semantics] node so a screen reader reads "R: Record or overdub the
/// selected track" as a unit, and the dialog names its route.
class _ShortcutsHelpDialog extends StatelessWidget {
  const _ShortcutsHelpDialog();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Loopy targets Windows/Linux too, so the modifier must not hardcode ⌘.
    final isMac = defaultTargetPlatform == TargetPlatform.macOS;
    // On macOS the modifier abuts the key (⌘Z); elsewhere it joins with `+`.
    String combo(String key) => isMac ? '⌘$key' : 'Ctrl+$key';

    return AlertDialog(
      key: const Key('shortcutsHelp_dialog'),
      // Names the route so assistive tech announces the legend as it opens.
      semanticLabel: l10n.a11yShortcutsHelp,
      title: Text(l10n.a11yShortcutsHelp),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _group(context, l10n.shortcutGroupTransport, [
                _Shortcut('playStop', 'Space', l10n.shortcutPlayStopAll),
                _Shortcut('clear', 'C', l10n.clearAllTooltip),
                _Shortcut('mode', 'M', l10n.shortcutMode),
                _Shortcut('arm', 'A', l10n.shortcutArm),
              ]),
              _group(context, l10n.shortcutGroupTracks, [
                _Shortcut('select', '1–8', l10n.shortcutSelectTrack),
                _Shortcut('bank', 'B', l10n.shortcutBank),
                _Shortcut('record', 'R', l10n.shortcutRecord),
                _Shortcut('playPause', 'P', l10n.shortcutPlayPause),
                _Shortcut('undoOverdub', 'U', l10n.shortcutUndoOverdub),
                _Shortcut('undo', combo('Z'), l10n.shortcutUndo),
                _Shortcut('redo', isMac ? '⌘⇧Z' : 'Ctrl+Y', l10n.shortcutRedo),
              ]),
              _group(context, l10n.shortcutGroupNavigation, [
                _Shortcut('signal', 'G', l10n.signalTooltip),
                _Shortcut('fullscreen', 'F', l10n.fullscreenTooltip),
                _Shortcut('settings', 'S', l10n.settingsTooltip),
                _Shortcut('save', combo('S'), l10n.shortcutSaveSession),
                _Shortcut('focus', 'Tab', l10n.shortcutFocusTraverse),
              ]),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('shortcutsHelp_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.close),
        ),
      ],
    );
  }

  Widget _group(BuildContext context, String title, List<_Shortcut> rows) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 2),
          child: Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        for (final row in rows) _row(context, row),
      ],
    );
  }

  Widget _row(BuildContext context, _Shortcut row) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // One merged node reading "<keys>: <description>", excluding the chip and
    // label's own nodes so the pairing is never read as two loose fragments.
    return Semantics(
      key: Key('shortcutRow_${row.id}'),
      container: true,
      label: '${row.chip}: ${row.description}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                constraints: const BoxConstraints(minWidth: 46),
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Text(
                  row.chip,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(row.description),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
