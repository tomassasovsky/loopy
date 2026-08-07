import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';

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

      expect(l10n.appMenuLabel, 'Segno');
      expect(l10n.sessionSaveAs, 'Save as…');
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

      expect(l10n.sessionSaveAs, 'Guardar como…');
      expect(l10n.trackStatePlaying, 'reproduciendo');
      expect(l10n.defaultTrackName(1), 'PISTA 1');
      expect(l10n.startEngine, 'Iniciar motor');
    });
  });

  group('trackName', () {
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('is the name the rig gave the track', () {
      expect(l10n.trackName(const ['drums', 'bass'], 1), 'bass');
    });

    test('localizes the untouched default rather than echoing it', () {
      // A track nobody has renamed still holds the seeded `TRACK 2`, which is
      // storage, not a display string — it goes back through the localized
      // default so a Spanish rig reads PISTA 2.
      expect(l10n.trackName(const ['drums', 'TRACK 2'], 1), 'TRACK 2');
      expect(
        l10n.trackName(const ['drums', 'TRACK 2'], 1),
        l10n.defaultTrackName(2),
      );
    });

    test('falls back rather than throwing on an absent channel', () {
      // A stale binding names a track the rig no longer has; a row that still
      // says what it used to drive beats a crash.
      expect(l10n.trackName(const ['drums'], 7), l10n.defaultTrackName(8));
      expect(l10n.trackName(const [], 0), l10n.defaultTrackName(1));
      expect(l10n.trackName(const ['drums'], -1), l10n.defaultTrackName(0));
    });
  });

  group('inputName', () {
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('is the name the player gave the socket', () {
      expect(l10n.inputName(const {0: 'guitar', 1: 'mic'}, 1), 'mic');
    });

    test('an unnamed socket falls back to its ordinal', () {
      // A socket with no name is ABSENT from the map rather than empty, so
      // the resolver is the one place that turns "nothing stored" into words.
      expect(l10n.inputName(const {0: 'guitar'}, 1), l10n.inputChannelLabel(2));
      expect(l10n.inputName(const {}, 0), l10n.inputChannelLabel(1));
      // A stored empty string reads the same way, so a half-written value can
      // never render as a blank name.
      expect(l10n.inputName(const {1: ''}, 1), l10n.inputChannelLabel(2));
    });

    test('falls back rather than throwing on an absent socket', () {
      // A session saved on an eight-in rig still routes In 6 when it is
      // reopened on a two-in one, and that lane's row has to say something.
      expect(l10n.inputName(const {0: 'guitar'}, 5), l10n.inputChannelLabel(6));
      expect(
        l10n.inputName(const {0: 'guitar'}, -1),
        l10n.inputChannelLabel(0),
      );
    });
  });
}
