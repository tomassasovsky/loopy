import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:midi_client/midi_client.dart' show MidiDevice;
import 'package:pedal_repository/src/pedal_button.dart';
import 'package:pedal_repository/src/pedal_codec.dart';
import 'package:pedal_repository/src/pedal_state_frame.dart';
import 'package:pedal_repository/src/pedal_transport.dart';

/// The reserved output-device id for the on-screen pedal simulator.
///
/// The simulator advertises itself as a normal MIDI output so it binds through
/// the same picker + `bind` flow as real hardware; this id is how the wiring
/// and the faceplate recognize it. A real device is never allowed to use it.
const kSimulatorOutputId = 'loopy-sim';

/// A [PedalTransport] that adds an **on-screen pedal** on top of an inner
/// transport (the native one, or a `NoopPedalTransport` when there is no MIDI
/// backend), so the pedal can be driven and observed entirely in software.
///
/// It is a loopback seam: [press] / [turn] inject raw MIDI onto the same [input]
/// the repository decodes (so the *real* `PedalCubit` behavior runs — undo
/// tap/hold, the Rec/Play cycle, Play-mode mute/arm), and when the simulator is
/// the bound output the outbound [send] frames are decoded and published on
/// [frame] for the faceplate to render. When a real device is bound instead,
/// every call delegates to the inner transport, so the simulator never
/// interferes.
class SimulatorPedalTransport implements PedalTransport {
  /// Creates a [SimulatorPedalTransport] decorating [inner].
  SimulatorPedalTransport({
    required PedalTransport inner,
    String deviceName = 'On-screen pedal',
  }) : _inner = inner,
       _device = MidiDevice(id: kSimulatorOutputId, name: deviceName) {
    // Merge the inner transport's inbound stream with the injected one, so a
    // real footswitch and an on-screen press both reach the repository.
    _innerSub = _inner.input.listen(_input.add, onError: _input.addError);
  }

  final PedalTransport _inner;
  final MidiDevice _device;

  final StreamController<PedalRawMessage> _input =
      StreamController<PedalRawMessage>.broadcast();
  late final StreamSubscription<PedalRawMessage> _innerSub;

  final ValueNotifier<PedalStateFrame> _frame = ValueNotifier(
    PedalStateFrame.blank(),
  );

  // Buttons currently held down on-screen, so [releaseAll] can send their
  // NoteOff and never leave a note (or the cubit's undo timer) stuck.
  final Set<PedalButton> _held = {};

  bool _boundToSim = false;
  bool _disposed = false;

  /// The latest decoded state frame while the simulator is the bound output —
  /// what the faceplate renders. Seeded with [PedalStateFrame.blank] so the
  /// faceplate has a value synchronously on mount, before the first push.
  ValueListenable<PedalStateFrame> get frame => _frame;

  /// Presses ([down] true) or releases ([down] false) [button], as if a
  /// footswitch fired. NoteOn on press, NoteOff on release.
  void press(PedalButton button, {required bool down}) {
    if (_disposed) return;
    if (down) {
      _held.add(button);
    } else {
      _held.remove(button);
    }
    _input.add((
      status: down ? 0x90 : 0x80,
      data1: button.note,
      data2: down ? 100 : 0,
    ));
  }

  /// Turns the encoder by [delta] detents (positive = clockwise). The value is
  /// clamped to the wire range (-64..+63); a drag can't exceed that.
  void turn(int delta) {
    if (_disposed) return;
    _input.add((
      status: 0xB0,
      data1: PedalCodec.encoderCc,
      data2: PedalCodec.encodeEncoder(delta),
    ));
  }

  /// Releases every currently-held button (NoteOff). Called on faceplate
  /// deactivate / focus loss so a held press can't stick.
  void releaseAll() {
    if (_disposed) return;
    final held = _held.toList();
    _held.clear();
    for (final button in held) {
      _input.add((status: 0x80, data1: button.note, data2: 0));
    }
  }

  @override
  Stream<PedalRawMessage> get input => _input.stream;

  @override
  List<MidiDevice> enumerateOutputs() => [
    // Drop any real device masquerading as the reserved id, then always append
    // the simulator — so the hotplug poll can never make it vanish and unbind.
    for (final device in _inner.enumerateOutputs())
      if (device.id != kSimulatorOutputId) device,
    _device,
  ];

  @override
  int openOutput(String id) {
    if (id == kSimulatorOutputId) {
      _inner.closeOutput(); // release any real port; frames now render onscreen
      _boundToSim = true;
      return 0;
    }
    _boundToSim = false;
    return _inner.openOutput(id);
  }

  @override
  int closeOutput() {
    if (_boundToSim) {
      _boundToSim = false;
      return 0;
    }
    return _inner.closeOutput();
  }

  @override
  int send(Uint8List bytes) {
    if (!_boundToSim) return _inner.send(bytes);
    // The loop-top pulse (single 0xFA) and the identity request decode to null;
    // only state frames update the faceplate.
    final frame = PedalCodec.decodeFrame(bytes);
    if (frame != null) _frame.value = frame;
    return 0;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _innerSub.cancel();
    await _input.close();
    _frame.dispose();
    await _inner.dispose();
  }
}
