import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/theme/theme.dart';

// ---------------------------------------------------------------------------
// Faceplate geometry (millimetres), taken verbatim from the Segno top plate in
// hardware/enclosure/segno_enclosure.py so the on-screen replica matches the 3D
// model. u = player left->right (0..fpW); v = front->rear (0..fpV).
// ---------------------------------------------------------------------------
const _fpW = 846.0; // faceplate width
const _fpV = 406.6; // faceplate sloped length (control area)
const _slotW = 78.0; // ASP-1 foot-plate slot (u)
const _slotD = 103.0; // ASP-1 foot-plate slot (v)
const _row1V = 61.5; // front-row pedal centre (v)
const _row2V = 229.5; // CLEAR/BANK centre (v)
const _screenTopV = 372.0; // rear edge of both screens (v)
const _ledBehind = 12.0; // LED_GAP — status LED behind a pedal (toward rear)
const _ledD = 5.1; // D_LED
const _silkH = 25.0; // SILK_H — single cap height for every legend line
const _silkCw = 0.66; // SILK_CW — est. glyph width = SILK_H * SILK_CW per char
const _silkLineSpacing = 1.15; // line-to-line pitch multiplier on SILK_H
const _silkNoLedGap = 8.0; // label lift above a plain pedal rear edge
const _silkLedExtra = 7.0; // extra lift above CLEAR/BANK LED centreline
const _ringOd = 58.0; // encoder ring outer diameter
const _colU = 119.55; // 7" screen + encoder column (pedal 1/2 gap)
const _s16Uc = 625.3; // 16" screen centre (u)
const _bigW = 344.0; // 16" aperture width
const _bigH = 194.0; // 16" aperture height
const _smallW = 156.0; // 7" aperture width
const _smallH = 88.0; // 7" aperture height

/// The u of front-row pedal [i] (`0..7`), evenly spaced inside the edge margin.
double _pedalU(int i) => 69.0 + (777.0 - 69.0) * i / 7.0;

/// Renders the Segno top plate to scale from injected state alone — the two
/// screen apertures (a 7" waveform on the left, the main looper screen on the
/// right), the encoder + activity ring, and the footswitches. Pure
/// presentation: no transport, cubit, or bloc dependency, so it pumps from a
/// [PedalStateFrame] and a handful of callbacks alone.
///
/// [selected] highlights buttons for the pedal-assignment UI (FX v3 part 6);
/// empty renders exactly as the plate always has.
class PedalPlate extends StatelessWidget {
  /// Creates a [PedalPlate].
  const PedalPlate({
    required this.frame,
    required this.onPress,
    required this.onTurn,
    required this.mode,
    required this.l10n,
    required this.mainScreen,
    required this.waveformScreen,
    required this.onClose,
    this.selected = const {},
    super.key,
  });

  /// LEDs, ring, bank — everything the plate renders from the wire frame.
  final PedalStateFrame frame;

  /// Fires on footswitch press and release, with the same signature the
  /// simulator transport dispatches today.
  final void Function(PedalButton button, {required bool down}) onPress;

  /// Fires on encoder rotation, `delta` detents per call.
  final void Function(int delta) onTurn;

  /// The live interaction mode — what the switches actually do. Distinct from
  /// `frame.mode`, which is what survived the wire's version downgrade.
  final InteractionMode mode;

  final AppLocalizations l10n;
  final Widget mainScreen;
  final Widget waveformScreen;

  /// Dismisses the plate (the top-right close button).
  final VoidCallback onClose;

  /// Buttons to render highlighted, for the pedal-assignment UI. Empty (the
  /// default) renders identically to a plate with no selection.
  final Set<PedalButton> selected;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final bankBase = frame.activeBank * _trackButtons.length;
    // Once the loop is cleared (activity off with nothing left to play) the
    // ring animates fully dark: the hump makes one last pass in the off color
    // and settles, instead of parking on a lit idle ring.
    final ringCleared =
        frame.globalColor == GlobalColor.off && frame.loopLengthMicros == 0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = math.min(
          constraints.maxWidth / _fpW,
          constraints.maxHeight / _fpV,
        );
        final plateW = _fpW * scale;
        final plateH = _fpV * scale;

        // Places [child] centred at faceplate (u, v), sized [wmm] x [hmm] mm.
        Positioned box(double u, double v, double wmm, double hmm, Widget c) {
          final w = wmm * scale;
          final h = hmm * scale;
          return Positioned(
            left: u * scale - w / 2,
            top: (_fpV - v) * scale - h / 2,
            width: w,
            height: h,
            child: c,
          );
        }

        Widget footswitch(
          PedalButton button,
          String label,
          double u,
          double v, {
          int? channel,
          Widget? statusLed,
        }) {
          final pedal = _Footswitch(
            button: button,
            label: label,
            onPress: onPress,
            l10n: l10n,
            mode: mode,
            led: channel == null ? null : frame.trackLeds[channel],
            channel: channel,
            selected: selected.contains(button),
          );
          if (statusLed == null) {
            return box(u, v, _slotW, _slotD, pedal);
          }

          // CLEAR/BANK: LED between pedal and silk (faceplate_holes layout).
          const aboveHmm = _ledD + _ledBehind;
          return box(
            u,
            v + aboveHmm / 2,
            _slotW,
            _slotD + aboveHmm,
            Column(
              children: [
                Expanded(
                  flex: _ledD.round(),
                  child: statusLed,
                ),
                Expanded(
                  flex: _ledBehind.round(),
                  child: const SizedBox.shrink(),
                ),
                Expanded(flex: _slotD.round(), child: pedal),
              ],
            ),
          );
        }

        // Silk legend line — bottom edge at faceplate v (segno_enclosure
        // layout).
        Widget silkLine(_SilkLine spec) => box(
          spec.align == TextAlign.center ? spec.u : spec.u + spec.blockW / 2,
          spec.v + _silkH / 2,
          spec.blockW,
          _silkH,
          _SilkLabel(text: spec.text, align: spec.align),
        );

        Iterable<Widget> silkLabels(String label, double u, double v) => [
          for (final spec in _silkLabelLines(label, u, v)) silkLine(spec),
        ];

        return Center(
          child: SizedBox(
            width: plateW,
            height: plateH,
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: surface.card,
                      borderRadius: BorderRadius.circular(
                        SurfaceTheme.radius17,
                      ),
                      border: Border.all(color: surface.line),
                    ),
                  ),
                ),
                // Rear screens.
                box(
                  _colU,
                  _screenTopV - _smallH / 2,
                  _smallW,
                  _smallH,
                  _ScreenBezel(child: waveformScreen),
                ),
                box(
                  _s16Uc,
                  _screenTopV - _bigH / 2,
                  _bigW,
                  _bigH,
                  _ScreenBezel(child: mainScreen),
                ),
                // Encoder + activity ring (between REC/PLAY and STOP).
                box(
                  _colU,
                  _row2V,
                  _ringOd,
                  _ringOd,
                  _Encoder(
                    ringColor: ringCleared
                        ? surface.ledOff
                        : _ringColor(surface, frame.globalColor),
                    loopLengthMicros: frame.loopLengthMicros,
                    cleared: ringCleared,
                    onTurn: onTurn,
                    l10n: l10n,
                  ),
                ),
                // CLEAR / BANK pair (upper centre).
                footswitch(
                  PedalButton.clear,
                  'CLEAR',
                  _pedalU(2),
                  _row2V,
                  statusLed: _Led(
                    ledKey: const Key('pedalFaceplate_led_clear'),
                    color: frame.clearFadeActive
                        ? surface.ledRed
                        : surface.ledOff,
                    glow: frame.globalColor != GlobalColor.off,
                  ),
                ),
                footswitch(
                  PedalButton.bank,
                  'BANK',
                  _pedalU(3),
                  _row2V,
                  statusLed: _Led(
                    ledKey: const Key('pedalFaceplate_led_bank'),
                    color: frame.activeBank == 1
                        ? surface.ledBlue
                        : surface.ledOff,
                    glow: frame.activeBank == 1,
                  ),
                ),
                ...silkLabels('CLEAR', _pedalU(2), _row2V),
                ...silkLabels('BANK', _pedalU(3), _row2V),
                // Front row: transport switches then the four track switches.
                footswitch(PedalButton.recPlay, 'REC/PLAY', _pedalU(0), _row1V),
                footswitch(PedalButton.stop, 'STOP', _pedalU(1), _row1V),
                footswitch(PedalButton.undo, 'UNDO', _pedalU(2), _row1V),
                footswitch(
                  PedalButton.mode,
                  'MODE',
                  _pedalU(3),
                  _row1V,
                  // The tri-state mode indicator (A1), mirroring the firmware
                  // verbatim: rec green, mute amber, FX blue — with the
                  // performance-armed blink keeping precedence, and the
                  // goodbye frame darkening it, exactly as both sketches
                  // render it (`goodbye ? Black : modeColor(...)`).
                  statusLed: frame.performanceArmed
                      ? _BlinkingLed(
                          ledKey: const Key('pedalFaceplate_led_mode'),
                          color: surface.ledRed,
                        )
                      : _Led(
                          ledKey: const Key('pedalFaceplate_led_mode'),
                          color: frame.isGoodbye
                              ? surface.ledOff
                              : _modeColor(surface, frame.mode),
                          glow: !frame.isGoodbye,
                        ),
                ),
                ...silkLabels('REC/PLAY', _pedalU(0), _row1V),
                ...silkLabels('STOP', _pedalU(1), _row1V),
                ...silkLabels('UNDO', _pedalU(2), _row1V),
                ...silkLabels('MODE', _pedalU(3), _row1V),
                for (var t = 0; t < _trackButtons.length; t++)
                  footswitch(
                    _trackButtons[t],
                    '${bankBase + t + 1}',
                    _pedalU(4 + t),
                    _row1V,
                    channel: bankBase + t,
                  ),
                // Status LEDs sit behind each track switch (and CLEAR/BANK), as
                // on the plate. The four track LEDs come from the frame; BANK
                // lights on bank B and CLEAR lights while there is activity to
                // clear.
                for (var t = 0; t < _trackButtons.length; t++)
                  box(
                    _pedalU(4 + t),
                    _row1V + _slotD / 2 + _ledBehind,
                    _ledD,
                    _ledD,
                    _Led(
                      ledKey: Key('pedalFaceplate_led_track${bankBase + t}'),
                      color: _ledColor(surface, frame.trackLeds[bankBase + t]),
                      glow: frame.trackLeds[bankBase + t] != PedalTrackLed.off,
                    ),
                  ),

                Align(
                  alignment: Alignment.topRight,
                  child: CloseButton(onPressed: onClose),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One silk legend line from segno_enclosure faceplate_holes / silk_text.
class _SilkLine {
  const _SilkLine({
    required this.text,
    required this.u,
    required this.v,
    required this.blockW,
    required this.align,
  });

  final String text;
  final double u; // centre u (centre align) or left edge (left align)
  final double v; // bottom edge in faceplate v coords
  final double blockW;
  final TextAlign align;
}

/// Mirrors segno_enclosure._silk_lines.
List<String> _silkLines(String label) {
  if (label == 'REC/PLAY') return const ['REC/', 'PLAY'];
  if (label.startsWith('TRACK')) return const [];
  return [label];
}

bool _silkHasLed(String label) =>
    label == 'CLEAR' || label == 'BANK' || label.startsWith('TRACK');

/// Mirrors segno_enclosure.faceplate_holes engraving layout.
List<_SilkLine> _silkLabelLines(String label, double pedalU, double pedalV) {
  final lines = _silkLines(label);
  if (lines.isEmpty) return const [];

  final vLbl =
      pedalV +
      _slotD / 2 +
      (_silkHasLed(label) ? _ledBehind + _silkLedExtra : _silkNoLedGap);

  final infos = <({String text, double dispW})>[];
  for (final ln in lines) {
    final estW = ln.length * _silkH * _silkCw;
    final dispW = math.min(estW, _slotW);
    infos.add((text: ln, dispW: dispW));
  }

  final maxDispW = infos.map((i) => i.dispW).reduce(math.max);
  final leftX = pedalU - maxDispW / 2;
  final multi = lines.length > 1;

  return [
    for (var k = 0; k < infos.length; k++)
      _SilkLine(
        text: infos[k].text,
        u: multi ? leftX : pedalU,
        v: vLbl + (lines.length - 1 - k) * _silkH * _silkLineSpacing,
        blockW: multi ? maxDispW : _slotW,
        align: multi ? TextAlign.left : TextAlign.center,
      ),
  ];
}

/// Bold sans legend at a fixed cap height; squish X only when wider than the
/// slot.
class _SilkLabel extends StatelessWidget {
  const _SilkLabel({
    required this.text,
    required this.align,
  });

  final String text;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return LayoutBuilder(
      builder: (context, constraints) {
        final capHeight = constraints.maxHeight;
        final maxWidth = constraints.maxWidth;
        return CustomPaint(
          size: Size(maxWidth, capHeight),
          painter: _SilkLabelPainter(
            text: text,
            align: align,
            color: surface.textSecondary,
            capHeight: capHeight,
            maxWidth: maxWidth,
          ),
        );
      },
    );
  }
}

/// Paints one silk line with optional horizontal squish, clipped to [maxWidth].
class _SilkLabelPainter extends CustomPainter {
  _SilkLabelPainter({
    required this.text,
    required this.align,
    required this.color,
    required this.capHeight,
    required this.maxWidth,
  });

  final String text;
  final TextAlign align;
  final Color color;
  final double capHeight;
  final double maxWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final style = TextStyle(
      color: color,
      fontFamily: SurfaceTheme.legendFont,
      fontFamilyFallback: SurfaceTheme.legendFontFallback,
      fontWeight: FontWeight.w700,
      fontSize: capHeight,
      height: 1,
    );
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final scaleX = painter.width > 0
        ? math.min(1, maxWidth / painter.width)
        : 1.0;
    final scaledW = painter.width * scaleX;
    final dx = switch (align) {
      TextAlign.center => (size.width - scaledW) / 2,
      _ => 0.0,
    };
    final dy = (size.height - painter.height) / 2;
    canvas
      ..save()
      ..clipRect(Offset.zero & size)
      ..translate(dx, dy)
      ..scale(scaleX.toDouble(), 1);
    painter.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SilkLabelPainter old) =>
      old.text != text ||
      old.align != align ||
      old.color != color ||
      old.capHeight != capHeight ||
      old.maxWidth != maxWidth;
}

/// A dark, bezelled screen aperture wrapping embedded content.
class _ScreenBezel extends StatelessWidget {
  const _ScreenBezel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(SurfaceTheme.radius10),
        border: Border.all(color: context.surface.line, width: 2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(SurfaceTheme.radius7),
        child: child,
      ),
    );
  }
}

/// A single footswitch. Pointer-down presses, pointer-up / cancel releases — so
/// a momentary tap and an UNDO long-press both work, and a held press that
/// wanders off the button still releases. Keyboard activation is a momentary
/// press. Fills the box the plate sizes it to.
class _Footswitch extends StatefulWidget {
  const _Footswitch({
    required this.button,
    required this.label,
    required this.onPress,
    required this.l10n,
    required this.mode,
    required this.selected,
    this.led,
    this.channel,
  });

  final PedalButton button;
  final String label;
  final void Function(PedalButton button, {required bool down}) onPress;
  final AppLocalizations l10n;

  /// The LIVE interaction mode — what this switch does, and how its LED
  /// reads, both depend on it. Deliberately not the frame's wire mode: below
  /// protocol v3 that decodes as mute even while FX mode is driving.
  final InteractionMode mode;

  /// Highlighted for the pedal-assignment UI (FX v3 part 6); `false` renders
  /// exactly as the plate always has.
  final bool selected;

  final PedalTrackLed? led;
  final int? channel;

  @override
  State<_Footswitch> createState() => _FootswitchState();
}

class _FootswitchState extends State<_Footswitch> {
  bool _down = false;

  void _press(bool down) {
    if (down == _down) return;
    setState(() => _down = down);
    widget.onPress(widget.button, down: down);
  }

  void _tap() {
    // Keyboard / screen-reader activation: a momentary press.
    widget.onPress(widget.button, down: true);
    widget.onPress(widget.button, down: false);
  }

  /// Keyboard / screen-reader activation of the LONG press — the gesture a
  /// fused tap can never produce, and the only way several switches reach
  /// their second action at all (undo's redo, MODE's record arm, Stop's
  /// FX-chain restore). Held past the cubit's threshold, then released.
  ///
  /// Goes through [_press] so the switch actually LOOKS held for the duration:
  /// on a control whose two halves differ only by how long it is down, a
  /// pressed state is the sole feedback that the hold registered. Ignored
  /// while already down, so overlapping activations cannot queue a second
  /// release that retires the newer press's long-press timer.
  void _holdActivate() {
    if (_down) return;
    _press(true);
    Future<void>.delayed(_keyboardHold, () {
      if (!mounted) return; // the plate's deactivate already released it
      _press(false);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.space ||
            event.logicalKey == LogicalKeyboardKey.enter)) {
      // Shift is the long-press modifier: a keyboard has no "hold" that
      // survives key repeat, so the gesture needs its own chord.
      if (HardwareKeyboard.instance.isShiftPressed) {
        _holdActivate();
      } else {
        _tap();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final label = switch (widget.channel) {
      final int channel => widget.l10n.pedalSimTrackSemantics(
        channel + 1,
        _ledStateLabel(
          widget.l10n,
          widget.led ?? PedalTrackLed.off,
          widget.mode,
        ),
      ),
      // Stop is the FX panic control in FX mode (a press bypasses every
      // chain, a hold restores them) — a plain "STOP footswitch" hides that.
      null
          when widget.button == PedalButton.stop &&
              widget.mode == InteractionMode.fx =>
        widget.l10n.pedalSimStopFxSemantics,
      null => widget.l10n.pedalSimFootswitchSemantics(widget.label),
    };
    return Semantics(
      button: true,
      label: label,
      selected: widget.selected,
      // Names the long-press chord where the user can actually meet it: the
      // shortcuts legend lives on TracksView, which this plate replaces
      // whenever the on-screen pedal is bound, so nothing else documents it.
      hint: widget.l10n.pedalSimHoldHint,
      onTap: _tap,
      // Screen-reader users get the long press as its own action; without it
      // the fused tap can only ever reach a switch's short gesture (in FX
      // mode: panic, with no way back to restore).
      onLongPress: _holdActivate,
      child: Focus(
        onKeyEvent: _onKey,
        child: Listener(
          onPointerDown: (event) {
            // Ignore the secondary (right) mouse button.
            if (event.buttons == kSecondaryButton) return;
            _press(true);
          },
          onPointerUp: (_) => _press(false),
          onPointerCancel: (_) => _press(false),
          child: Container(
            key: Key('pedalFaceplate_footswitch_${widget.button.name}'),
            decoration: BoxDecoration(
              color: _down ? surface.cardHigh : surface.surface,
              borderRadius: BorderRadius.circular(SurfaceTheme.radius10),
              border: Border.all(
                color: widget.selected ? surface.accent : surface.line,
                width: _down || widget.selected ? 2 : 1,
              ),
            ),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(6),
          ),
        ),
      ),
    );
  }
}

/// A status LED dot, filling the box the plate sizes it to. Lit dots glow.
class _Led extends StatelessWidget {
  const _Led({required this.ledKey, required this.color, required this.glow});

  final Key ledKey;
  final Color color;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ledKey,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: glow ? [BoxShadow(color: color, blurRadius: 6)] : null,
      ),
    );
  }
}

/// A [_Led] that toggles lit/dark on a fixed period — the performance-armed
/// indication (D-PEDAL): **blinking** [color], distinct eyes-free from any
/// solid-lit status LED (e.g. the looper's own solid record red).
class _BlinkingLed extends StatefulWidget {
  const _BlinkingLed({required this.ledKey, required this.color});

  final Key ledKey;
  final Color color;

  /// On/off half-period — distinguishable at a glance from a steady light
  /// without being distracting.
  static const _period = Duration(milliseconds: 400);

  @override
  State<_BlinkingLed> createState() => _BlinkingLedState();
}

class _BlinkingLedState extends State<_BlinkingLed> {
  Timer? _timer;
  bool _lit = true;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_BlinkingLed._period, (_) {
      setState(() => _lit = !_lit);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _Led(
      ledKey: widget.ledKey,
      color: _lit ? widget.color : Colors.transparent,
      glow: _lit,
    );
  }
}

/// The rotary encoder + its 12-LED activity ring. Drag or scroll turns it; the
/// ring's color is the global activity color, and a bright pixel sweeps around
/// the twelve LEDs once per loop (like the firmware advancing the ring on each
/// loop top).
class _Encoder extends StatefulWidget {
  const _Encoder({
    required this.ringColor,
    required this.loopLengthMicros,
    required this.cleared,
    required this.onTurn,
    required this.l10n,
  });

  final Color ringColor;
  final int loopLengthMicros;

  /// The loop was just cleared: the hump makes one last pass (at `_idleSweep`)
  /// in the off color, so the ring animates to dark instead of parking lit.
  final bool cleared;
  final void Function(int delta) onTurn;
  final AppLocalizations l10n;

  @override
  State<_Encoder> createState() => _EncoderState();
}

class _EncoderState extends State<_Encoder>
    with SingleTickerProviderStateMixin {
  static const double _dragPerDetent = 6;

  // Steady rotation used when there is no loop to time the sweep to (e.g. while
  // the ring winds off after a clear). Matches the firmware's kRingMsPerRev.
  static const Duration _idleSweep = Duration(milliseconds: 700);

  late final AnimationController _sweep;

  // Residual drag, so a slow drag still crosses detents instead of truncating
  // sub-detent deltas to zero.
  double _drag = 0;

  @override
  void initState() {
    super.initState();
    _sweep = AnimationController(vsync: this);
    _syncSweep();
  }

  @override
  void didUpdateWidget(_Encoder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loopLengthMicros != widget.loopLengthMicros ||
        oldWidget.cleared != widget.cleared) {
      _syncSweep();
    }
  }

  // One revolution per loop; on clear the hump makes one last idle-rate pass
  // and settles dark (a single forward pass, not a repeat, so it animates off
  // rather than parking a lit ring — and still settles for pumpAndSettle);
  // otherwise parked.
  void _syncSweep() {
    if (widget.loopLengthMicros > 0) {
      _sweep.duration = Duration(microseconds: widget.loopLengthMicros);
      if (!_sweep.isAnimating) unawaited(_sweep.repeat());
    } else if (widget.cleared) {
      _sweep.duration = _idleSweep;
      unawaited(_sweep.forward());
    } else {
      _sweep
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  void _onDrag(DragUpdateDetails details) {
    _drag += details.delta.dx - details.delta.dy;
    while (_drag >= _dragPerDetent) {
      widget.onTurn(1);
      _drag -= _dragPerDetent;
    }
    while (_drag <= -_dragPerDetent) {
      widget.onTurn(-1);
      _drag += _dragPerDetent;
    }
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      slider: true,
      label: widget.l10n.pedalSimEncoderSemantics,
      onIncrease: () => widget.onTurn(1),
      onDecrease: () => widget.onTurn(-1),
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
              event.logicalKey == LogicalKeyboardKey.arrowRight) {
            widget.onTurn(1);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
              event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            widget.onTurn(-1);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Listener(
          onPointerSignal: (signal) {
            if (signal is PointerScrollEvent) {
              widget.onTurn(signal.scrollDelta.dy > 0 ? -1 : 1);
            }
          },
          child: GestureDetector(
            onPanUpdate: _onDrag,
            onPanEnd: (_) => _drag = 0,
            child: Container(
              key: const Key('pedalFaceplate_encoder'),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: surface.surface,
                border: Border.all(color: widget.ringColor, width: 4),
                boxShadow: [BoxShadow(color: widget.ringColor, blurRadius: 8)],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: AnimatedBuilder(
                      animation: _sweep,
                      builder: (context, _) => CustomPaint(
                        key: const Key('pedalFaceplate_ring'),
                        painter: _LedRingPainter(
                          color: widget.ringColor,
                          progress:
                              widget.loopLengthMicros > 0 || widget.cleared
                              ? _sweep.value
                              : null,
                        ),
                      ),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: 0.42,
                    heightFactor: 0.42,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: surface.cardHigh,
                        border: Border.all(color: surface.line),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the encoder's 12-LED activity ring (the 12× WS2812 ring board on the
/// hardware). Every LED idles at a dim glow in the activity [color]; while a
/// loop runs the pixel nearest [progress] (`0..1`, clockwise from the top)
/// burns bright and its neighbours fade off either side, so a highlight sweeps
/// once per loop. [progress] is `null` when parked — then all twelve just idle.
class _LedRingPainter extends CustomPainter {
  _LedRingPainter({required this.color, required this.progress});

  final Color color;
  final double? progress;

  static const _count = 12;
  static const _baseGlow = 0.30; // idle LED alpha

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final dotR = size.shortestSide * 0.05;
    final ringR = size.shortestSide / 2 - dotR - 6;
    // Playhead position in LED units (0..12); negative parks the sweep.
    final head = progress == null ? -1.0 : progress! * _count;

    for (var i = 0; i < _count; i++) {
      final angle = -math.pi / 2 + i / _count * 2 * math.pi;
      final at = centre + Offset(math.cos(angle), math.sin(angle)) * ringR;

      // Wrapping distance from the playhead, so the bright pixel and its glow
      // fall off symmetrically and wrap cleanly at the top of the ring.
      var d = (i - head).abs();
      if (d > _count / 2) d = _count - d;
      final lit = head < 0 ? 0.0 : (1 - d / 2).clamp(0.0, 1.0);

      if (lit > 0.5) {
        canvas.drawCircle(
          at,
          dotR * 2.2,
          Paint()
            ..color = color.withValues(alpha: 0.35 * lit)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
        );
      }
      final alpha = _baseGlow + (1 - _baseGlow) * lit;
      canvas.drawCircle(
        at,
        dotR,
        Paint()..color = color.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_LedRingPainter old) =>
      old.progress != progress || old.color != color;
}

/// How long a keyboard / screen-reader long-press holds a switch down.
///
/// Comfortably past `ControlCubit`'s 500 ms default threshold (and past a
/// user-raised one within reason) — the cubit owns the real timing, this only
/// has to outlast it.
const _keyboardHold = Duration(milliseconds: 700);

const _trackButtons = <PedalButton>[
  PedalButton.track1,
  PedalButton.track2,
  PedalButton.track3,
  PedalButton.track4,
];

Color _ledColor(SurfaceTheme surface, PedalTrackLed led) => switch (led) {
  PedalTrackLed.off => surface.ledOff,
  PedalTrackLed.green => surface.ledGreen,
  PedalTrackLed.red => surface.ledRed,
  // FX-mode chain-enabled (protocol v3, part 5a) — rendered like the
  // firmware's verbatim blue; the FX-mode projection that emits it is 5b's.
  PedalTrackLed.blue => surface.ledBlue,
};

/// The tri-state MODE indicator's color (A1), one per interaction mode —
/// the on-screen twin of the firmware's `modeColor`, whose amber comes from
/// the same place the ring's does.
Color _modeColor(SurfaceTheme surface, PedalMode mode) => switch (mode) {
  PedalMode.rec => surface.ledGreen,
  PedalMode.play => surface.ledAmber,
  PedalMode.fx => surface.ledBlue,
};

Color _ringColor(SurfaceTheme surface, GlobalColor color) => switch (color) {
  GlobalColor.off => surface.ringGlow,
  GlobalColor.green => surface.ledGreen,
  GlobalColor.red => surface.ledRed,
  GlobalColor.amber => surface.ledAmber,
  GlobalColor.blue => surface.ledBlue,
};

/// The screen-reader reading of a track LED, PER ACTIVE MODE — the same byte
/// means different things in each, so a mode-blind label would lie.
///
/// Keyed on the LIVE [InteractionMode], never on the frame's wire mode: below
/// protocol v3 the codec degrades fx to play AND blue to green in lockstep,
/// so a wire-keyed label would read an engaged chain as "armed" on exactly
/// the pedals that need the reading most. FX mode therefore treats ANY lit
/// LED as chain-enabled, which covers the downgraded green too.
String _ledStateLabel(
  AppLocalizations l10n,
  PedalTrackLed led,
  InteractionMode mode,
) => switch (mode) {
  InteractionMode.fx =>
    led == PedalTrackLed.off
        ? l10n.pedalSimLedChainDisabled
        : l10n.pedalSimLedChainEnabled,
  InteractionMode.record || InteractionMode.mute => switch (led) {
    PedalTrackLed.off => l10n.pedalSimLedOff,
    PedalTrackLed.green => l10n.pedalSimLedArmed,
    PedalTrackLed.red => l10n.pedalSimLedRecording,
    PedalTrackLed.blue => l10n.pedalSimLedChainEnabled,
  },
};
