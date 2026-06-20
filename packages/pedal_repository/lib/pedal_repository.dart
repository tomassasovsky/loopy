/// Repository + protocol layer for the Loopy bidirectional MIDI looper pedal:
/// the state-frame models and SysEx codec shared with the firmware as one
/// contract, the `PedalRepository` over a `PedalTransport`, and the native
/// composition factory (`createNativePedalRepository`) that adapts a MIDI input
/// source into the pedal's transport.
library;

export 'src/models/pedal_output.dart';
export 'src/native_pedal_repository.dart';
export 'src/native_pedal_transport.dart';
export 'src/noop_pedal_transport.dart';
export 'src/pedal_button.dart';
export 'src/pedal_codec.dart';
export 'src/pedal_event.dart';
export 'src/pedal_repository.dart';
export 'src/pedal_state_frame.dart';
export 'src/pedal_transport.dart';
