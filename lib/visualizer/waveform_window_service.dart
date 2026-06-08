import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/widgets.dart';

/// Manages the secondary output-waveform window: opening/closing it and pushing
/// waveform frames to it. Injected into the app so tests use a no-op.
abstract interface class WaveformWindowService {
  /// Whether the waveform window is currently open.
  bool get isOpen;

  /// Opens the waveform window (idempotent).
  Future<void> open();

  /// Closes the waveform window (idempotent).
  Future<void> close();

  /// Sends a waveform frame (loop peaks + playhead [progress] in `0..1`) to the
  /// open window; no-op if closed.
  void pushWaveform(Float32List samples, double progress);
}

/// Opens a real second OS window via `desktop_multi_window` and streams
/// waveform frames to it over the plugin's method channel.
class DesktopMultiWindowWaveformService implements WaveformWindowService {
  int? _windowId;

  @override
  bool get isOpen => _windowId != null;

  @override
  Future<void> open() async {
    if (_windowId != null) return;
    final controller = await DesktopMultiWindow.createWindow(
      jsonEncode({'view': 'waveform'}),
    );
    _windowId = controller.windowId;
    await controller.setFrame(const Offset(120, 120) & const Size(960, 320));
    await controller.setTitle('Loopy — Output');
    await controller.show();
  }

  @override
  Future<void> close() async {
    final id = _windowId;
    if (id == null) return;
    _windowId = null;
    await WindowController.fromWindowId(id).close();
  }

  @override
  void pushWaveform(Float32List samples, double progress) {
    final id = _windowId;
    if (id == null) return;
    // Fire-and-forget; the next frame supersedes any dropped one.
    unawaited(
      DesktopMultiWindow.invokeMethod(id, 'waveform', {
        'samples': samples,
        'progress': progress,
      }),
    );
  }
}

/// A no-op service for tests and platforms without multi-window support.
class NoopWaveformWindowService implements WaveformWindowService {
  @override
  bool get isOpen => false;

  @override
  Future<void> open() async {}

  @override
  Future<void> close() async {}

  @override
  void pushWaveform(Float32List samples, double progress) {}
}
