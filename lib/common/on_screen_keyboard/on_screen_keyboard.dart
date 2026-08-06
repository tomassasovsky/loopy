import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:segno/theme/theme.dart';

/// Which key layout the on-screen keyboard offers.
enum OnScreenKeyboardLayout {
  /// Full QWERTY with a symbols layer.
  text,

  /// A compact numeric pad, for fields that only accept numbers.
  numeric,
}

/// Picks the layout a field's [TextInputType] calls for.
///
/// Anything numeric gets the pad; everything else — including passwords, which
/// are ordinary text behind the masking — gets QWERTY.
OnScreenKeyboardLayout layoutForInputType(TextInputType? type) {
  if (type == TextInputType.number ||
      type == TextInputType.phone ||
      type == const TextInputType.numberWithOptions(decimal: true)) {
    return OnScreenKeyboardLayout.numeric;
  }
  return OnScreenKeyboardLayout.text;
}

/// The console's on-screen keyboard: a pure key surface that reports presses
/// and holds no text state of its own.
///
/// Deliberately dumb — every edit is applied by the host against the focused
/// field's controller, so this widget never has to know what is being typed
/// into, and a field's own formatters and validators still run.
class OnScreenKeyboard extends StatefulWidget {
  /// Creates an [OnScreenKeyboard].
  const OnScreenKeyboard({
    required this.layout,
    required this.onKey,
    required this.onBackspace,
    required this.onDone,
    this.doneLabel,
    this.showNumberRow = false,
    super.key,
  });

  /// Which key set to draw.
  final OnScreenKeyboardLayout layout;

  /// Called with the character a pressed key produces.
  final ValueChanged<String> onKey;

  /// Called when the delete key is pressed.
  final VoidCallback onBackspace;

  /// Called when the user is finished with the field.
  final VoidCallback onDone;

  /// Caption for the action key. Defaults to a generic "done".
  ///
  /// A key that says what it *does* — "Join" over a WiFi passphrase — is worth
  /// more than a generic one on a surface with no other affordance to read.
  final String? doneLabel;

  /// Whether to draw a digit row above the letters.
  ///
  /// Off by default; on for fields that are full of digits. A passphrase is,
  /// and a layer switch per digit is unusable standing over a console.
  final bool showNumberRow;

  /// Key height, sized for a foot-console: pressed while standing, often with
  /// one hand. Public so the host sizes its panel from the keys rather than
  /// from a guess that can drift out of step with them.
  static const double keyHeight = 54;

  @override
  State<OnScreenKeyboard> createState() => _OnScreenKeyboardState();
}

class _OnScreenKeyboardState extends State<OnScreenKeyboard> {
  bool _shifted = false;
  bool _symbols = false;

  static const _row1 = 'qwertyuiop';
  static const _row2 = 'asdfghjkl';
  static const _row3 = 'zxcvbnm';
  static const _symRow1 = '1234567890';
  static const _symRow2 = r'-/:;()$&@"';
  static const _symRow3 = ".,?!'";
  static const _symRow3Wide = ".,?!'+=_";
  static const _symRow4 = r'#%*[]{}\|';

  void _tap(String key) {
    unawaited(HapticFeedback.selectionClick());
    widget.onKey(_shifted ? key.toUpperCase() : key);
    // Shift is one-shot, like every phone keyboard: holding it down is not an
    // option when the other hand is on an instrument.
    if (_shifted) setState(() => _shifted = false);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.layout == OnScreenKeyboardLayout.numeric) return _numericPad();
    // With the digit row drawn above the letters, the symbols layer no longer
    // has to spend its first row on digits, and gains the punctuation row the
    // mockups draw instead.
    final upper = _symbols
        ? (widget.showNumberRow
              ? [_symRow2, _symRow3Wide]
              : [_symRow1, _symRow2])
        : [_row1, _row2];
    final third = _symbols
        ? (widget.showNumberRow ? _symRow4 : _symRow3)
        : _row3;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showNumberRow) _keyRow(_symRow1.split('')),
        for (final row in upper) _keyRow(row.split('')),
        Row(
          children: [
            if (!_symbols)
              _special(
                icon: _shifted
                    ? Icons.arrow_upward
                    : Icons.arrow_upward_outlined,
                selected: _shifted,
                onPressed: () => setState(() => _shifted = !_shifted),
                semanticLabel: 'Shift',
              ),
            ...third.split('').map((k) => Expanded(child: _key(k))),
            _special(
              icon: Icons.backspace_outlined,
              onPressed: widget.onBackspace,
              semanticLabel: 'Delete',
            ),
          ],
        ),
        Row(
          children: [
            _special(
              label: _symbols ? 'abc' : '?123',
              onPressed: () => setState(() {
                _symbols = !_symbols;
                _shifted = false;
              }),
            ),
            Expanded(flex: 4, child: _key(' ', label: 'space')),
            _special(
              label: widget.doneLabel ?? 'done',
              onPressed: widget.onDone,
              primary: true,
            ),
          ],
        ),
      ],
    );
  }

  Widget _numericPad() {
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '.', '0'];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var row = 0; row < 4; row++)
          Row(
            children: [
              for (var col = 0; col < 3; col++)
                if (row * 3 + col < keys.length)
                  Expanded(child: _key(keys[row * 3 + col]))
                else
                  Expanded(
                    child: _special(
                      icon: Icons.backspace_outlined,
                      onPressed: widget.onBackspace,
                      semanticLabel: 'Delete',
                    ),
                  ),
            ],
          ),
        Row(
          children: [
            Expanded(
              child: _special(
                label: widget.doneLabel ?? 'done',
                onPressed: widget.onDone,
                primary: true,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _keyRow(List<String> keys) =>
      Row(children: [for (final k in keys) Expanded(child: _key(k))]);

  Widget _key(String value, {String? label}) {
    final display = label ?? (_shifted ? value.toUpperCase() : value);
    return Padding(
      padding: const EdgeInsets.all(3),
      child: _KeyCap(
        label: display,
        onPressed: () => _tap(value),
      ),
    );
  }

  Widget _special({
    required VoidCallback onPressed,
    String? label,
    IconData? icon,
    bool primary = false,
    bool selected = false,
    String? semanticLabel,
  }) {
    final cap = _KeyCap(
      label: label,
      icon: icon,
      primary: primary,
      selected: selected,
      semanticLabel: semanticLabel,
      onPressed: onPressed,
    );
    return Padding(
      padding: const EdgeInsets.all(3),
      child: label != null && !primary
          ? SizedBox(width: 92, child: cap)
          : primary
          ? SizedBox(width: 108, child: cap)
          : SizedBox(width: 72, child: cap),
    );
  }
}

/// One key.
///
/// Drawn from the surface tokens rather than from `FilledButton.tonal`, which
/// was the reason this keyboard never looked like the console it lives on: the
/// Material button brings its own container colour, elevation overlay and 40px
/// minimum geometry, none of which the mockups have and all of which fight the
/// hand-drawn surfaces beside it.
class _KeyCap extends StatelessWidget {
  const _KeyCap({
    required this.onPressed,
    this.label,
    this.icon,
    this.primary = false,
    this.selected = false,
    this.semanticLabel,
  });

  final VoidCallback onPressed;
  final String? label;
  final IconData? icon;
  final bool primary;
  final bool selected;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final fill = primary
        ? surface.accent
        : selected
        ? surface.accentSurface
        : surface.cardHigh;
    final tint = primary
        ? surface.onAccent
        : selected
        ? surface.accent
        // A modifier is a lower tier than a character: what you type should
        // read louder than how you type it.
        : icon != null || (label != null && label!.length > 1)
        ? surface.textSecondary
        : surface.textPrimary;
    return SizedBox(
      height: OnScreenKeyboard.keyHeight,
      child: Material(
        color: fill,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: primary ? surface.accent : surface.line,
              ),
            ),
            child: icon != null
                ? Icon(
                    icon,
                    size: 20,
                    color: tint,
                    semanticLabel: semanticLabel,
                  )
                : Text(
                    label ?? '',
                    style: TextStyle(
                      color: tint,
                      fontSize: 17,
                      fontWeight: primary ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
