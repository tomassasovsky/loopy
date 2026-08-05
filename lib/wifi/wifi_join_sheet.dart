import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// Shortest passphrase WPA/WPA2 accepts. Checked here so a too-short
/// passphrase fails in the sheet, where it can be corrected, rather than being
/// handed to the supplicant and coming back as a generic association failure
/// several seconds later.
const int kMinWpaPassphraseLength = 8;

/// Asks for a network's passphrase.
///
/// Returns the passphrase, or null when dismissed.
///
/// A bottom sheet with the keys built in, rather than a dialog over the
/// app-wide on-screen keyboard host: the console has no physical keyboard, and
/// the host's keyboard is driven by *field focus*, which would put the keys in
/// a second panel underneath a dialog that is itself trying to centre itself in
/// what is left. The mockups draw one surface — title, field, keys — and that
/// is what this is.
Future<String?> showWifiJoinSheet(
  BuildContext context, {
  required String ssid,
  required String security,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: context.surface.scrim,
  // Material caps bottom sheets at 640px; the mockups run this one edge to
  // edge, and a 640px keyboard on a 1920px console would be a toy.
  constraints: const BoxConstraints(),
  builder: (sheetContext) => _WifiJoinSheet(ssid: ssid, security: security),
);

class _WifiJoinSheet extends StatefulWidget {
  const _WifiJoinSheet({required this.ssid, required this.security});

  final String ssid;
  final String security;

  @override
  State<_WifiJoinSheet> createState() => _WifiJoinSheetState();
}

class _WifiJoinSheetState extends State<_WifiJoinSheet> {
  /// The passphrase being typed. Held here rather than in a controller behind
  /// a real `TextField`: a focused field would summon the app-wide on-screen
  /// keyboard on top of this sheet's own keys.
  String _value = '';
  bool _showLengthError = false;

  void _type(String key) => setState(() {
    _value += key;
    _showLengthError = false;
  });

  void _backspace() {
    if (_value.isEmpty) return;
    setState(() {
      _value = _value.substring(0, _value.length - 1);
      _showLengthError = false;
    });
  }

  void _submit() {
    if (_value.length < kMinWpaPassphraseLength) {
      setState(() => _showLengthError = true);
      return;
    }
    Navigator.of(context).pop(_value);
  }

  /// Physical-keyboard support, for desktop builds and for a console with a
  /// USB keyboard plugged in: the sheet owns its text, so nothing types into
  /// it unless this listens.
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
    // Control characters arrive as single-code-unit strings below space.
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
                        widget.security,
                        style: TextStyle(
                          color: surface.textMuted,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    ConsoleSmallButton(
                      key: const Key('wifi_join_cancel'),
                      label: l10n.cancel,
                      large: true,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 13),
                _PassphraseField(
                  value: _value,
                  invalid: _showLengthError,
                ),
                if (_showLengthError) ...[
                  const SizedBox(height: 8),
                  Text(
                    l10n.wifiPassphraseTooShort,
                    key: const Key('wifi_join_error'),
                    style: TextStyle(color: surface.rec, fontSize: 13),
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
        ),
      ),
    );
  }
}

/// The masked passphrase display: dots and a caret, drawn rather than typed
/// into (see [_WifiJoinSheetState._value]).
class _PassphraseField extends StatelessWidget {
  const _PassphraseField({required this.value, required this.invalid});

  final String value;
  final bool invalid;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: invalid ? surface.rec : surface.accent),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        child: Row(
          children: [
            Flexible(
              child: Text(
                '•' * value.length,
                key: const Key('wifi_join_field'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: surface.textPrimary, fontSize: 18),
              ),
            ),
            const SizedBox(width: 2),
            _Caret(color: surface.accent, restartOn: value.length),
          ],
        ),
      ),
    );
  }
}

/// The blinking insertion point. Static in tests and under reduce-motion —
/// a caret that never settles would leave every screenshot golden flapping.
class _Caret extends StatefulWidget {
  const _Caret({required this.color, required this.restartOn});

  final Color color;

  /// Changes whenever a key is pressed. Like every text editor, the caret
  /// shows itself again on input rather than blinking through a keystroke.
  final int restartOn;

  @override
  State<_Caret> createState() => _CaretState();
}

class _CaretState extends State<_Caret> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1060),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller
        ..stop()
        ..value = 1;
    } else if (!_controller.isAnimating) {
      unawaited(_controller.repeat());
    }
  }

  @override
  void didUpdateWidget(_Caret oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.restartOn != oldWidget.restartOn &&
        !MediaQuery.disableAnimationsOf(context)) {
      unawaited(_controller.repeat());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller.drive(
        TweenSequence<double>([
          TweenSequenceItem(tween: ConstantTween<double>(1), weight: 1),
          TweenSequenceItem(tween: ConstantTween<double>(0), weight: 1),
        ]),
      ),
      child: Container(width: 2, height: 22, color: widget.color),
    );
  }
}
