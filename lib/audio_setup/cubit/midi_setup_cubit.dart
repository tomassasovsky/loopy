import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:midi_device_repository/midi_device_repository.dart';

part 'midi_setup_state.dart';

/// Composes [MidiDeviceRepository] data for the MIDI foot-controller picker.
///
/// A thin business-logic seam over the repository: it surfaces the repository's
/// [MidiConnection] domain model and folds in the raw activity stream
/// ([MidiDeviceRepository.activity]) as an opaque blink tick, emitting the
/// combined [MidiSetupState]. All MIDI lifecycle (enumerate / open / close,
/// hotplug supervision, persistence) lives in the repository, so this cubit
/// holds no device logic and — like the repository — never touches the audio
/// engine.
class MidiSetupCubit extends Cubit<MidiSetupState> {
  /// Creates a [MidiSetupCubit] over [repository].
  MidiSetupCubit({required MidiDeviceRepository repository})
    : _repository = repository,
      super(MidiSetupState(connection: repository.connection)) {
    _connectionSub = _repository.connections.listen(
      (connection) => emit(state.copyWith(connection: connection)),
    );
    // The activity stream is high-frequency and presentation-only, so it drives
    // a separate tick rather than the connection model (kept out of the data
    // layer's domain state).
    _activitySub = _repository.activity.listen(
      (_) => emit(state.copyWith(activityTick: state.activityTick + 1)),
    );
  }

  final MidiDeviceRepository _repository;
  late final StreamSubscription<MidiConnection> _connectionSub;
  late final StreamSubscription<void> _activitySub;

  /// Selects the device [id] to open (empty id selects "None").
  Future<void> select(String id) => _repository.select(id);

  /// Deselects the device ("None").
  Future<void> selectNone() => _repository.selectNone();

  /// Re-enumerates the host's MIDI inputs and reconciles the pinned device.
  void refresh() => _repository.refresh();

  @override
  Future<void> close() {
    // The repository is owned by the app shell (provided via RepositoryProvider
    // and disposed there); the cubit only borrows it, so it must not be
    // disposed here.
    unawaited(_connectionSub.cancel());
    unawaited(_activitySub.cancel());
    return super.close();
  }
}
