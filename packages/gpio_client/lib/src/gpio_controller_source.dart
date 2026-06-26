import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:gpio_client/src/gpio_bindings.dart';
import 'package:gpio_client/src/gpio_encoder_config.dart';
import 'package:gpio_client/src/lib_gpiod_bindings.dart';
import 'package:meta/meta.dart';

/// A [ControllerSource] backed by Raspberry Pi GPIO footswitch pins (and,
/// optionally, a rotary [encoder]).
///
/// Mirrors `MidiControllerSource`: it owns a persistent broadcast [inputs]
/// stream and normalizes raw pin edges (from [GpioBindings]) into
/// [RawControllerInput]s after a leading-edge per-trigger [debounce], so a
/// bouncing stomped footswitch can't double-toggle a record.
///
/// **Active-low.** The lines are requested with a pull-up bias, so an idle
/// switch reads high (`1`) and a press shorts it to ground (`0`). This source
/// inverts that: a falling edge (level `0`) becomes a press (value `1`) and a
/// rising edge a release (value `0`), matching the value convention the rest of
/// the pipeline expects. The encoder push-switch is just another press line.
///
/// **Encoder rotation (reserved).** When an [encoder] is given, its A/B pins are
/// quadrature-decoded into relative detents on [rotation]. Rotation is decoded
/// but **not** routed through the mapping in v1 (the press-only pipeline and
/// the touchscreen cover configuration); [rotation] has no consumer yet — see
/// the option-B follow-up in the umbrella plan.
class GpioControllerSource implements ControllerSource {
  /// Creates a [GpioControllerSource] requesting the footswitch [lines] (BCM
  /// pin offsets, including any encoder push-switch) over [bindings] (defaults
  /// to a real [LibGpiodBindings] on the platform libgpiod). When [encoder] is
  /// given its A/B pins are requested too and decoded into [rotation].
  ///
  /// [debounce] is the minimum gap between two emitted inputs for the *same*
  /// pin; sub-[debounce] repeats collapse to one event on [inputs] (they still
  /// blink [activity]). Defaults to 20 ms — long enough to swallow mechanical
  /// bounce, short enough to preserve fast intentional taps.
  ///
  /// [sanityFloor] is the minimum quiet gap a pin must show *before* an edge is
  /// accepted: an edge within [sanityFloor] of the previous edge on that pin
  /// (accepted or not) is dropped as electrical noise (a GPIO miswire or ESD
  /// transient) before any decode or debounce. A continuously chattering pin
  /// therefore never settles and collapses to a single edge, so it can't fire
  /// phantom transport actions or corrupt the quadrature decode. Defaults to
  /// 1 ms — orders of magnitude faster than a human stomp or turn.
  GpioControllerSource({
    required List<int> lines,
    GpioBindings? bindings,
    this.encoder,
    this.debounce = const Duration(milliseconds: 20),
    this.sanityFloor = const Duration(milliseconds: 1),
  }) : _bindings = bindings ?? LibGpiodBindings() {
    _bindings.open([...lines, ...?encoder?.lines], _onEdge);
  }

  final GpioBindings _bindings;

  /// The optional rotary encoder whose A/B pins are quadrature-decoded.
  final GpioEncoderConfig? encoder;

  /// The minimum gap between emitted inputs for the same pin.
  final Duration debounce;

  /// The minimum plausible gap between any two edges on the same pin; faster
  /// edges are rejected as noise.
  final Duration sanityFloor;

  final StreamController<RawControllerInput> _inputs =
      StreamController<RawControllerInput>.broadcast();
  final StreamController<RawControllerInput> _activity =
      StreamController<RawControllerInput>.broadcast();
  final StreamController<int> _rotation = StreamController<int>.broadcast();

  /// The timestamp (µs) of the last input *emitted* for each pin. Leading-edge
  /// debounce: only emitted edges advance the window, so a continuous bounce
  /// can't keep resetting it.
  final Map<int, int> _lastEmitUs = {};

  /// The timestamp (µs) of the last *accepted* raw edge for each pin, for the
  /// sanity gate.
  final Map<int, int> _lastEdgeUs = {};

  /// The current quadrature state `(A << 1) | B`; starts idle (both high).
  int _quadState = 0x3;

  /// Accumulated quadrature sub-steps; ±4 is one detent.
  int _quadAccum = 0;

  bool _disposed = false;

  @override
  Stream<RawControllerInput> get inputs => _inputs.stream;

  /// Every press-line edge, pre-debounce and pre-mapping, for a UI activity
  /// indicator.
  ///
  /// Mirrors `MidiControllerSource.activity`; kept on parity for the planned
  /// console footswitch-activity indicator (a later Part), so it has no
  /// consumer yet — do not remove as dead code. Encoder rotation edges do not
  /// blink it (they are not presses).
  Stream<RawControllerInput> get activity => _activity.stream;

  /// Relative encoder detents: `+1` per clockwise notch, `-1` per
  /// counter-clockwise. Decoded but reserved in v1 (no consumer) — see the
  /// class doc.
  Stream<int> get rotation => _rotation.stream;

  /// Debounce window in microseconds, derived from [debounce] (computed once).
  late final int _debounceUs = debounce.inMicroseconds;

  /// Sanity floor in microseconds, derived from [sanityFloor] (computed once).
  late final int _sanityFloorUs = sanityFloor.inMicroseconds;

  /// Quadrature transition table, indexed by `(prev << 2) | next` over the
  /// 2-bit `(A, B)` state. Valid single steps are ±1; invalid (skipped/bounced)
  /// transitions are 0. Four steps make one detent.
  static const List<int> _quadTable = [
    0, -1, 1, 0, //
    1, 0, 0, -1, //
    -1, 0, 0, 1, //
    0, 1, -1, 0, //
  ];

  /// Handles one raw pin edge from [GpioBindings] (or [pushForTest]).
  void _onEdge(int line, int level, int tsUs) {
    // Sanity gate: an edge is accepted only after the pin has been quiet for at
    // least the floor; one within the floor of the previous edge (accepted or
    // not) is dropped as noise (miswire / ESD), before any decode or debounce.
    // Recording every edge's time means a continuously chattering pin never
    // settles, collapsing the whole storm to its first edge. The first edge on
    // a pin always passes (no prior edge to compare against).
    final lastEdge = _lastEdgeUs[line];
    _lastEdgeUs[line] = tsUs;
    if (lastEdge != null && tsUs - lastEdge < _sanityFloorUs) return;

    final encoder = this.encoder;
    if (encoder != null && (line == encoder.pinA || line == encoder.pinB)) {
      _decodeRotation(encoder, line, level);
      return;
    }

    // Active-low: a low level (switch to ground) is a press.
    final input = RawControllerInput(
      kind: ControllerSourceKind.gpio,
      id: line,
      value: level == 0 ? 1 : 0,
    );

    // Activity is the raw pre-mapping edge: every edge blinks it, even
    // debounced duplicates, so the indicator reflects true footswitch traffic.
    if (!_activity.isClosed) _activity.add(input);

    // Leading-edge same-pin debounce on the inputs (action) stream.
    final last = _lastEmitUs[line];
    if (last != null && tsUs - last < _debounceUs) return;
    _lastEmitUs[line] = tsUs;

    if (!_inputs.isClosed) _inputs.add(input);
  }

  /// Folds one A/B edge into the quadrature state and emits a [rotation] detent
  /// when four valid sub-steps accumulate in one direction.
  void _decodeRotation(GpioEncoderConfig encoder, int line, int level) {
    final next = line == encoder.pinA
        ? (level == 0 ? _quadState & 0x1 : _quadState | 0x2)
        : (level == 0 ? _quadState & 0x2 : _quadState | 0x1);
    _quadAccum += _quadTable[(_quadState << 2) | next];
    _quadState = next;

    // One edge adds at most ±1 sub-step, so each loop runs at most once per
    // call; the residual `_quadAccum` always stays within (-4, 4).
    while (_quadAccum >= 4) {
      _quadAccum -= 4;
      if (!_rotation.isClosed) _rotation.add(1);
    }
    while (_quadAccum <= -4) {
      _quadAccum += 4;
      if (!_rotation.isClosed) _rotation.add(-1);
    }
  }

  /// Drives the event path as if a native edge arrived, without hardware.
  ///
  /// [level] is the electrical line level after the edge (`0` low / `1` high).
  @visibleForTesting
  void pushForTest(int line, int level, {int tsUs = 0}) =>
      _onEdge(line, level, tsUs);

  /// Whether [dispose] has been called.
  @visibleForTesting
  bool get isDisposed => _disposed;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Stop edge delivery and free the native request before closing the streams
    // so a late edge can never add to a closed sink.
    _bindings
      ..close()
      ..dispose();
    await _inputs.close();
    await _activity.close();
    await _rotation.close();
  }
}
