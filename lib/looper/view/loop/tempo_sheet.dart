import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/theme/theme.dart';

/// Asks for a tempo, drawn to `LOOP / loop-tempo`: a number pad with a tap pad
/// beside it, because the row says "tap or type" and both have to work.
///
/// Returns the bpm to apply, or null when dismissed.
///
/// Tapping goes straight to the engine — a tempo derived from taps is the
/// engine's own runtime state — so the sheet reports each tap through [onTap]
/// and then MIRRORS what the engine made of it, which is the only feedback a
/// tap has. Without that the pad looks dead: taps land, the engine converges,
/// and the field goes on showing whatever it opened with.
Future<double?> showTempoSheet(
  BuildContext context, {
  required double initial,
  required EngineResult Function() onTap,
}) {
  // A modal route is built by the navigator, not by the caller, so it sees
  // nothing the caller's subtree provides. The bloc is handed across
  // explicitly — the sheet needs it to show what the taps did.
  final bloc = context.read<LooperBloc>();
  return showModalBottomSheet<double>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: context.surface.scrim,
    constraints: const BoxConstraints(),
    builder: (sheetContext) => BlocProvider<LooperBloc>.value(
      value: bloc,
      child: _TempoSheet(initial: initial, onTap: onTap),
    ),
  );
}

class _TempoSheet extends StatefulWidget {
  const _TempoSheet({required this.initial, required this.onTap});

  final double initial;
  final EngineResult Function() onTap;

  @override
  State<_TempoSheet> createState() => _TempoSheetState();
}

class _TempoSheetState extends State<_TempoSheet> {
  // No tempo yet (`0`) opens an empty field rather than a literal "0.0" the
  // performer would have to clear first.
  late String _value = widget.initial > 0
      ? widget.initial.toStringAsFixed(1)
      : '';
  late bool _typed = widget.initial <= 0;

  /// True once the pad has been tapped: from then on the field follows the
  /// engine's derived tempo rather than the text, until something is typed.
  bool _tapping = false;

  void _press(String key) => setState(() {
    _tapping = false;
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
    _tapping = false;
    _typed = true;
    if (_value.isNotEmpty) _value = _value.substring(0, _value.length - 1);
  });

  /// What the field shows: the engine's tempo while tapping, the typed text
  /// otherwise.
  String _display(BuildContext context) {
    if (!_tapping) return _value;
    final engine = context.watch<LooperBloc>().state.transport.tempoBpm;
    if (engine <= 0) return _value;
    return engine.toStringAsFixed(1);
  }

  double? _parsed(String display) {
    final bpm = double.tryParse(display);
    if (bpm == null || bpm <= 0) return null;
    return bpm;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final display = _display(context);
    final parsed = _parsed(display);

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
                    display,
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
                      // Two taps make a tempo; the first only starts the
                      // measurement. Following the engine from the first tap
                      // means the field moves as soon as it has anything to
                      // say.
                      setState(() => _tapping = true);
                    },
                    onSet: parsed == null
                        ? null
                        : () => Navigator.of(context).pop(parsed),
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
