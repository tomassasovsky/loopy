import 'package:bloc/bloc.dart';
import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:equatable/equatable.dart';

part 'bluetooth_state.dart';

/// Drives the console Bluetooth UI: scan + power/discoverable/advertise.
class BluetoothCubit extends Cubit<BluetoothState> {
  /// Creates a [BluetoothCubit] over [repository].
  BluetoothCubit({required BluetoothRepository repository})
    : _repository = repository,
      super(const BluetoothState());

  final BluetoothRepository _repository;

  /// Loads adapter status.
  Future<void> load() async {
    emit(state.copyWith(busy: true, clearError: true));
    try {
      final status = await _repository.status();
      emit(
        state.copyWith(
          supported: status.supported && _repository.isSupported,
          status: status,
          busy: false,
        ),
      );
    } on Object catch (e) {
      emit(state.copyWith(busy: false, errorMessage: '$e'));
    }
  }

  /// Timed discovery of nearby devices.
  Future<void> scan() async {
    if (!state.supported) return;
    emit(state.copyWith(scanning: true, clearError: true));
    try {
      final devices = await _repository.scan();
      final status = await _repository.status();
      emit(
        state.copyWith(
          devices: devices,
          status: status,
          scanning: false,
        ),
      );
    } on Object catch (e) {
      emit(state.copyWith(scanning: false, errorMessage: '$e'));
    }
  }

  /// Adapter power on/off — Control Center tile tap.
  Future<void> setPowered({required bool enabled}) async {
    if (!state.supported) return;
    emit(state.copyWith(busy: true, clearError: true));
    try {
      await _repository.setPowered(enabled: enabled);
      final status = await _repository.status();
      emit(state.copyWith(status: status, busy: false));
    } on Object catch (e) {
      emit(state.copyWith(busy: false, errorMessage: '$e'));
    }
  }

  /// Toggles adapter power.
  Future<void> togglePowered() => setPowered(enabled: !state.status.powered);

  /// Toggles classic discoverable.
  Future<void> setDiscoverable({required bool enabled}) async {
    if (!state.supported) return;
    emit(state.copyWith(busy: true, clearError: true));
    try {
      await _repository.setDiscoverable(enabled: enabled);
      final status = await _repository.status();
      emit(state.copyWith(status: status, busy: false));
    } on Object catch (e) {
      emit(state.copyWith(busy: false, errorMessage: '$e'));
    }
  }

  /// Toggles LE advertising (+ discoverable when enabling).
  Future<void> setAdvertising({required bool enabled}) async {
    if (!state.supported) return;
    emit(state.copyWith(busy: true, clearError: true));
    try {
      await _repository.setAdvertising(enabled: enabled);
      final status = await _repository.status();
      emit(state.copyWith(status: status, busy: false));
    } on Object catch (e) {
      emit(state.copyWith(busy: false, errorMessage: '$e'));
    }
  }
}
