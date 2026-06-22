import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/visualizer/waveform_window_args.dart';
import 'package:loopy/visualizer/waveform_window_channel.dart';
import 'package:loopy/visualizer/widgets/waveform_view.dart';
import 'package:loopy/window/window_chrome.dart';
import 'package:window_manager/window_manager.dart';

/// A loop waveform frame pushed from the main window: the loop peaks plus the
/// playhead position.
typedef WaveformFrame = ({Float32List samples, double progress});

/// Entrypoint for the secondary waveform window — a separate Flutter engine
/// spawned by `desktop_multi_window`. It owns no audio engine; the main window
/// pushes `waveform` frames to it over [waveformWindowChannel].
Future<void> runWaveformWindow(WindowController controller) async {
  WidgetsFlutterBinding.ensureInitialized();

  final args = WaveformWindowArgs.parse(controller.arguments);
  final title = args.title ?? 'Loopy — Output';
  final frame = ValueNotifier<WaveformFrame>(
    (samples: Float32List(0), progress: 0),
  );

  // Register the shared channel before any slow init so the main window can
  // reach us as soon as [WindowController.create] returns.
  await waveformWindowChannel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'waveform':
        if (call.arguments is Map) {
          final map = call.arguments as Map;
          final progress = map['progress'];
          frame.value = (
            samples: _toFloat32List(map['samples']),
            progress: progress is num ? progress.toDouble() : 0.0,
          );
        }
        return null;
      case 'window_close':
        await windowManager.close();
        return null;
      default:
        return null;
    }
  });

  // Tell the main window the channel handler is live.
  await waveformWindowChannel
      .invokeMethod(waveformWindowReadyMethod)
      .catchError((Object _) => null);

  await windowManager.ensureInitialized();
  await configureLoopyDesktopWindow(title: title);
  await windowManager.setPosition(Offset(args.x, args.y));
  await windowManager.setSize(Size(args.width, args.height));
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: Size(args.width, args.height),
      title: title,
      backgroundColor: const Color(0xFF06060A),
    ),
    () async {
      await windowManager.show();
    },
  );

  runApp(WaveformWindowApp(frame: frame, title: title));
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
  const WaveformWindowApp({
    required this.frame,
    required this.title,
    super.key,
  });

  /// The latest waveform frame, updated as the main window pushes new data.
  final ValueListenable<WaveformFrame> frame;

  /// OS window title.
  final String title;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.bigPicture,
      home: LoopyWindowChromeShell(
        title: title,
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: ValueListenableBuilder<WaveformFrame>(
            valueListenable: frame,
            builder: (context, data, _) => WaveformView(
              samples: data.samples,
              progress: data.progress,
              // This window has no Localizations ancestor, so resolve the label
              // from the platform locale directly.
              semanticLabel: lookupAppLocalizations(
                PlatformDispatcher.instance.locale,
              ).a11yWaveform,
            ),
          ),
        ),
      ),
    );
  }
}
