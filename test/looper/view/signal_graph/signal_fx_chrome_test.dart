import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/view/signal_graph/signal_fx_chrome.dart';
import 'package:loopy/theme/surface_theme.dart';

import '../../../helpers/helpers.dart';

void main() {
  group('InheritedFxBadge', () {
    testWidgets('names its single source input', (tester) async {
      await tester.pumpApp(
        const Scaffold(
          body: Center(
            child: InheritedFxBadge(badgeKey: Key('badge'), inputs: [1]),
          ),
        ),
      );

      expect(find.text('Inherited'), findsOneWidget);
      expect(
        tester.widget<Tooltip>(find.byType(Tooltip)).message,
        'Copied from In 2 when this take was recorded',
      );
    });

    testWidgets('joins a multi-input inherit in input order (A8)', (
      tester,
    ) async {
      await tester.pumpApp(
        const Scaffold(
          body: Center(
            child: InheritedFxBadge(badgeKey: Key('badge'), inputs: [0, 2]),
          ),
        ),
      );

      expect(
        tester.widget<Tooltip>(find.byType(Tooltip)).message,
        'Copied from In 1, In 3 when this take was recorded',
      );
    });

    testWidgets('announces its provenance rather than just "Inherited"', (
      tester,
    ) async {
      await tester.pumpApp(
        const Scaffold(
          body: Center(
            child: InheritedFxBadge(badgeKey: Key('badge'), inputs: [1]),
          ),
        ),
      );

      expect(
        tester.getSemantics(find.byKey(const Key('badge'))).label,
        contains('Copied from In 2'),
      );
    });
  });

  group('FxPowerToggle', () {
    testWidgets('reports the flipped state and announces the current one', (
      tester,
    ) async {
      final calls = <bool>[];
      await tester.pumpApp(
        Scaffold(
          body: Center(
            child: FxPowerToggle(
              toggleKey: const Key('power'),
              enabled: true,
              onChanged: ({required enabled}) => calls.add(enabled),
              semanticLabel: 'Effect on',
              tooltip: 'Turn this effect off',
            ),
          ),
        ),
      );

      expect(
        tester.getSemantics(find.byKey(const Key('power'))).label,
        contains('Effect on'),
      );
      await tester.tap(find.byKey(const Key('power')));
      expect(calls, [false]);
    });
  });

  group('FxDisabledDim', () {
    testWidgets('dims to the theme token, never to a hardcoded opacity', (
      tester,
    ) async {
      await tester.pumpApp(
        const Scaffold(
          body: FxDisabledDim(enabled: false, child: Text('x')),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        SurfaceTheme.dark.disabledOpacity,
      );
    });

    testWidgets('renders an engaged subtree at full strength', (tester) async {
      await tester.pumpApp(
        const Scaffold(
          body: FxDisabledDim(enabled: true, child: Text('x')),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1.0,
      );
    });
  });

  group('fxPluginStatus', () {
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('classifies the placeholder states in the card order', () {
      const ref = PluginRef(format: PluginFormat.vst3, id: 'a', version: 1);

      // A built-in never carries an attention state.
      expect(
        fxPluginStatus(l10n, BuiltInEffect(type: TrackEffectType.drive)),
        isNull,
      );
      // Nor does a resolved plugin.
      expect(fxPluginStatus(l10n, const PluginEffect(ref: ref)), isNull);
      // Loading wins over unavailable (F5) — still scanning is not a failure.
      expect(
        fxPluginStatus(
          l10n,
          const PluginEffect(ref: ref, loading: true, unavailable: true),
        )?.message,
        l10n.signalPluginLoading,
      );
      // Rejected reads distinctly from missing (D-BUS vs D-MISS).
      expect(
        fxPluginStatus(l10n, const PluginEffect(ref: ref, unavailable: true))
            ?.message,
        l10n.signalPluginUnavailable,
      );
      expect(
        fxPluginStatus(
          l10n,
          const PluginEffect(ref: ref, unavailable: true, unsupported: true),
        )?.message,
        l10n.signalPluginUnsupported,
      );
      // A resolved-but-drifted plugin still flags.
      expect(
        fxPluginStatus(
          l10n,
          const PluginEffect(ref: ref, versionChanged: true),
        )?.message,
        l10n.signalPluginVersionChanged,
      );
    });
  });
}
