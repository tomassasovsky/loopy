import 'dart:convert';

/// JSON payload passed to the secondary output-waveform window.
class WaveformWindowArgs {
  /// Creates [WaveformWindowArgs].
  const WaveformWindowArgs({
    this.title,
    this.x = 120,
    this.y = 120,
    this.width = 960,
    this.height = 320,
  });

  /// Parses the JSON [arguments] string from a sub-window controller.
  factory WaveformWindowArgs.parse(String arguments) {
    if (arguments.isEmpty) return const WaveformWindowArgs();
    try {
      final map = jsonDecode(arguments);
      if (map is! Map) return const WaveformWindowArgs();
      return WaveformWindowArgs(
        title: map['title'] is String ? map['title'] as String : null,
        x: _readDouble(map['x']) ?? 120,
        y: _readDouble(map['y']) ?? 120,
        width: _readDouble(map['width']) ?? 960,
        height: _readDouble(map['height']) ?? 320,
      );
    } on Object {
      return const WaveformWindowArgs();
    }
  }

  /// OS window title, when provided by the main window.
  final String? title;

  /// Window position and size passed from the main window.
  final double x;
  final double y;
  final double width;
  final double height;

  static const _viewKey = 'view';
  static const viewWaveform = 'waveform';

  /// Whether [arguments] identifies the output-waveform sub-window.
  static bool isWaveformWindow(String arguments) {
    if (arguments.isEmpty) return false;
    try {
      final map = jsonDecode(arguments);
      return map is Map && map[_viewKey] == viewWaveform;
    } on Object {
      return false;
    }
  }

  /// Encodes the waveform-window payload for window creation.
  static String encode({
    String? title,
    double x = 120,
    double y = 120,
    double width = 960,
    double height = 320,
  }) => jsonEncode({
    _viewKey: viewWaveform,
    'title': ?title,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  });

  static double? _readDouble(Object? value) =>
      value is num ? value.toDouble() : null;
}
