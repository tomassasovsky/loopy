// The MIDI overrides intentionally mirror the generated C symbol names.
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:loopy_engine/loopy_engine_ffi.dart';
import 'package:midi_client/midi_client.dart';

/// A hardware-free stand-in for [LoopyEngineBindings] covering just the
/// `le_midi_*` surface that [MidiClient] uses.
///
/// Implements the full generated interface via [noSuchMethod] (the audio
/// methods are never called from MIDI code) and overrides only the five MIDI
/// entry points. Records call order in [calls] so dispose-ordering is testable.
class FakeLoopyEngineBindings implements LoopyEngineBindings {
  FakeLoopyEngineBindings({
    List<MidiDevice> devices = const [],
    this.createReturnsNull = false,
    this.openResult = 0,
  }) : devices = List.of(devices);

  /// The devices [le_midi_enumerate] reports.
  List<MidiDevice> devices;

  /// When `true`, [le_midi_create] returns `nullptr` (allocation failure).
  bool createReturnsNull;

  /// The result code [le_midi_open] returns.
  int openResult;

  /// Ordered log of MIDI calls, e.g. `create`, `open`, `close`, `destroy`.
  final List<String> calls = [];

  /// The id passed to the most recent [le_midi_open].
  String? lastOpenedId;

  /// The callback pointer passed to the most recent [le_midi_open].
  le_midi_event_cb? lastOpenedCb;

  /// The sentinel handle from [le_midi_create] (non-null when allocated).
  static final Pointer<le_midi> _handle = Pointer<le_midi>.fromAddress(0x4D);

  @override
  Pointer<le_midi> le_midi_create() {
    calls.add('create');
    return createReturnsNull ? nullptr : _handle;
  }

  @override
  void le_midi_destroy(Pointer<le_midi> m) {
    calls.add('destroy');
  }

  @override
  int le_midi_enumerate(
    Pointer<le_midi_info> out,
    int max,
    Pointer<Int32> count,
  ) {
    calls.add('enumerate');
    final n = devices.length < max ? devices.length : max;
    for (var i = 0; i < n; i++) {
      final device = devices[i];
      writeNativeString((out + i).ref.id, device.id);
      writeNativeString((out + i).ref.name, device.name);
      (out + i).ref.is_default = device.isDefault ? 1 : 0;
    }
    count.value = n;
    return 0;
  }

  @override
  int le_midi_open(Pointer<le_midi> m, Pointer<Char> id, le_midi_event_cb cb) {
    calls.add('open');
    lastOpenedId = id.cast<Utf8>().toDartString();
    lastOpenedCb = cb;
    return openResult;
  }

  @override
  int le_midi_close(Pointer<le_midi> m) {
    calls.add('close');
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
