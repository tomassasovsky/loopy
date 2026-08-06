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

  /// Pairs with [address] — discover, pair, trust, connect.
  ///
  /// Marks [BluetoothState.pairingAddress] rather than [BluetoothState.busy]:
  /// pairing waits on a human at the other device, and the rest of the list
  /// stays usable behind the banner.
  Future<void> pair(String address) async {
    if (!state.supported) return;
    emit(
      state.copyWith(pairingAddress: address, clearError: true),
    );
    try {
      await _repository.pair(address);
      await _refreshDevices(clearPairing: true);
    } on Object catch (e) {
      emit(
        state.copyWith(
          clearPairing: true,
          errorMessage: '$e',
          failedAddress: address,
        ),
      );
    }
  }

  /// Abandons an in-flight pairing.
  ///
  /// Drops the marker only. The helper call itself cannot be recalled once
  /// issued, so claiming anything more about the far device would be a lie —
  /// the next scan reports what actually happened.
  void cancelPairing() {
    if (state.pairingAddress == null) return;
    emit(state.copyWith(clearPairing: true, clearError: true));
  }

  /// Connects an already-paired [address].
  Future<void> connect(String address) => _deviceAction(
    address,
    () => _repository.connect(address),
  );

  /// Drops the link to [address], leaving the pairing in place.
  Future<void> disconnect(String address) => _deviceAction(
    address,
    () => _repository.disconnect(address),
  );

  /// Removes the pairing for [address] entirely.
  Future<void> forget(String address) => _deviceAction(
    address,
    () => _repository.forget(address),
  );

  Future<void> _deviceAction(
    String address,
    Future<void> Function() action,
  ) async {
    if (!state.supported) return;
    emit(state.copyWith(busy: true, clearError: true));
    try {
      await action();
      await _refreshDevices();
    } on Object catch (e) {
      emit(
        state.copyWith(
          busy: false,
          errorMessage: '$e',
          failedAddress: address,
        ),
      );
    }
  }

  /// Re-reads scan + status after a device verb.
  ///
  /// The verbs report only success or failure, so the list is re-derived from
  /// the adapter rather than patched from what the verb claims it did: bluez
  /// accepts a command and leaves the device as it was often enough that the
  /// exit code is not evidence of state.
  Future<void> _refreshDevices({bool clearPairing = false}) async {
    try {
      final devices = await _repository.scan();
      final status = await _repository.status();
      if (isClosed) return;
      emit(
        state.copyWith(
          devices: devices,
          status: status,
          busy: false,
          clearPairing: clearPairing,
        ),
      );
    } on Object catch (e) {
      if (isClosed) return;
      emit(
        state.copyWith(
          busy: false,
          clearPairing: clearPairing,
          errorMessage: '$e',
        ),
      );
    }
  }
}
