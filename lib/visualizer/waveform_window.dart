import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/visualizer/widgets/waveform_view.dart';

/// A loop waveform frame pushed from the main window: the loop peaks plus the
/// playhead position.
typedef WaveformFrame = ({Float32List samples, double progress});

/// Entrypoint for the secondary waveform window — a separate Flutter engine
/// spawned by `desktop_multi_window`. It owns no audio engine; the main window
/// pushes `waveform` frames to it over the plugin's method channel.
void runWaveformWindow(int windowId) {
  WidgetsFlutterBinding.ensureInitialized();
  final frame = ValueNotifier<WaveformFrame>(
    (samples: Float32List(0), progress: 0),
  );
  DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
    if (call.method == 'waveform' && call.arguments is Map) {
      final args = call.arguments as Map;
      final progress = args['progress'];
      frame.value = (
        // The plugin re-serializes across engines, which can turn the
        // Float32List into a plain List<double>, so accept any numeric list.
        samples: _toFloat32List(args['samples']),
        progress: progress is num ? progress.toDouble() : 0.0,
      );
    }
    return null;
  });
  runApp(WaveformWindowApp(frame: frame));
}

/// Coerces a method-channel payload (a [Float32List], or a `List` of numbers
/// after the plugin re-serializes across engines) into a [Float32List].
Float32List _toFloat32List(Object? raw) {
  if (raw is Float32List) return raw;
  if (raw is List) {
    final out = Float32List(raw.length);
    for (var i = 0; i < raw.length; i++) {
      final v = raw[i];
      out[i] = v is num ? v.toDouble() : 0.0;
    }
    return out;
  }
  return Float32List(0);
}

/// The root widget of the waveform window: a full-screen [WaveformView] driven
/// by frames pushed from the main window.
class WaveformWindowApp extends StatelessWidget {
  /// Creates a [WaveformWindowApp] rendering [frame].
  const WaveformWindowApp({required this.frame, super.key});

  /// The latest waveform frame, updated as the main window pushes new data.
  final ValueListenable<WaveformFrame> frame;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.bigPicture,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: ValueListenableBuilder<WaveformFrame>(
            valueListenable: frame,
            builder: (context, data, _) => WaveformView(
              samples: data.samples,
              progress: data.progress,
            ),
          ),
        ),
      ),
    );
  }
}
