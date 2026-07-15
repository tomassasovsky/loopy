import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/visualizer/waveform_window_args.dart';
import 'package:loopy/visualizer/waveform_window_channel.dart';
import 'package:loopy/visualizer/widgets/waveform_view.dart';
import 'package:loopy/window/window_chrome.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// Where the output-waveform window should sit: **full-bleed on a secondary
/// display** when one is present (the intended second-screen setup), else the
/// windowed fallback from [args]. Pure over the screen list so it can be
/// unit-tested without a real multi-monitor desktop.
///
/// Each screen's `position`/`size` arrive in that display's **own** logical
/// pixels (how `screen_retriever` reports them) with its DPI `scale`. The
/// result is returned in the **primary window's** logical space — what
/// `window_manager.setBounds` expects for the primary-hosted sub-window — by
/// rescaling with `scale / primaryScale`. Skipping this drops a secondary at a
/// different DPI than the primary onto the wrong place: e.g. a 4K@175% display
/// whose physical origin is x=2560 is reported at own-logical x=1463, a point
/// *inside* a 100%-scaled primary, so the window lands mid-primary.
@visibleForTesting
({Offset position, Size size, bool fullscreen}) waveformWindowPlacement({
  required List<({String id, Offset position, Size size, double scale})>
  screens,
  required String primaryId,
  required double primaryScale,
  required WaveformWindowArgs args,
}) {
  for (final screen in screens) {
    if (screen.id != primaryId) {
      final k = screen.scale / primaryScale;
      return (
        position: screen.position * k,
        size: screen.size * k,
        fullscreen: true,
      );
    }
  }
  return (
    position: Offset(args.x, args.y),
    size: Size(args.width, args.height),
    fullscreen: false,
  );
}

/// Resolves [waveformWindowPlacement] against the live displays, falling back
/// to the windowed layout if the display query fails (never leave the output
/// window unplaced).
Future<({Offset position, Size size, bool fullscreen})> _resolvePlacement(
  WaveformWindowArgs args,
) async {
  try {
    final displays = await screenRetriever.getAllDisplays();
    final primary = await screenRetriever.getPrimaryDisplay();
    return waveformWindowPlacement(
      screens: [
        for (final d in displays)
          (
            id: d.id,
            position: d.visiblePosition ?? Offset.zero,
            size: d.size,
            scale: d.scaleFactor?.toDouble() ?? 1.0,
          ),
      ],
      primaryId: primary.id,
      primaryScale: primary.scaleFactor?.toDouble() ?? 1.0,
      args: args,
    );
  } on Object {
    return (
      position: Offset(args.x, args.y),
      size: Size(args.width, args.height),
      fullscreen: false,
    );
  }
}

/// A loop waveform frame pushed from the main window: the loop peaks plus the
/// playhead position.
typedef WaveformFrame = ({
  Float32List samples,
  double progress,
  String selectedTrack,
});

/// Entrypoint for the secondary waveform window — a separate Flutter engine
/// spawned by `desktop_multi_window`. It owns no audio engine; the main window
/// pushes `waveform` frames to it over [waveformWindowChannel].
Future<void> runWaveformWindow(WindowController controller) async {
  WidgetsFlutterBinding.ensureInitialized();

  final args = WaveformWindowArgs.parse(controller.arguments);
  final title = args.title ?? 'Loopy — Output';
  final frame = ValueNotifier<WaveformFrame>(
    (samples: Float32List(0), progress: 0, selectedTrack: ''),
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
            selectedTrack: map['selectedTrack'] as String,
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

  // Full-bleed on a second monitor when there is one; otherwise the windowed
  // fallback. Two ordering rules make this land on the *second* display:
  //   1. Move the window onto the target display only *after* it is realized
  //      (`show`). A `setBounds` issued while the sub-window is still hidden is
  //      dropped by the Windows layer, so the later `setFullScreen` would fill
  //      whichever monitor the window defaulted to (the primary).
  //   2. `setFullScreen` *after* the move: the OS then fills the monitor the
  //      window is on at its native resolution — which also sidesteps
  //      window_manager scaling the size by the target display's DPI.
  final placement = await _resolvePlacement(args);
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: placement.size,
      title: title,
      backgroundColor: const Color(0xFF06060A),
    ),
    () async {
      await windowManager.show();
      await windowManager.setBounds(
        null,
        position: placement.position,
        size: placement.size,
      );
      if (placement.fullscreen) {
        await windowManager.setFullScreen(true);
      }
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
      theme: AppTheme.neon,
      home: LoopyWindowChromeShell(
        title: title,
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: ValueListenableBuilder<WaveformFrame>(
            valueListenable: frame,
            builder: (context, data, _) => WaveformView(
              selectedTrack: data.selectedTrack,
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
