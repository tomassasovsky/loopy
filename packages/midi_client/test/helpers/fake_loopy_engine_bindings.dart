// The MIDI overrides intentionally mirror the generated C symbol names.
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';
import 'dart:typed_data';

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
    List<MidiDevice> outDevices = const [],
    this.outCreateReturnsNull = false,
    this.outOpenResult = 0,
    this.sendResult = 0,
  }) : devices = List.of(devices),
       outDevices = List.of(outDevices);

  /// The devices [le_midi_enumerate] reports.
  List<MidiDevice> devices;

  /// When `true`, [le_midi_create] returns `nullptr` (allocation failure).
  bool createReturnsNull;

  /// The result code [le_midi_open] returns.
  int openResult;

  /// The devices [le_midi_out_enumerate] reports.
  List<MidiDevice> outDevices;

  /// When `true`, [le_midi_out_create] returns `nullptr` (alloc failure).
  bool outCreateReturnsNull;

  /// The result code [le_midi_out_open] returns.
  int outOpenResult;

  /// The result code [le_midi_out_send] returns.
  int sendResult;

  /// The id passed to the most recent [le_midi_out_open].
  String? lastOutOpenedId;

  /// Every payload passed to [le_midi_out_send], in order.
  final List<Uint8List> sent = [];

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

  /// The sentinel handle from [le_midi_out_create].
  static final Pointer<le_midi_out> _outHandle =
      Pointer<le_midi_out>.fromAddress(0x4F);

  @override
  Pointer<le_midi_out> le_midi_out_create() {
    calls.add('out_create');
    return outCreateReturnsNull ? nullptr : _outHandle;
  }

  @override
  void le_midi_out_destroy(Pointer<le_midi_out> m) {
    calls.add('out_destroy');
  }

  @override
  int le_midi_out_enumerate(
    Pointer<le_midi_info> out,
    int max,
    Pointer<Int32> count,
  ) {
    calls.add('out_enumerate');
    final n = outDevices.length < max ? outDevices.length : max;
    for (var i = 0; i < n; i++) {
      final device = outDevices[i];
      writeNativeString((out + i).ref.id, device.id);
      writeNativeString((out + i).ref.name, device.name);
      (out + i).ref.is_default = device.isDefault ? 1 : 0;
    }
    count.value = n;
    return 0;
  }

  @override
  int le_midi_out_open(Pointer<le_midi_out> m, Pointer<Char> id) {
    calls.add('out_open');
    lastOutOpenedId = id.cast<Utf8>().toDartString();
    return outOpenResult;
  }

  @override
  int le_midi_out_close(Pointer<le_midi_out> m) {
    calls.add('out_close');
    return 0;
  }

  @override
  int le_midi_out_send(Pointer<le_midi_out> m, Pointer<Uint8> data, int len) {
    calls.add('out_send');
    sent.add(Uint8List.fromList(data.asTypedList(len)));
    return sendResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
