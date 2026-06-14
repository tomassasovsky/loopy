import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/looper/cubit/bank_cubit.dart';

void main() {
  group('BankCubit', () {
    test('defaults to two banks with bank A showing channels 0-3', () {
      final state = BankCubit().state;
      expect(state.activeBank, 0);
      expect(state.bankCount, 2);
      expect(state.baseChannel, 0);
      expect(state.contains(3), isTrue);
      expect(state.contains(4), isFalse);
    });

    blocTest<BankCubit, BankState>(
      'selecting bank B exposes channels 4-7',
      build: BankCubit.new,
      act: (cubit) => cubit.selectBank(1),
      expect: () => [const BankState(activeBank: 1)],
      verify: (_) {
        const state = BankState(activeBank: 1);
        expect(state.baseChannel, 4);
        expect(state.contains(4), isTrue);
        expect(state.contains(3), isFalse);
      },
    );

    blocTest<BankCubit, BankState>(
      'selectBank clamps out-of-range indices to the bank count',
      build: BankCubit.new,
      act: (cubit) => cubit.selectBank(5),
      expect: () => [const BankState(activeBank: 1)],
    );

    blocTest<BankCubit, BankState>(
      'toggle flips between bank A and bank B',
      build: BankCubit.new,
      act: (cubit) => cubit
        ..toggle()
        ..toggle(),
      expect: () => [
        const BankState(activeBank: 1),
        const BankState(),
      ],
    );
  });
}
