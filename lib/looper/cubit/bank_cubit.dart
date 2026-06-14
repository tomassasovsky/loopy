import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';

part 'bank_state.dart';

/// Holds the active track bank: a transient UI cursor over the two banks of
/// four tracks (channels 0–3 and 4–7), selected one at a time. Banking is
/// always on, so there is nothing to persist.
class BankCubit extends Cubit<BankState> {
  /// Creates a [BankCubit].
  BankCubit() : super(const BankState());

  /// Selects the active bank (0 or 1).
  void selectBank(int bank) {
    emit(state.copyWith(activeBank: bank.clamp(0, BankState.bankCountMax - 1)));
  }

  /// Toggles between bank A and bank B.
  void toggle() => selectBank(state.activeBank == 0 ? 1 : 0);
}
