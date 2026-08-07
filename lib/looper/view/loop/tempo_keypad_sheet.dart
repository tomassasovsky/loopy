import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/theme/theme.dart';

/// Asks for a tempo on the console's own number pad.
///
/// A sheet rather than a row that opens in place, because this is an editor
/// and not a choice — the same call `NETWORK / wifi-password` and
/// `TRACKS / track-rename` make for the console's other typed values.
///
/// A modal route is built by the navigator and sees nothing the caller's
/// subtree provides, so [LooperBloc] is handed across explicitly rather than
/// looked up inside.
Future<void> showTempoKeypadSheet(BuildContext context) {
  final surface = context.surface;
  final looper = context.read<LooperBloc>();
  final tempo = context.read<TempoCubit>();
  return showModalBottomSheet<void>(
    context: context,
    barrierColor: surface.scrim.withValues(alpha: 0.62),
    backgroundColor: Colors.transparent,
    // Material caps a bottom sheet at 640px wide, which would make a toy of a
    // keypad on a 1920px console. Full-bleed, as the wifi sheet is.
    constraints: const BoxConstraints(),
    isScrollControlled: true,
    builder: (_) => BlocProvider<LooperBloc>.value(
      value: looper,
      child: _TempoKeypadSheet(tempo: tempo),
    ),
  );
}

class _TempoKeypadSheet extends StatefulWidget {
  const _TempoKeypadSheet({required this.tempo});

  final TempoCubit tempo;

  @override
  State<_TempoKeypadSheet> createState() => _TempoKeypadSheetState();
}

class _TempoKeypadSheetState extends State<_TempoKeypadSheet> {
  /// What has been typed, or null while the field is mirroring the engine.
  ///
  /// Null rather than "the engine's value as a string": the first keypress
  /// **replaces** what is shown rather than appending to it, and a buffer
  /// seeded with `120.0` would make the first `9` read `120.09`.
  String? _typed;

  /// The most characters the field will hold — `300.0` is the longest tempo
  /// the engine accepts, so anything past this cannot become a valid value.
  ///
  /// A cap and not just a validator: `_onKey` handles `KeyRepeatEvent`, so a
  /// held digit on an attached USB keyboard would otherwise grow the buffer
  /// without bound until the field's text overflowed its row.
  static const int _maxDigits = 5;

  /// The width the mockups give the pad. Centred rather than stretched: keys
  /// 600px wide on a 1920px console are a worse target than close ones.
  static const double _padWidth = 504;
  static const double _keyGap = 7;
  static const double _keyHeight = 50;

  String _shown(double bpm) =>
      _typed ?? (bpm > 0 ? bpm.toStringAsFixed(1) : '');

  void _digit(String key) {
    final buffer = _typed ?? '';
    if (buffer.length >= _maxDigits) return;
    setState(() => _typed = buffer + key);
  }

  void _dot() {
    final buffer = _typed ?? '';
    if (buffer.contains('.') || buffer.length >= _maxDigits) return;
    setState(() => _typed = '$buffer.');
  }

  /// Backspace edits what is on screen, so it seeds the buffer from the
  /// mirrored value first — a field showing `120.0` that ignores ⌫ reads as
  /// broken.
  void _backspace(double bpm) {
    final buffer = _typed ?? _shown(bpm);
    if (buffer.isEmpty) return;
    setState(() => _typed = buffer.substring(0, buffer.length - 1));
  }

  /// Registers a tap and hands the field back to the engine.
  ///
  /// A tapped tempo is runtime state with nothing to submit — it never reaches
  /// [TempoCubit]'s persisted intent — so the only feedback a tap pad can give
  /// is to show what the engine made of the taps. Clearing the buffer is what
  /// puts the field back on that mirror.
  void _tap() {
    widget.tempo.tapTempo();
    setState(() => _typed = null);
  }

  /// Submits the typed tempo, clamped to what the engine will accept.
  ///
  /// The engine clamps `setTempo` to `kTempoRange` itself and says nothing, so
  /// submitting 999 would close the sheet and quietly leave the rig at 300.
  /// Clamping here means the value the sheet sends is the value the rig takes.
  void _set() {
    final value = double.tryParse(_typed?.trim() ?? '');
    if (value != null && value > 0) {
      unawaited(
        widget.tempo.setTempo(
          value.clamp(kTempoRange.$1, kTempoRange.$2),
        ),
      );
    }
    Navigator.of(context).pop();
  }

  /// Physical keys too — for desktop builds and for a console with a USB
  /// keyboard attached, exactly as the wifi sheet does it.
  KeyEventResult _onKey(double bpm, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _backspace(bpm);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _set();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    final character = event.character;
    if (character == null) return KeyEventResult.ignored;
    if (character == '.') {
      _dot();
      return KeyEventResult.handled;
    }
    if (RegExp(r'^[0-9]$').hasMatch(character)) {
      _digit(character);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    // Watched, not read: while Tap is being pressed this field IS the readout
    // of what the engine converged on.
    final bpm = context.watch<LooperBloc>().state.transport.tempoBpm;

    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) => _onKey(bpm, event),
      child: Semantics(
        label: l10n.a11yLoopTempoSheet,
        child: Container(
          key: const Key('tempo_keypad_sheet'),
          decoration: BoxDecoration(
            color: surface.card,
            border: Border(top: BorderSide(color: surface.borderStrong)),
          ),
          padding: const EdgeInsets.fromLTRB(19, 20, 19, 19),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    l10n.loopTempoRow,
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.loopTempoSheetUnit,
                      style: TextStyle(
                        color: surface.textMuted,
                        fontSize: 14,
                        height: 1.21,
                        leadingDistribution: TextLeadingDistribution.even,
                      ),
                    ),
                  ),
                  ConsoleSmallButton(
                    key: const Key('tempo_keypad_cancel'),
                    label: l10n.cancel,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _Field(text: _shown(bpm)),
              const SizedBox(height: 13),
              Center(
                child: SizedBox(
                  width: _padWidth,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final row in const [
                        ['7', '8', '9'],
                        ['4', '5', '6'],
                        ['1', '2', '3'],
                      ]) ...[
                        _keyRow([
                          for (final digit in row)
                            _key(
                              id: 'tempo_keypad_$digit',
                              label: digit,
                              onTap: () => _digit(digit),
                            ),
                        ]),
                        const SizedBox(height: _keyGap),
                      ],
                      _keyRow([
                        _key(
                          id: 'tempo_keypad_dot',
                          label: '.',
                          semanticLabel: l10n.loopTempoSheetDecimal,
                          onTap: _dot,
                        ),
                        _key(
                          id: 'tempo_keypad_0',
                          label: '0',
                          onTap: () => _digit('0'),
                        ),
                        _key(
                          id: 'tempo_keypad_backspace',
                          // A glyph, not the '⌫' the mockup sets: the text
                          // face does not carry U+232B and a tofu box is a
                          // worse mark than none — the same call
                          // `ConsolePickRow`'s check makes.
                          icon: Icons.backspace_outlined,
                          label: l10n.loopTempoSheetBackspace,
                          muted: true,
                          onTap: () => _backspace(bpm),
                        ),
                      ]),
                      const SizedBox(height: _keyGap),
                      _keyRow([
                        _key(
                          id: 'tempo_keypad_tap',
                          label: l10n.tapTempoButton,
                          emphasis: true,
                          onTap: _tap,
                        ),
                        _key(
                          id: 'tempo_keypad_set',
                          label: l10n.loopTempoSheetSet,
                          emphasis: true,
                          primary: true,
                          onTap: _set,
                        ),
                      ]),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _keyRow(List<Widget> keys) => Row(
    children: [
      for (final (index, key) in keys.indexed) ...[
        if (index > 0) const SizedBox(width: _keyGap),
        Expanded(child: key),
      ],
    ],
  );

  Widget _key({
    required String id,
    required String label,
    required VoidCallback onTap,
    IconData? icon,
    String? semanticLabel,
    bool muted = false,
    bool emphasis = false,
    bool primary = false,
  }) => _PadKey(
    key: Key(id),
    label: label,
    icon: icon,
    semanticLabel: semanticLabel ?? label,
    height: _keyHeight,
    muted: muted,
    emphasis: emphasis,
    primary: primary,
    onTap: onTap,
  );
}

/// The typed tempo, with a caret that shows the pad below it is wired to
/// something. The wifi sheet's masked field, unmasked.
class _Field extends StatelessWidget {
  const _Field({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      decoration: BoxDecoration(
        color: surface.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: surface.accent),
      ),
      child: Row(
        children: [
          // Flexible, so a long buffer ellipsises instead of overflowing the
          // row — the field is 18px mono on a 1920px sheet, but nothing about
          // the layout should depend on that staying true.
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              key: const Key('tempo_keypad_field'),
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
    );
  }
}

/// One key of the pad. [primary] is the accent-filled Set; [icon] replaces
/// [label] on the one key whose mark is not a character the text face has.
class _PadKey extends StatelessWidget {
  const _PadKey({
    required this.label,
    required this.semanticLabel,
    required this.height,
    required this.muted,
    required this.emphasis,
    required this.primary,
    required this.onTap,
    this.icon,
    super.key,
  });

  final String label;
  final IconData? icon;
  final String semanticLabel;
  final double height;
  final bool muted;
  final bool emphasis;
  final bool primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final tint = primary
        ? surface.onAccent
        : muted
        ? surface.textSecondary
        : surface.textPrimary;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: primary ? surface.accent : surface.cardHigh,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: primary ? surface.accent : surface.line),
          ),
          child: icon != null
              ? Icon(icon, size: 19, color: tint)
              : Text(
                  label,
                  style: TextStyle(
                    color: tint,
                    fontSize: 17,
                    height: 1.18,
                    leadingDistribution: TextLeadingDistribution.even,
                    fontWeight: emphasis ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
        ),
      ),
    );
  }
}
