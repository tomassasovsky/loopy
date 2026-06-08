import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/visualizer/widgets/waveform_view.dart';

/// Entrypoint for the secondary waveform window — a separate Flutter engine
/// spawned by `desktop_multi_window`. It owns no audio engine; the main window
/// pushes `waveform` frames to it over the plugin's method channel.
void runWaveformWindow(int windowId) {
  WidgetsFlutterBinding.ensureInitialized();
  final samples = ValueNotifier<Float32List>(Float32List(0));
  DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
    if (call.method == 'waveform' && call.arguments is Float32List) {
      samples.value = call.arguments as Float32List;
    }
    return null;
  });
  runApp(WaveformWindowApp(samples: samples));
}

/// The root widget of the waveform window: a full-screen [WaveformView] driven
/// by frames pushed from the main window.
class WaveformWindowApp extends StatelessWidget {
  /// Creates a [WaveformWindowApp] rendering [samples].
  const WaveformWindowApp({required this.samples, super.key});

  /// The latest waveform frame, updated as the main window pushes new data.
  final ValueListenable<Float32List> samples;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.bigPicture,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: ValueListenableBuilder<Float32List>(
            valueListenable: samples,
            builder: (context, data, _) => WaveformView(samples: data),
          ),
        ),
      ),
    );
  }
}
