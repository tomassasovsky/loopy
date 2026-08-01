/// Hardware-agnostic controller abstraction: maps raw MIDI inputs to looper
/// actions and to external-MIDI bindings (continuous CC ranges and discrete
/// on/off stomps), with MIDI-learn capture.
library;

export 'src/binding_behavior.dart';
export 'src/controller_binding.dart';
export 'src/controller_binding_event.dart';
export 'src/controller_binding_set.dart';
export 'src/controller_event.dart';
export 'src/controller_input.dart';
export 'src/controller_mapping.dart';
export 'src/controller_repository.dart';
export 'src/controller_source.dart';
export 'src/looper_action.dart';
