import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:loopy/wifi/wifi_env.dart';

part 'wifi_state.dart';

/// Drives the console's Wi-Fi picker: scan, join, forget.
///
/// Holds no platform knowledge — every effect goes through the injected
/// [WifiEnv], so this is testable with no radio and no NetworkManager.
class WifiCubit extends Cubit<WifiState> {
  /// Creates a [WifiCubit] over [env].
  WifiCubit({required WifiEnv env})
    : _env = env,
      super(const WifiState(supported: false));

  final WifiEnv _env;

  /// Scans and publishes the visible networks.
  ///
  /// Kept separate from the constructor so the page controls when the first
  /// scan runs, and so pull-to-refresh reuses one path.
  Future<void> refresh() async {
    if (!_env.isSupported) {
      emit(const WifiState(supported: false));
      return;
    }
    emit(state.copyWith(supported: true, busy: true, clearMessage: true));
    final networks = await _env.scan();
    if (isClosed) return;
    emit(state.copyWith(networks: networks, busy: false));
  }

  /// Joins [network], using [password] when one is needed.
  ///
  /// Re-scans afterwards either way: on success to pick up the new active
  /// network, and on failure because a rejected password can still change
  /// what NetworkManager reports.
  Future<void> connect(WifiNetwork network, {String? password}) async {
    emit(state.copyWith(busy: true, clearMessage: true));
    final error = await _env.connect(ssid: network.ssid, password: password);
    if (isClosed) return;
    emit(state.copyWith(message: error, clearMessage: error == null));
    await refreshPreservingMessage();
  }

  /// Deletes the saved profile for [network].
  Future<void> forget(WifiNetwork network) async {
    emit(state.copyWith(busy: true, clearMessage: true));
    final error = await _env.forget(network.ssid);
    if (isClosed) return;
    emit(state.copyWith(message: error, clearMessage: error == null));
    await refreshPreservingMessage();
  }

  /// A [refresh] that leaves any pending message in place, so the reason a
  /// join failed survives the re-scan that follows it.
  Future<void> refreshPreservingMessage() async {
    final message = state.message;
    await refresh();
    if (isClosed || message == null) return;
    emit(state.copyWith(message: message));
  }
}
