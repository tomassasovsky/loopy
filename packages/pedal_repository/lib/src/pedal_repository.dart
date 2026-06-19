import 'dart:async';

import 'package:pedal_repository/src/models/pedal_output.dart';
import 'package:pedal_repository/src/pedal_codec.dart';
import 'package:pedal_repository/src/pedal_event.dart';
import 'package:pedal_repository/src/pedal_state_frame.dart';
import 'package:pedal_repository/src/pedal_transport.dart';

/// The binding state of the pedal output link.
///
/// Binding is driven by the output port opening — loopy's 3-byte input capture
/// cannot deliver the pedal's SysEx identity *reply*, so there is no
/// reply-based auto-detect or inbound version negotiation in v1 (both are
/// deferred until the input seam grows a SysEx-capable path).
enum PedalBindStatus {
  /// No output destination is bound.
  none,

  /// An output destination is being opened.
  connecting,

  /// An output destination is open; state frames are being streamed.
  bound,

  /// The last bind attempt failed (the port could not be opened).
  error,
}

/// Owns the pedal protocol over a [PedalTransport]: decodes inbound button /
/// encoder messages into [PedalEvent]s and pushes outbound [PedalStateFrame]s,
/// the loop-top pulse, and the identity request.
///
/// Hardware-free and FFI-free — all native work is behind the injected
/// [PedalTransport] (`NativePedalTransport` in production, a fake in tests).
class PedalRepository {
  /// Creates a [PedalRepository] over [transport].
  ///
  /// [clock] stamps inbound button events for the cubit's tap / long-press /
  /// double-tap timing; it defaults to a monotonic stopwatch started now.
  PedalRepository(PedalTransport transport, {Duration Function()? clock})
    : _transport = transport {
    final stopwatch = Stopwatch()..start();
    _clock = clock ?? (() => stopwatch.elapsed);
    _inputSub = _transport.input.listen(_onRaw);
  }

  final PedalTransport _transport;
  late final Duration Function() _clock;
  late final StreamSubscription<PedalRawMessage> _inputSub;

  final StreamController<PedalEvent> _events =
      StreamController<PedalEvent>.broadcast();
  final StreamController<PedalBindStatus> _statusChanges =
      StreamController<PedalBindStatus>.broadcast();

  PedalBindStatus _status = PedalBindStatus.none;
  String? _boundOutputId;
  bool _disposed = false;

  /// Decoded pedal inputs (button presses/releases, encoder deltas).
  Stream<PedalEvent> get events => _events.stream;

  /// Binding-status transitions, for a UI indicator.
  Stream<PedalBindStatus> get statusChanges => _statusChanges.stream;

  /// The current binding status.
  PedalBindStatus get status => _status;

  /// The id of the bound output destination, or `null` when not bound.
  String? get boundOutputId => _boundOutputId;

  /// The host's available MIDI output destinations, as domain models (mapped
  /// from the transport's raw enumeration so callers never name the data type).
  List<PedalOutput> availableOutputs() => [
    for (final device in _transport.enumerateOutputs())
      PedalOutput(id: device.id, name: device.name),
  ];

  /// Binds the pedal's output to destination [outputDeviceId].
  ///
  /// Opens the port (moving through [PedalBindStatus.connecting]); on success
  /// the status becomes [PedalBindStatus.bound] and an identity request is
  /// broadcast, on failure [PedalBindStatus.error].
  void bind(String outputDeviceId) {
    if (_disposed) return;
    _setStatus(PedalBindStatus.connecting);
    final code = _transport.openOutput(outputDeviceId);
    if (code != 0) {
      _boundOutputId = null;
      _setStatus(PedalBindStatus.error);
      return;
    }
    _boundOutputId = outputDeviceId;
    _setStatus(PedalBindStatus.bound);
    _transport.send(PedalCodec.encodeIdentityRequest());
  }

  /// Unbinds the pedal: sends a goodbye frame (so the pedal darkens) and closes
  /// the output port.
  void unbind() {
    if (_disposed) return;
    if (_status == PedalBindStatus.bound) {
      _transport.send(
        PedalCodec.encodeFrame(PedalStateFrame.blank(goodbye: true)),
      );
    }
    _transport.closeOutput();
    _boundOutputId = null;
    _setStatus(PedalBindStatus.none);
  }

  /// Encodes [frame] and sends it to the pedal. A no-op when not bound.
  void pushState(PedalStateFrame frame) {
    if (_disposed || _status != PedalBindStatus.bound) return;
    _transport.send(PedalCodec.encodeFrame(frame));
  }

  /// Sends the single-byte loop-top pulse. A no-op when not bound.
  void sendLoopTop() {
    if (_disposed || _status != PedalBindStatus.bound) return;
    _transport.send(PedalCodec.encodeLoopTop());
  }

  void _onRaw(PedalRawMessage message) {
    final event = PedalCodec.decodeMessage(
      message.status,
      message.data1,
      message.data2,
      timestamp: _clock(),
    );
    if (event != null && !_events.isClosed) _events.add(event);
  }

  void _setStatus(PedalBindStatus status) {
    _status = status;
    if (!_statusChanges.isClosed) _statusChanges.add(status);
  }

  /// Cancels the inbound subscription, releases the output handle, and closes
  /// the streams. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _inputSub.cancel();
    await _transport.dispose();
    await _events.close();
    await _statusChanges.close();
  }
}
