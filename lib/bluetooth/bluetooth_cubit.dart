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

  /// Pairs, trusts and connects [device] — the first contact with a device
  /// the console has never seen.
  ///
  /// Held in [BluetoothState.pairingAddress] rather than [BluetoothState.busy]
  /// so the rest of the list stays live behind the pairing banner: the console
  /// is waiting on a human pressing a button on a pedal, which can take as
  /// long as it takes.
  Future<void> pair(BluetoothDevice device) async {
    if (!state.supported) return;
    emit(state.copyWith(pairingAddress: device.address, clearError: true));
    try {
      await _repository.pair(device.address);
      await _refresh(clearPairing: true);
    } on Object catch (e) {
      emit(
        state.copyWith(
          clearPairing: true,
          errorMessage: '$e',
        ),
      );
    }
  }

  /// Abandons a pairing that is waiting on the device.
  void cancelPairing() {
    if (state.pairingAddress == null) return;
    emit(state.copyWith(clearPairing: true));
  }

  /// Connects an already-paired device.
  Future<void> connect(BluetoothDevice device) =>
      _act(() => _repository.connect(device.address));

  /// Drops the connection to [device], keeping the pairing.
  Future<void> disconnect(BluetoothDevice device) =>
      _act(() => _repository.disconnect(device.address));

  /// Removes the pairing for [device].
  Future<void> forget(BluetoothDevice device) =>
      _act(() => _repository.forget(device.address));

  /// Runs a device action, then re-reads devices and status so the list
  /// reflects what actually happened rather than what was asked for.
  Future<void> _act(Future<void> Function() action) async {
    if (!state.supported) return;
    emit(state.copyWith(busy: true, clearError: true));
    try {
      await action();
      await _refresh();
    } on Object catch (e) {
      emit(state.copyWith(busy: false, errorMessage: '$e'));
    }
  }

  Future<void> _refresh({bool clearPairing = false}) async {
    final devices = await _repository.scan();
    final status = await _repository.status();
    emit(
      state.copyWith(
        devices: devices,
        status: status,
        busy: false,
        clearPairing: clearPairing,
      ),
    );
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
