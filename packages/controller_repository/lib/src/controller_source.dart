import 'package:controller_repository/src/controller_input.dart';

/// A source of raw controller inputs (a data-layer client).
///
/// The MIDI client (`midi_client`) and Raspberry Pi GPIO client (`gpio_client`)
/// implement this so the repository can combine them behind one abstraction.
abstract interface class ControllerSource {
  /// A broadcast stream of raw inputs from this source.
  Stream<RawControllerInput> get inputs;

  /// Releases the source.
  Future<void> dispose();
}
