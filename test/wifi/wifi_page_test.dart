import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/wifi/wifi_cubit.dart';
import 'package:loopy/wifi/wifi_page.dart';
import 'package:wifi_repository/wifi_repository.dart';

void main() {
  testWidgets('shows unsupported body when the helper is absent', (
    tester,
  ) async {
    final cubit = WifiCubit(
      repository: const WifiRepository(client: UnsupportedWifiClient()),
    );
    addTearDown(cubit.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider.value(
          value: cubit,
          child: const WifiPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.byKey(const Key('wifi_page')), findsOneWidget);
    expect(find.text(l10n.wifiUnsupportedBody), findsOneWidget);
  });
}
