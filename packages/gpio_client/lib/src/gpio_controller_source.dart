import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:gpio_client/src/gpio_bindings.dart';
import 'package:gpio_client/src/lib_gpiod_bindings.dart';
import 'package:meta/meta.dart';

/// A [ControllerSource] backed by Raspberry Pi GPIO footswitch pins.
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
/// the pipeline expects.
class GpioControllerSource implements ControllerSource {
  /// Creates a [GpioControllerSource] requesting the footswitch [lines] (BCM
  /// pin offsets) over [bindings] (defaults to a real [LibGpiodBindings] on the
  /// platform libgpiod).
  ///
  /// [debounce] is the minimum gap between two emitted inputs for the *same*
  /// pin; sub-[debounce] repeats collapse to one event on [inputs] (they still
  /// blink [activity]). Defaults to 20 ms — long enough to swallow mechanical
  /// bounce, short enough to preserve fast intentional taps.
  GpioControllerSource({
    required List<int> lines,
    GpioBindings? bindings,
    this.debounce = const Duration(milliseconds: 20),
  }) : _bindings = bindings ?? LibGpiodBindings() {
    _bindings.open(lines, _onEdge);
  }

  final GpioBindings _bindings;

  /// The minimum gap between emitted inputs for the same pin.
  final Duration debounce;

  final StreamController<RawControllerInput> _inputs =
      StreamController<RawControllerInput>.broadcast();
  final StreamController<RawControllerInput> _activity =
      StreamController<RawControllerInput>.broadcast();

  /// The timestamp (µs) of the last input *emitted* for each pin. Leading-edge
  /// debounce: only emitted edges advance the window, so a continuous bounce
  /// can't keep resetting it.
  final Map<int, int> _lastEmitUs = {};

  bool _disposed = false;

  @override
  Stream<RawControllerInput> get inputs => _inputs.stream;

  /// Every pin edge, pre-debounce and pre-mapping, for a UI activity indicator.
  ///
  /// Mirrors `MidiControllerSource.activity`; kept on parity for the planned
  /// console footswitch-activity indicator (a later Part), so it has no
  /// consumer yet — do not remove as dead code.
  Stream<RawControllerInput> get activity => _activity.stream;

  /// Debounce window in microseconds, derived from [debounce].
  int get _debounceUs => debounce.inMicroseconds;

  /// Handles one raw pin edge from [GpioBindings] (or [pushForTest]).
  void _onEdge(int line, int level, int tsUs) {
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
  }
}
