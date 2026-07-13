import 'package:daw_export/daw_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/performance/view/export_device_chain_summary.dart';

import '../../helpers/helpers.dart';

void main() {
  Widget summary(List<DawTrack> tracks) => Scaffold(
    body: Center(child: ExportDeviceChainSummary(tracks: tracks)),
  );

  Future<AppLocalizations> l10n() =>
      AppLocalizations.delegate.load(const Locale('en'));

  testWidgets('renders nothing for an empty track list', (tester) async {
    await tester.pumpApp(summary(const []));
    expect(find.byKey(const Key('exportSummary')), findsNothing);
  });

  testWidgets(
    'a track with a non-empty resolved chain shows the live-plugins label',
    (tester) async {
      await tester.pumpApp(
        summary(const [
          DawTrack(
            name: 'Track 0',
            deviceChain: [
              DawEffect(type: 3, params: [0.35, 0.35, 0.35, 0.0]),
            ],
          ),
        ]),
      );
      final strings = await l10n();

      expect(find.text('Track 0'), findsOneWidget);
      expect(find.text(strings.perfExportTrackLive), findsOneWidget);
      expect(find.text(strings.perfExportTrackBounced), findsNothing);
    },
  );

  testWidgets(
    'a track with an empty resolved chain (no effects) shows bounced with '
    'no fallback callout',
    (tester) async {
      await tester.pumpApp(
        summary(const [DawTrack(name: 'Track 1', deviceChain: [])]),
      );
      final strings = await l10n();

      expect(find.text(strings.perfExportTrackBounced), findsOneWidget);
      expect(
        find.text(strings.perfExportReasonMixedLanes),
        findsNothing,
      );
      expect(
        find.text(strings.perfExportReasonThirdPartyPlugin),
        findsNothing,
      );
      expect(
        find.text(strings.perfExportReasonUnrepresented),
        findsNothing,
      );
    },
  );

  testWidgets('mixedLaneChains shows its specific fallback message', (
    tester,
  ) async {
    await tester.pumpApp(
      summary(const [
        DawTrack(
          name: 'Track 2',
          deviceChainFallbackReason: DeviceChainFallbackReason.mixedLaneChains,
        ),
      ]),
    );
    final strings = await l10n();

    expect(find.text(strings.perfExportTrackBounced), findsOneWidget);
    expect(find.text(strings.perfExportReasonMixedLanes), findsOneWidget);
  });

  testWidgets('thirdPartyPlugin shows its specific fallback message', (
    tester,
  ) async {
    await tester.pumpApp(
      summary(const [
        DawTrack(
          name: 'Track 3',
          deviceChainFallbackReason: DeviceChainFallbackReason.thirdPartyPlugin,
        ),
      ]),
    );
    final strings = await l10n();

    expect(
      find.text(strings.perfExportReasonThirdPartyPlugin),
      findsOneWidget,
    );
  });

  testWidgets('unrepresentedEffectType shows its specific fallback message', (
    tester,
  ) async {
    await tester.pumpApp(
      summary(const [
        DawTrack(
          name: 'Track 4',
          deviceChainFallbackReason:
              DeviceChainFallbackReason.unrepresentedEffectType,
        ),
      ]),
    );
    final strings = await l10n();

    expect(
      find.text(strings.perfExportReasonUnrepresented),
      findsOneWidget,
    );
  });

  testWidgets('renders one row per track, in order', (tester) async {
    await tester.pumpApp(
      summary(const [
        DawTrack(name: 'Track A', deviceChain: []),
        DawTrack(name: 'Track B', deviceChain: []),
        DawTrack(name: 'Track C', deviceChain: []),
      ]),
    );

    expect(find.text('Track A'), findsOneWidget);
    expect(find.text('Track B'), findsOneWidget);
    expect(find.text('Track C'), findsOneWidget);
  });
}
