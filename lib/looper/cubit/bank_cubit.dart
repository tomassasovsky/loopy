import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:settings_repository/settings_repository.dart';

part 'bank_state.dart';

/// Holds the track-bank state: whether the second bank of four tracks is
/// enabled (persisted) and which bank is currently active (a transient UI
/// cursor). With the bank disabled there is one bank of four (channels 0–3);
/// enabled, two banks of four (0–3 and 4–7) selected one at a time.
class BankCubit extends Cubit<BankState> {
  /// Creates a [BankCubit] backed by [settings].
  BankCubit({required SettingsRepository settings})
    : _settings = settings,
      super(const BankState());

  final SettingsRepository _settings;

  /// Restores the persisted bank-enabled preference.
  Future<void> load() async {
    emit(state.copyWith(enabled: await _settings.loadBankEnabled()));
  }

  /// Enables or disables the second bank, persisting the choice. Disabling
  /// returns to bank A.
  Future<void> setEnabled({required bool value}) async {
    emit(
      state.copyWith(enabled: value, activeBank: value ? state.activeBank : 0),
    );
    await _settings.saveBankEnabled(value: value);
  }

  /// Selects the active bank (0 or 1). No-op when the second bank is disabled.
  void selectBank(int bank) {
    if (!state.enabled) return;
    emit(state.copyWith(activeBank: bank.clamp(0, BankState.bankCountMax - 1)));
  }

  /// Toggles between bank A and bank B.
  void toggle() => selectBank(state.activeBank == 0 ? 1 : 0);
}
