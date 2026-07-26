import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/bluetooth/bluetooth_cubit.dart';
import 'package:loopy/bluetooth/bluetooth_page.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/theme.dart';

void main() {
  testWidgets('shows unsupported body when the helper is absent', (
    tester,
  ) async {
    final cubit = BluetoothCubit(
      repository: const BluetoothRepository(
        client: UnsupportedBluetoothClient(),
      ),
    );
    addTearDown(cubit.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider.value(
          value: cubit,
          child: const BluetoothPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.byKey(const Key('bluetooth_page')), findsOneWidget);
    expect(find.text(l10n.bluetoothUnsupportedBody), findsOneWidget);
  });
}
