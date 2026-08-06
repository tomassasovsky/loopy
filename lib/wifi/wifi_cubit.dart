import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:wifi_repository/wifi_repository.dart';

part 'wifi_state.dart';

/// Drives the console WiFi UI: status, scan, join, disconnect, forget, radio.
class WifiCubit extends Cubit<WifiState> {
  /// Creates a [WifiCubit] over [repository].
  WifiCubit({required WifiRepository repository})
    : _repository = repository,
      super(const WifiState());

  final WifiRepository _repository;

  /// Loads status (and whether the stack is supported).
  Future<void> load() async {
    emit(
      state.copyWith(
        busy: true,
        clearConnectingSsid: true,
        disconnecting: false,
        clearError: true,
      ),
    );
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

  /// Scans for nearby networks.
  Future<void> scan() async {
    if (!state.supported) return;
    emit(state.copyWith(scanning: true, clearError: true));
    try {
      final networks = await _repository.scan();
      // Prefer stronger signal; drop empty SSIDs / de-dupe by name.
      final bySsid = <String, WifiNetwork>{};
      for (final n in networks) {
        if (n.ssid.isEmpty) continue;
        final existing = bySsid[n.ssid];
        if (existing == null || n.signal > existing.signal) {
          bySsid[n.ssid] = n;
        }
      }
      final sorted = bySsid.values.toList()
        ..sort((a, b) => b.signal.compareTo(a.signal));
      final status = await _repository.status();
      emit(
        state.copyWith(
          networks: sorted,
          status: status,
          scanning: false,
        ),
      );
    } on Object catch (e) {
      emit(state.copyWith(scanning: false, errorMessage: '$e'));
    }
  }

  /// Joins [ssid] with optional [psk].
  Future<void> connect(String ssid, {String? psk}) async {
    if (!state.supported) return;
    emit(
      state.copyWith(
        busy: true,
        connectingSsid: ssid,
        disconnecting: false,
        clearError: true,
      ),
    );
    try {
      await _repository.connect(ssid, psk: psk);
      final status = await _repository.status();
      emit(
        state.copyWith(
          status: status,
          busy: false,
          clearConnectingSsid: true,
          disconnecting: false,
        ),
      );
    } on Object catch (e) {
      var status = state.status;
      try {
        status = await _repository.status();
      } on Object {
        // Keep the last known status if refresh fails.
      }
      emit(
        state.copyWith(
          status: status,
          busy: false,
          clearConnectingSsid: true,
          disconnecting: false,
          errorMessage: '$e',
          failedSsid: ssid,
        ),
      );
    }
  }

  /// Abandons an in-flight join.
  ///
  /// Drops the in-flight marker and disconnects. The helper call itself cannot
  /// be recalled once issued, so dropping any association it may already have
  /// made is the only thing still true afterwards.
  Future<void> cancelConnect() async {
    if (state.connectingSsid == null) return;
    emit(state.copyWith(clearConnectingSsid: true, clearError: true));
    await disconnect();
  }

  /// Disconnects the current association.
  Future<void> disconnect() async {
    if (!state.supported) return;
    emit(
      state.copyWith(
        busy: true,
        disconnecting: true,
        clearConnectingSsid: true,
        clearError: true,
      ),
    );
    try {
      await _repository.disconnect();
      final status = await _repository.status();
      emit(
        state.copyWith(
          status: status,
          busy: false,
          disconnecting: false,
        ),
      );
    } on Object catch (e) {
      emit(
        state.copyWith(
          busy: false,
          disconnecting: false,
          errorMessage: '$e',
        ),
      );
    }
  }

  /// Forgets a saved [ssid] and disconnects if it was the active one.
  Future<void> forget(String ssid) async {
    if (!state.supported) return;
    final forgettingActive =
        state.status.connected && state.status.ssid == ssid;
    emit(
      state.copyWith(
        busy: true,
        disconnecting: forgettingActive,
        clearConnectingSsid: true,
        clearError: true,
      ),
    );
    try {
      await _repository.forget(ssid);
      final status = await _repository.status();
      emit(
        state.copyWith(
          status: status,
          networks: [
            for (final n in state.networks)
              if (n.ssid != ssid) n,
          ],
          busy: false,
          disconnecting: false,
        ),
      );
    } on Object catch (e) {
      emit(
        state.copyWith(
          busy: false,
          disconnecting: false,
          errorMessage: '$e',
        ),
      );
    }
  }

  /// Radio on/off — Control Center tile tap.
  Future<void> setEnabled({required bool enabled}) async {
    if (!state.supported) return;
    emit(
      state.copyWith(
        busy: true,
        clearConnectingSsid: true,
        disconnecting: false,
        clearError: true,
      ),
    );
    try {
      await _repository.setEnabled(enabled: enabled);
      final status = await _repository.status();
      emit(state.copyWith(status: status, busy: false));
    } on Object catch (e) {
      emit(state.copyWith(busy: false, errorMessage: '$e'));
    }
  }

  /// Toggles radio enabled.
  Future<void> toggleEnabled() => setEnabled(enabled: !state.status.enabled);
}
