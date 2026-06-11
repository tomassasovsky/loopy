import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/l10n/l10n.dart';

void main() {
  group('AppLocalizations', () {
    testWidgets('English strings resolve through context.l10n', (tester) async {
      late AppLocalizations l10n;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              l10n = context.l10n;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(l10n.looperAppBarTitle, 'Loopy');
      expect(l10n.saveSession, 'Save session');
      expect(l10n.trackStatePlaying, 'playing');
      expect(l10n.defaultTrackName(1), 'TRACK 1');
    });

    testWidgets('Spanish strings resolve for es locale', (tester) async {
      late AppLocalizations l10n;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              l10n = context.l10n;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(l10n.saveSession, 'Guardar sesión');
      expect(l10n.trackStatePlaying, 'reproduciendo');
      expect(l10n.defaultTrackName(1), 'PISTA 1');
      expect(l10n.startEngine, 'Iniciar motor');
    });
  });
}
