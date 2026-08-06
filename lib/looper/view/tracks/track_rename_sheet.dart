import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// Asks for a track's name.
///
/// Returns the new name, or null when dismissed.
///
/// A console sheet with the keys built in, for the same reason the WiFi join
/// sheet is one: the console has no physical keyboard, and the app-wide
/// keyboard host is driven by field focus, which would put the keys in a
/// second panel under a dialog trying to centre itself in what is left. The
/// stage's own rename is a dialog and stays one — this is the console's.
Future<String?> showTrackRenameSheet(
  BuildContext context, {
  required String initial,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: context.surface.scrim,
  constraints: const BoxConstraints(),
  builder: (sheetContext) => _TrackRenameSheet(initial: initial),
);

class _TrackRenameSheet extends StatefulWidget {
  const _TrackRenameSheet({required this.initial});

  final String initial;

  @override
  State<_TrackRenameSheet> createState() => _TrackRenameSheetState();
}

class _TrackRenameSheetState extends State<_TrackRenameSheet> {
  /// The name being typed. Held here rather than in a controller behind a real
  /// `TextField`, which would summon the app-wide keyboard over this sheet's
  /// own keys.
  late String _value = widget.initial;

  /// True until the first key: the sheet opens with the current name selected,
  /// so typing replaces it and backspace edits it. Renaming a track is
  /// usually "call it something else", not "append to what it is called".
  bool _replacing = true;

  void _type(String key) => setState(() {
    if (_replacing) {
      _replacing = false;
      _value = '';
    }
    if (_value.length >= 24) return;
    _value += key;
  });

  void _backspace() => setState(() {
    _replacing = false;
    if (_value.isNotEmpty) _value = _value.substring(0, _value.length - 1);
  });

  void _submit() {
    final name = _value.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  /// Physical-keyboard support, for desktop builds and a console with a USB
  /// keyboard plugged in: the sheet owns its text, so nothing types into it
  /// unless this listens.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _backspace();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _submit();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    final character = event.character;
    if (character == null || character.isEmpty) return KeyEventResult.ignored;
    if (character.codeUnitAt(0) < 0x20) return KeyEventResult.ignored;
    _type(character);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: surface.card,
          border: Border(top: BorderSide(color: surface.borderStrong)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(19, 20, 19, 19),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.trackRenameTitle,
                        style: TextStyle(
                          color: surface.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    ConsoleSmallButton(
                      key: const Key('track_rename_cancel'),
                      label: l10n.cancel,
                      large: true,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 13),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: surface.background,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: surface.accent),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 15,
                    ),
                    child: Text(
                      _value,
                      key: const Key('track_rename_field'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _replacing
                            ? surface.textSecondary
                            : surface.textPrimary,
                        fontSize: 18,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 13),
                OnScreenKeyboard(
                  layout: OnScreenKeyboardLayout.text,
                  showNumberRow: true,
                  doneLabel: l10n.done,
                  onKey: _type,
                  onBackspace: _backspace,
                  onDone: _submit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
