import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// Asks for a tempo, drawn to `LOOP / loop-tempo`: a number pad with a tap pad
/// beside it, because the row says "tap or type" and both have to work.
///
/// Returns the typed bpm, or null when dismissed. Tapping is different: it
/// goes straight to the engine as it happens (a tempo derived from taps is
/// runtime state, not something to hold and submit), so the sheet reports it
/// through [onTap] and closes on the first result.
Future<double?> showTempoSheet(
  BuildContext context, {
  required double initial,
  required EngineResult Function() onTap,
}) => showModalBottomSheet<double>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: context.surface.scrim,
  constraints: const BoxConstraints(),
  builder: (sheetContext) => _TempoSheet(initial: initial, onTap: onTap),
);

class _TempoSheet extends StatefulWidget {
  const _TempoSheet({required this.initial, required this.onTap});

  final double initial;
  final EngineResult Function() onTap;

  @override
  State<_TempoSheet> createState() => _TempoSheetState();
}

class _TempoSheetState extends State<_TempoSheet> {
  late String _value = widget.initial.toStringAsFixed(1);
  bool _typed = false;

  void _press(String key) => setState(() {
    // The first keypress replaces the shown tempo rather than appending to
    // it: the field opens with the current value, and a performer typing 90
    // means 90, not 120.090.
    if (!_typed) {
      _typed = true;
      _value = '';
    }
    if (key == '.' && _value.contains('.')) return;
    if (_value.length >= 6) return;
    _value += key;
  });

  void _backspace() => setState(() {
    _typed = true;
    if (_value.isNotEmpty) _value = _value.substring(0, _value.length - 1);
  });

  double? get _parsed {
    final bpm = double.tryParse(_value);
    if (bpm == null || bpm <= 0) return null;
    return bpm;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;

    return DecoratedBox(
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
                    l10n.loopTempoTitle,
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.loopBpmUnit,
                      style: TextStyle(
                        color: surface.textMuted,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  ConsoleSmallButton(
                    key: const Key('tempo_sheet_cancel'),
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
                    key: const Key('tempo_sheet_field'),
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 18,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 13),
              // Centred and narrow: a number pad stretched across a 1920px
              // console would put its keys a hand's width apart.
              Center(
                child: SizedBox(
                  width: 520,
                  child: _NumberPad(
                    onKey: _press,
                    onBackspace: _backspace,
                    onTap: () {
                      unawaited(HapticFeedback.selectionClick());
                      widget.onTap();
                    },
                    onSet: _parsed == null
                        ? null
                        : () => Navigator.of(context).pop(_parsed),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The pad itself: calculator order, as drawn, with Tap and Set on the last
/// row.
class _NumberPad extends StatelessWidget {
  const _NumberPad({
    required this.onKey,
    required this.onBackspace,
    required this.onTap,
    required this.onSet,
  });

  final ValueChanged<String> onKey;
  final VoidCallback onBackspace;
  final VoidCallback onTap;
  final VoidCallback? onSet;

  static const List<List<String>> _rows = [
    ['7', '8', '9'],
    ['4', '5', '6'],
    ['1', '2', '3'],
    ['.', '0', '⌫'],
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in _rows) ...[
          if (row != _rows.first) const SizedBox(height: 7),
          Row(
            children: [
              for (final key in row) ...[
                if (key != row.first) const SizedBox(width: 7),
                Expanded(
                  child: _PadKey(
                    label: key,
                    onPressed: () => key == '⌫' ? onBackspace() : onKey(key),
                  ),
                ),
              ],
            ],
          ),
        ],
        const SizedBox(height: 7),
        Row(
          children: [
            Expanded(
              child: _PadKey(
                key: const Key('tempo_sheet_tap'),
                label: context.l10n.loopTempoTapAction,
                onPressed: onTap,
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: _PadKey(
                key: const Key('tempo_sheet_set'),
                label: context.l10n.loopTempoSetAction,
                primary: true,
                onPressed: onSet,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _PadKey extends StatelessWidget {
  const _PadKey({
    required this.label,
    required this.onPressed,
    this.primary = false,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Opacity(
      opacity: onPressed == null ? 0.5 : 1,
      child: Material(
        color: primary ? surface.accent : surface.cardHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: primary ? surface.accent : surface.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            height: 50,
            child: Center(
              child: Text(
                label,
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
