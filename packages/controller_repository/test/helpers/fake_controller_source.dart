import 'dart:async';

import 'package:controller_repository/controller_repository.dart';

/// An in-memory [ControllerSource] for tests: push raw inputs via [emit].
class FakeControllerSource implements ControllerSource {
  final StreamController<RawControllerInput> _controller =
      StreamController<RawControllerInput>.broadcast();

  /// Whether [dispose] has been called.
  bool disposed = false;

  @override
  Stream<RawControllerInput> get inputs => _controller.stream;

  /// Pushes a raw input through this source.
  void emit(RawControllerInput input) => _controller.add(input);

  /// Convenience: emits a press (and optional release) for a control.
  void press(ControllerSourceKind kind, int id, {int value = 127}) {
    emit(RawControllerInput(kind: kind, id: id, value: value));
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _controller.close();
  }
}
