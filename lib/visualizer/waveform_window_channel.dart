import 'package:desktop_multi_window/desktop_multi_window.dart';

/// Cross-engine channel for the output-waveform sub-window.
///
/// Both the main window and the waveform window register on this channel.
/// The sub-window sends [waveformWindowReadyMethod] after its handler is live;
/// the main window waits for that before pushing frames.
const waveformWindowChannel = WindowMethodChannel('loopy/waveform_window');

/// Sent by the waveform window once [waveformWindowChannel] is registered.
const waveformWindowReadyMethod = 'ready';
