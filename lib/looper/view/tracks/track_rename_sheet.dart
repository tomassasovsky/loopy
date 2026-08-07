import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// Asks for track [channel]'s new name, starting from [current]; resolves to
/// the trimmed name, or null if it was cancelled or left empty.
///
/// The console has **one keyboard**, and it is built into this sheet — the
/// same reason `showWifiJoinSheet` is a sheet rather than a dialog. The
/// app-wide keyboard host is driven by *field focus*, so a dialog holding a
/// real `TextField` would summon a second keyboard panel underneath a dialog
/// that is itself trying to centre in what is left of the screen.
///
/// The stage keeps its own `showRenameTrackDialog`: that surface has a
/// physical keyboard behind it and no room for a full-width one.
Future<String?> showTrackRenameSheet(
  BuildContext context, {
  required int channel,
  required String current,
}) {
  final surface = context.surface;
  return showModalBottomSheet<String>(
    context: context,
    barrierColor: surface.scrim.withValues(alpha: 0.62),
    backgroundColor: Colors.transparent,
    // Material caps a bottom sheet at 640px wide, which would make a toy of a
    // keyboard on a 1920px console. Same override the join sheet takes.
    constraints: const BoxConstraints(),
    isScrollControlled: true,
    builder: (_) => _TrackRenameSheet(channel: channel, current: current),
  );
}

class _TrackRenameSheet extends StatefulWidget {
  const _TrackRenameSheet({required this.channel, required this.current});

  final int channel;
  final String current;

  @override
  State<_TrackRenameSheet> createState() => _TrackRenameSheetState();
}

class _TrackRenameSheetState extends State<_TrackRenameSheet> {
  /// The sheet holds its own text — there is no [TextField] to hold it.
  late String _name = widget.current;

  void _type(String key) => setState(() => _name += key);

  void _backspace() {
    if (_name.isEmpty) return;
    setState(() => _name = _name.substring(0, _name.length - 1));
  }

  /// An empty name is not a rename, so Save does nothing rather than closing:
  /// `TracksCubit.rename` drops an empty name anyway, and a sheet that shut on
  /// one would look like it had renamed the track to nothing.
  void _submit() {
    final trimmed = _name.trim();
    if (trimmed.isEmpty) return;
    Navigator.of(context).pop(trimmed);
  }

  /// Physical keys too — for desktop builds, and for a console with a USB
  /// keyboard attached.
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
    final l10n = context.l10n;
    final surface = context.surface;

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Container(
        key: const Key('track_rename_sheet'),
        decoration: BoxDecoration(
          color: surface.card,
          border: Border.all(color: surface.borderStrong),
        ),
        padding: const EdgeInsets.fromLTRB(19, 20, 19, 19),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  l10n.tracksRenameSheetTitle,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 18,
                    height: 1.17,
                    leadingDistribution: TextLeadingDistribution.even,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.tracksOrdinal(widget.channel + 1),
                    style: TextStyle(
                      color: surface.textMuted,
                      fontSize: 14,
                      height: 1.21,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                  ),
                ),
                ConsoleDialogButton(
                  key: const Key('track_rename_cancel'),
                  label: l10n.cancel,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _NameField(text: _name),
            const SizedBox(height: 13),
            OnScreenKeyboard(
              layout: OnScreenKeyboardLayout.text,
              showNumberRow: true,
              doneLabel: l10n.save,
              onKey: _type,
              onBackspace: _backspace,
              onDone: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// The name being typed, with a caret showing the keys below are live.
///
/// Set in the mono face, as the mockup draws it and as the join sheet's field
/// is: this is the literal string that will be stored, so it is shown in the
/// face the console uses for literal machine values rather than the one it
/// uses for prose.
class _NameField extends StatelessWidget {
  const _NameField({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      textField: true,
      label: context.l10n.a11yTracksRenameField,
      value: text,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        decoration: BoxDecoration(
          color: surface.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: surface.accent),
        ),
        child: Row(
          children: [
            Flexible(
              child: Text(
                text,
                key: const Key('track_rename_field'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: surface.textPrimary,
                  fontFamily: SurfaceTheme.monoFont,
                  fontSize: 18,
                  height: 1.17,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
            ),
            const SizedBox(width: 2),
            Container(width: 2, height: 22, color: surface.accent),
          ],
        ),
      ),
    );
  }
}
