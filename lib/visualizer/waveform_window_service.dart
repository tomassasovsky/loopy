import 'dart:async';
import 'dart:typed_data';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:loopy/visualizer/waveform_window_args.dart';
import 'package:loopy/visualizer/waveform_window_channel.dart';

/// Manages the secondary output-waveform window: opening/closing it and pushing
/// waveform frames to it. Injected into the app so tests use a no-op.
abstract interface class WaveformWindowService {
  /// Whether the waveform window is currently open.
  bool get isOpen;

  /// Opens the waveform window (idempotent).
  ///
  /// [title] sets the OS window title; defaults to English when omitted.
  /// Returns `true` once the window is ready, or `false` if it failed to signal
  /// readiness within the timeout — so the caller can surface the failure
  /// instead of degrading silently.
  Future<bool> open({String title = 'Loopy — Output'});

  /// Closes the waveform window (idempotent).
  Future<void> close();

  /// Sends a waveform frame (loop peaks + playhead [progress] in `0..1`) to the
  /// open window; no-op if closed.
  void pushWaveform(Float32List samples, double progress);
}

/// Opens a real second OS window via `desktop_multi_window` and streams
/// waveform frames to it over [waveformWindowChannel].
class DesktopMultiWindowWaveformService implements WaveformWindowService {
  WindowController? _controller;
  static Completer<void>? _readyCompleter;
  static var _mainChannelRegistered = false;

  /// Closes sub-windows left over from a hot restart. Dart state is reset but
  /// native windows from `desktop_multi_window` survive.
  static Future<void> closeOrphanWindows() async {
    await _ensureMainChannelRegistered();
    final current = await WindowController.fromCurrentEngine();
    for (final controller in await WindowController.getAll()) {
      if (controller.windowId == current.windowId) continue;
      if (WaveformWindowArgs.isWaveformWindow(controller.arguments)) {
        await waveformWindowChannel
            .invokeMethod('window_close')
            .catchError((Object _) => null);
      }
    }
  }

  @override
  bool get isOpen => _controller != null;

  static Future<void> _ensureMainChannelRegistered() async {
    if (_mainChannelRegistered) return;
    await waveformWindowChannel.setMethodCallHandler((call) async {
      if (call.method == waveformWindowReadyMethod) {
        _readyCompleter?.complete();
      }
      return null;
    });
    _mainChannelRegistered = true;
  }

  @override
  Future<bool> open({String title = 'Loopy — Output'}) async {
    if (_controller != null) return true;
    await closeOrphanWindows();
    await _ensureMainChannelRegistered();

    _readyCompleter = Completer<void>();
    final controller = await WindowController.create(
      WindowConfiguration(
        arguments: WaveformWindowArgs.encode(title: title),
      ),
    );
    _controller = controller;

    // The sub-window signals readiness over the channel; a timeout means it
    // never came up. Report that so the caller can show an operator-visible
    // indicator instead of leaving a dark second screen.
    var ready = true;
    await _readyCompleter!.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => ready = false,
    );
    await controller.show();
    return ready;
  }

  @override
  Future<void> close() async {
    _controller = null;
    _readyCompleter = null;
    await waveformWindowChannel
        .invokeMethod('window_close')
        .catchError((Object _) => null);
    await closeOrphanWindows();
  }

  @override
  void pushWaveform(Float32List samples, double progress) {
    if (_controller == null) return;
    unawaited(
      waveformWindowChannel
          .invokeMethod('waveform', {
            'samples': samples,
            'progress': progress,
          })
          .catchError((Object _) => null),
    );
  }
}

/// A no-op service for tests and platforms without multi-window support.
class NoopWaveformWindowService implements WaveformWindowService {
  @override
  bool get isOpen => false;

  @override
  Future<bool> open({String title = 'Loopy — Output'}) async => true;

  @override
  Future<void> close() async {}

  @override
  void pushWaveform(Float32List samples, double progress) {}
}
