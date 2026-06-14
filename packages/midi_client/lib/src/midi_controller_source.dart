import 'dart:async';
import 'dart:ffi';

import 'package:controller_repository/controller_repository.dart';
import 'package:loopy_engine/loopy_engine_ffi.dart';
import 'package:meta/meta.dart';
import 'package:midi_client/src/midi_client_base.dart';
import 'package:midi_client/src/midi_device.dart';

/// A [ControllerSource] backed by a native USB MIDI input device.
///
/// Long-lived by design: [inputs] is a persistent broadcast stream that
/// survives device open/close/switch, so `ControllerRepository`'s single
/// subscription is never torn down on replug (the structural prerequisite from
/// the plan). The physical device is swapped *inside* the source via [open] /
/// [close].
///
/// Raw `(status, data1, data2)` bytes from the native callback are normalized
/// to [RawControllerInput]s (`midiCc` / `midiNote`) and pushed to [inputs]
/// after a small same-trigger [debounce] (so a bouncing footswitch can't
/// double-toggle a record). Every recognized message — pre-debounce,
/// pre-mapping — is mirrored on [activity] for a UI input indicator.
class MidiControllerSource implements ControllerSource {
  /// Creates a [MidiControllerSource] over [client] (defaults to a real
  /// [MidiClient] on the platform library).
  ///
  /// [debounce] is the minimum gap between two emitted inputs for the *same*
  /// trigger; sub-[debounce] repeats collapse to one event on [inputs] (they
  /// still blink [activity]). Defaults to 30 ms.
  MidiControllerSource({
    MidiClient? client,
    this.debounce = const Duration(milliseconds: 30),
  }) : _client = client ?? MidiClient() {
    _callable = NativeCallable<le_midi_event_cbFunction>.listener(_onMidiEvent);
  }

  final MidiClient _client;

  /// The minimum gap between emitted inputs for the same trigger.
  final Duration debounce;

  late final NativeCallable<le_midi_event_cbFunction> _callable;

  final StreamController<RawControllerInput> _inputs =
      StreamController<RawControllerInput>.broadcast();
  final StreamController<RawControllerInput> _activity =
      StreamController<RawControllerInput>.broadcast();

  /// The capture timestamp (µs) of the last input *emitted* for each trigger,
  /// keyed by `kind#id`. Leading-edge debounce: only emitted messages advance
  /// the window, so a continuous bounce can't keep resetting it.
  final Map<int, int> _lastEmitUs = {};

  bool _disposed = false;

  @override
  Stream<RawControllerInput> get inputs => _inputs.stream;

  /// Every recognized Note/CC message, pre-debounce and pre-mapping, for a UI
  /// activity indicator. Unrecognized traffic (SysEx, clock, active-sensing,
  /// aftertouch, pitch bend, program change) never reaches here.
  Stream<RawControllerInput> get activity => _activity.stream;

  /// Lists the host's available MIDI input devices.
  List<MidiDevice> enumerate() => _client.enumerate();

  /// Opens (or switches to) the device with the given [id], routing its
  /// messages into [inputs] / [activity]. Returns the native result code
  /// (`0` on success).
  int open(String id) => _client.open(id, _callable.nativeFunction);

  /// Closes the currently open device. Idempotent; [inputs] stays open.
  int close() => _client.close();

  /// Debounce window in microseconds, derived from [debounce].
  int get _debounceUs => debounce.inMicroseconds;

  /// Handles one raw MIDI message from the native callback (or [pushForTest]).
  void _onMidiEvent(int status, int data1, int data2, int tsUs) {
    final input = _parse(status, data1, data2);
    if (input == null) return;

    // Activity is the raw pre-mapping tap: every recognized message blinks it,
    // even debounced duplicates, so the indicator reflects true device traffic.
    if (!_activity.isClosed) _activity.add(input);

    // Leading-edge same-trigger debounce on the inputs (action) stream.
    final key = _triggerKey(input);
    final last = _lastEmitUs[key];
    if (last != null && tsUs - last < _debounceUs) return;
    _lastEmitUs[key] = tsUs;

    if (!_inputs.isClosed) _inputs.add(input);
  }

  /// Maps a MIDI status/data triple to a [RawControllerInput], or `null` when
  /// the message is not a Note On/Off or Control Change.
  ///
  /// Channel (the status low nibble) is ignored — triggers are
  /// channel-agnostic. A Note On with velocity 0 is the conventional Note Off,
  /// so it maps to value 0 (a release, which the mapping treats as non-press).
  static RawControllerInput? _parse(int status, int data1, int data2) {
    switch (status & 0xF0) {
      case 0x90: // Note On (velocity 0 == Note Off)
        return RawControllerInput(
          kind: ControllerSourceKind.midiNote,
          id: data1,
          value: data2,
        );
      case 0x80: // Note Off
        return RawControllerInput(
          kind: ControllerSourceKind.midiNote,
          id: data1,
          value: 0,
        );
      case 0xB0: // Control Change
        return RawControllerInput(
          kind: ControllerSourceKind.midiCc,
          id: data1,
          value: data2,
        );
      default: // SysEx / real-time / aftertouch / pitch bend / program change
        return null;
    }
  }

  /// A compact integer key for a trigger (kind + id), for the debounce map.
  static int _triggerKey(RawControllerInput input) =>
      input.kind.index << 16 | input.id;

  /// Drives the event path as if a native message arrived, without hardware.
  @visibleForTesting
  void pushForTest(int status, int data1, int data2, {int tsUs = 0}) =>
      _onMidiEvent(status, data1, data2, tsUs);

  /// Whether [dispose] has been called.
  @visibleForTesting
  bool get isDisposed => _disposed;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Order matters (use-after-free safety): stop native capture and free the
    // handle *before* releasing the NativeCallable, so the native side can
    // never invoke a freed callback.
    // le_midi_close -> le_midi_destroy -> callable.close.
    _client
      ..close()
      ..dispose();
    _callable.close();
    await _inputs.close();
    await _activity.close();
  }
}
