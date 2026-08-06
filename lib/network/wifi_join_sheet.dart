import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/network/network_surface.dart';
import 'package:segno/theme/theme.dart';

/// WPA2's own floor. Checked here, where it can be corrected, rather than
/// handed to the supplicant and returned seconds later as a generic
/// association failure that names nothing.
const int kWpa2PassphraseMinLength = 8;

/// Asks for [ssid]'s passphrase; resolves to it, or null if cancelled.
///
/// The console has **one keyboard**, and it is built into this sheet. The
/// obvious implementation — a dialog holding a real [TextField] over the
/// app-wide on-screen keyboard host — does not work here: that host is driven
/// by *field focus*, so focusing the field summons a second keyboard panel
/// underneath a dialog that is itself trying to centre in what is left.
Future<String?> showWifiJoinSheet(
  BuildContext context, {
  required String ssid,
  String? security,
}) {
  final surface = context.surface;
  return showModalBottomSheet<String>(
    context: context,
    barrierColor: surface.scrim.withValues(alpha: 0.62),
    backgroundColor: Colors.transparent,
    // Material caps a bottom sheet at 640px wide. That cap would make a toy of
    // a keyboard on a 1920px console, so the sheet is full-bleed.
    constraints: const BoxConstraints(),
    isScrollControlled: true,
    builder: (sheetContext) => _WifiJoinSheet(ssid: ssid, security: security),
  );
}

class _WifiJoinSheet extends StatefulWidget {
  const _WifiJoinSheet({required this.ssid, this.security});

  final String ssid;
  final String? security;

  @override
  State<_WifiJoinSheet> createState() => _WifiJoinSheetState();
}

class _WifiJoinSheetState extends State<_WifiJoinSheet> {
  /// The sheet holds its own text — there is no [TextField] to hold it.
  String _passphrase = '';
  bool _tooShort = false;

  void _type(String key) => setState(() {
    _passphrase += key;
    _tooShort = false;
  });

  void _backspace() {
    if (_passphrase.isEmpty) return;
    setState(() {
      _passphrase = _passphrase.substring(0, _passphrase.length - 1);
      _tooShort = false;
    });
  }

  void _submit() {
    if (_passphrase.length < kWpa2PassphraseMinLength) {
      setState(() => _tooShort = true);
      return;
    }
    Navigator.of(context).pop(_passphrase);
  }

  /// Physical keys too — for desktop builds, and for a console with a USB
  /// keyboard attached. The on-screen keys are the console's only guaranteed
  /// input, not its only possible one.
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
        key: const Key('wifi_join_sheet'),
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
                  l10n.wifiJoinSheetTitle(widget.ssid),
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.security ?? '',
                    style: TextStyle(
                      color: surface.textMuted,
                      fontSize: 14,
                      height: 1.21,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                  ),
                ),
                NetworkSmallButton(
                  key: const Key('wifi_join_cancel'),
                  label: l10n.cancel,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _MaskedField(text: _passphrase, invalid: _tooShort),
            if (_tooShort) ...[
              const SizedBox(height: 10),
              Text(
                l10n.wifiPassphraseTooShort(kWpa2PassphraseMinLength),
                key: const Key('wifi_join_too_short'),
                style: TextStyle(color: surface.rec, fontSize: 14),
              ),
            ],
            const SizedBox(height: 13),
            OnScreenKeyboard(
              layout: OnScreenKeyboardLayout.text,
              showNumberRow: true,
              doneLabel: l10n.wifiJoinAction,
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

/// The passphrase as dots, with a caret that shows the field is live.
///
/// A caret rather than a blinking cursor inside a real field: there is no
/// field, and without a caret an empty box gives no sign that the keys below
/// it are wired to anything.
class _MaskedField extends StatelessWidget {
  const _MaskedField({required this.text, required this.invalid});

  final String text;
  final bool invalid;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      decoration: BoxDecoration(
        color: surface.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: invalid ? surface.rec : surface.accent),
      ),
      child: Row(
        children: [
          Text(
            '•' * text.length,
            key: const Key('wifi_join_field'),
            style: TextStyle(
              color: surface.textPrimary,
              fontFamily: SurfaceTheme.monoFont,
              fontSize: 18,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(width: 2),
          Container(width: 2, height: 22, color: surface.accent),
        ],
      ),
    );
  }
}
