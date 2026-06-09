import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/looper/cubit/bank_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  late SettingsRepository settings;

  setUp(() => settings = SettingsRepository(store: FakeKeyValueStore()));

  group('BankCubit', () {
    test('defaults to two banks with bank A showing channels 0-3', () {
      final state = BankCubit(settings: settings).state;
      expect(state.enabled, isTrue);
      expect(state.bankCount, 2);
      expect(state.baseChannel, 0);
      expect(state.contains(3), isTrue);
      expect(state.contains(4), isFalse);
    });

    blocTest<BankCubit, BankState>(
      'enabling the bank persists it and exposes two banks',
      build: () => BankCubit(settings: settings),
      act: (cubit) => cubit.setEnabled(value: true),
      expect: () => [const BankState()],
      verify: (_) async => expect(await settings.loadBankEnabled(), isTrue),
    );

    blocTest<BankCubit, BankState>(
      'selecting bank B exposes channels 4-7 when enabled',
      build: () => BankCubit(settings: settings),
      seed: () => const BankState(),
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
      'selectBank is ignored while the second bank is disabled',
      build: () => BankCubit(settings: settings),
      seed: () => const BankState(enabled: false),
      act: (cubit) => cubit.selectBank(1),
      expect: () => <BankState>[],
    );

    blocTest<BankCubit, BankState>(
      'disabling the bank returns to bank A',
      build: () => BankCubit(settings: settings),
      seed: () => const BankState(activeBank: 1),
      act: (cubit) => cubit.setEnabled(value: false),
      expect: () => [const BankState(enabled: false)],
    );

    blocTest<BankCubit, BankState>(
      'load restores a persisted enabled bank',
      setUp: () => settings.saveBankEnabled(value: true),
      build: () => BankCubit(settings: settings),
      act: (cubit) => cubit.load(),
      expect: () => [const BankState()],
    );
  });
}
