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
    this.showNumberRow = false,
    this.doneLabel,
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

  /// Whether to keep a digit row above the letters instead of hiding digits
  /// behind the symbols layer. The WiFi join sheet asks for it, because
  /// passphrases are full of digits and a layer switch per digit is
  /// unusable standing over a console.
  final bool showNumberRow;

  /// Label for the action key. Defaults to the generic `done`; surfaces that
  /// know what finishing means name it (the join sheet says "Join").
  final String? doneLabel;

  /// Key height, sized for a foot-console: pressed while standing, often with
  /// one hand. Public so the host sizes its panel from the keys rather than
  /// from a guess that can drift out of step with them.
  static const double keyHeight = 50;

  /// Gap between keys, from the mockups.
  static const double keyGap = 7;

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
  static const _digits = '1234567890';

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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showNumberRow && !_symbols) ...[
          _keyRow(_digits.split('')),
          const SizedBox(height: OnScreenKeyboard.keyGap),
        ],
        _keyRow((_symbols ? _symRow1 : _row1).split('')),
        const SizedBox(height: OnScreenKeyboard.keyGap),
        _keyRow((_symbols ? _symRow2 : _row2).split('')),
        const SizedBox(height: OnScreenKeyboard.keyGap),
        Row(
          children: [
            if (!_symbols) ...[
              Expanded(
                flex: 2,
                child: _special(
                  icon: _shifted ? Icons.arrow_upward : Icons.arrow_upward,
                  selected: _shifted,
                  onPressed: () => setState(() => _shifted = !_shifted),
                  semanticLabel: 'Shift',
                ),
              ),
              const SizedBox(width: OnScreenKeyboard.keyGap),
            ],
            for (final k in (_symbols ? _symRow3 : _row3).split('')) ...[
              Expanded(child: _key(k)),
              const SizedBox(width: OnScreenKeyboard.keyGap),
            ],
            Expanded(
              flex: 2,
              child: _special(
                icon: Icons.backspace_outlined,
                onPressed: widget.onBackspace,
                semanticLabel: 'Delete',
              ),
            ),
          ],
        ),
        const SizedBox(height: OnScreenKeyboard.keyGap),
        Row(
          children: [
            Expanded(
              child: _special(
                label: _symbols ? 'abc' : '?123',
                onPressed: () => setState(() {
                  _symbols = !_symbols;
                  _shifted = false;
                }),
              ),
            ),
            const SizedBox(width: OnScreenKeyboard.keyGap),
            Expanded(flex: 3, child: _key(' ', label: 'space')),
            const SizedBox(width: OnScreenKeyboard.keyGap),
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

  Widget _numericPad() {
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '.', '0'];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var row = 0; row < 4; row++) ...[
          if (row > 0) const SizedBox(height: OnScreenKeyboard.keyGap),
          Row(
            children: [
              for (var col = 0; col < 3; col++) ...[
                if (col > 0) const SizedBox(width: OnScreenKeyboard.keyGap),
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
            ],
          ),
        ],
        const SizedBox(height: OnScreenKeyboard.keyGap),
        _special(
          label: widget.doneLabel ?? 'done',
          onPressed: widget.onDone,
          primary: true,
        ),
      ],
    );
  }

  Widget _keyRow(List<String> keys) => Row(
    children: [
      for (final k in keys) ...[
        if (k != keys.first) const SizedBox(width: OnScreenKeyboard.keyGap),
        Expanded(child: _key(k)),
      ],
    ],
  );

  Widget _key(String value, {String? label}) {
    final display = label ?? (_shifted ? value.toUpperCase() : value);
    return _KeyCap(
      label: display,
      onPressed: () => _tap(value),
    );
  }

  Widget _special({
    required VoidCallback onPressed,
    String? label,
    IconData? icon,
    bool primary = false,
    bool selected = false,
    String? semanticLabel,
  }) => _KeyCap(
    label: label,
    icon: icon,
    onPressed: onPressed,
    primary: primary,
    selected: selected,
    semanticLabel: semanticLabel,
  );
}

/// One key: a flat, bordered cap on the design system's raised surface.
///
/// Not a Material button — `FilledButton.tonal` brings its own container
/// colour, elevation overlay and 40px minimum geometry, which is why the
/// pre-design keyboard did not look like the console it lives on.
class _KeyCap extends StatelessWidget {
  const _KeyCap({
    required this.onPressed,
    this.label,
    this.icon,
    this.primary = false,
    this.selected = false,
    this.semanticLabel,
  });

  final String? label;
  final IconData? icon;
  final VoidCallback onPressed;
  final bool primary;
  final bool selected;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final background = primary
        ? surface.accent
        : selected
        ? surface.control
        : surface.cardHigh;
    final name = semanticLabel;
    return Semantics(
      button: true,
      label: name,
      // A glyph key ('⌫', '⇧') names itself through [semanticLabel]; leaving
      // the glyph in the tree as well merges the two into one unreadable
      // label ("Delete ⌫").
      excludeSemantics: name != null,
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: primary ? surface.accent : surface.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            height: OnScreenKeyboard.keyHeight,
            child: Center(
              child: icon != null
                  ? Icon(
                      icon,
                      size: 20,
                      color: primary ? surface.onAccent : surface.textPrimary,
                    )
                  : Text(
                      label ?? '',
                      style: TextStyle(
                        color: primary ? surface.onAccent : surface.textPrimary,
                        fontSize: 16,
                        fontWeight: primary ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
