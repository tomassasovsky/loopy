import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/signal_graph/signal_fx_chrome.dart';
import 'package:loopy/looper/view/signal_graph/signal_fx_summary.dart';

import '../../../helpers/helpers.dart';

void main() {
  Widget summary({
    required List<TrackEffect> effects,
    VoidCallback? onEdit,
    bool chainEnabled = true,
    String? semanticLabel,
    ({String button, bool held})? stomp,
  }) => Scaffold(
    body: Center(
      child: SignalFxSummary(
        summaryKey: const Key('sum'),
        effects: effects,
        chainEnabled: chainEnabled,
        semanticLabel: semanticLabel,
        stomp: stomp,
        onEdit: onEdit ?? () {},
      ),
    ),
  );

  testWidgets('names each block and opens the editor on tap', (tester) async {
    var edited = false;
    await tester.pumpApp(
      summary(
        effects: [
          BuiltInEffect(type: TrackEffectType.drive),
          BuiltInEffect(type: TrackEffectType.reverb),
        ],
        onEdit: () => edited = true,
      ),
    );

    expect(find.text('Drive'), findsOneWidget);
    expect(find.text('Reverb'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sum')));
    expect(edited, isTrue);
  });

  testWidgets('an empty chain shows a No FX affordance that still edits', (
    tester,
  ) async {
    var edited = false;
    await tester.pumpApp(
      summary(effects: const [], onEdit: () => edited = true),
    );

    expect(find.text('No FX'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sum')));
    expect(edited, isTrue);
  });

  testWidgets('exposes an edit-FX button for a11y', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpApp(summary(effects: const []));

    final node = tester.getSemantics(find.byKey(const Key('sum')));
    expect(node, isSemantics(isButton: true));
    handle.dispose();
  });

  testWidgets('a powered-off entry strikes through its own chip', (
    tester,
  ) async {
    await tester.pumpApp(
      summary(
        effects: [
          BuiltInEffect(type: TrackEffectType.drive, enabled: false),
          BuiltInEffect(type: TrackEffectType.reverb),
        ],
      ),
    );

    Text chip(String label) => tester.widget<Text>(find.text(label));
    expect(chip('Drive').style?.decoration, TextDecoration.lineThrough);
    expect(chip('Reverb').style?.decoration, isNull);
  });

  testWidgets('a disabled chain marks the whole row off, not just dims it', (
    tester,
  ) async {
    await tester.pumpApp(
      summary(
        effects: [BuiltInEffect(type: TrackEffectType.drive)],
        chainEnabled: false,
      ),
    );

    // The state is spelled out, so it never rests on the dim alone.
    expect(find.text('Chain off'), findsOneWidget);
    // ...and every entry reads as silenced, even one whose own flag is on.
    expect(
      tester.widget<Text>(find.text('Drive')).style?.decoration,
      TextDecoration.lineThrough,
    );
  });

  testWidgets('an enabled chain shows no chain-off marker', (tester) async {
    await tester.pumpApp(
      summary(effects: [BuiltInEffect(type: TrackEffectType.drive)]),
    );
    expect(find.text('Chain off'), findsNothing);
  });

  testWidgets('an unavailable plugin flags itself on the overview row', (
    tester,
  ) async {
    await tester.pumpApp(
      summary(
        effects: [
          const PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: 'x', version: 1),
            name: 'Ghost',
            unavailable: true,
          ),
        ],
      ),
    );

    // err-1: the placeholder state is visible without opening the dock.
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(
      tester.widget<Tooltip>(find.byType(Tooltip)).message,
      'Plugin unavailable',
    );
  });

  testWidgets('an unsupported plugin says so, distinctly from missing', (
    tester,
  ) async {
    await tester.pumpApp(
      summary(
        effects: [
          const PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: 'x', version: 1),
            name: 'Ghost',
            unavailable: true,
            unsupported: true,
          ),
        ],
      ),
    );
    expect(
      tester.widget<Tooltip>(find.byType(Tooltip)).message,
      'Plugin unsupported',
    );
  });

  testWidgets('a still-scanning plugin reads as loading, not failed', (
    tester,
  ) async {
    await tester.pumpApp(
      summary(
        effects: [
          const PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: 'x', version: 1),
            name: 'Ghost',
            loading: true,
          ),
        ],
      ),
    );
    expect(find.byIcon(Icons.hourglass_empty), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  testWidgets('a stage row can name its own tap target', (tester) async {
    await tester.pumpApp(
      summary(
        effects: [BuiltInEffect(type: TrackEffectType.drive)],
        semanticLabel: 'Edit the master FX chain',
      ),
    );
    expect(
      tester.getSemantics(find.byKey(const Key('sum'))).label,
      contains('Edit the master FX chain'),
    );
  });

  testWidgets('an empty chain still says the chain is off', (tester) async {
    await tester.pumpApp(summary(effects: const [], chainEnabled: false));

    // The disabled flag persists independently of the entries, so without this
    // an empty disabled chain reads exactly like a never-touched one and
    // silently swallows the next effect added.
    expect(find.text('Chain off'), findsOneWidget);
    expect(find.text('No FX'), findsOneWidget);
  });

  testWidgets('an empty enabled chain shows no chain-off marker', (
    tester,
  ) async {
    await tester.pumpApp(summary(effects: const []));
    expect(find.text('Chain off'), findsNothing);
  });

  testWidgets('a silenced plugin keeps its warning glyph undimmed', (
    tester,
  ) async {
    await tester.pumpApp(
      summary(
        effects: [
          const PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: 'x', version: 1),
            name: 'Ghost',
            unavailable: true,
          ),
        ],
        chainEnabled: false,
      ),
    );
    await tester.pumpAndSettle();

    // The warning is what the user must act on, so it stays dominant over the
    // powered-off dim — matching the placeholder card's rule for this state.
    final dimmed = find.ancestor(
      of: find.byIcon(Icons.warning_amber_rounded),
      matching: find.byType(FxDisabledDim),
    );
    expect(dimmed, findsNothing);
  });

  group('stomp chip (part 6b)', () {
    testWidgets('is absent when no footswitch reaches the chain', (
      tester,
    ) async {
      await tester.pumpApp(summary(effects: const []));
      expect(find.byKey(const Key('stomp_chip_stop')), findsNothing);
    });

    testWidgets('names the bound footswitch', (tester) async {
      await tester.pumpApp(
        summary(
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
          stomp: (button: 'stop', held: false),
        ),
      );
      expect(find.byKey(const Key('stomp_chip_stop')), findsOneWidget);
      expect(find.text('Pedal \u00b7 STOP'), findsOneWidget);
    });

    testWidgets('marks a HELD momentary — the one FX state on this surface '
        'the user cannot undo by clicking', (tester) async {
      await tester.pumpApp(
        summary(
          effects: const [],
          stomp: (button: 'track1', held: true),
        ),
      );
      final chip = find.byKey(const Key('stomp_chip_track1'));
      expect(chip, findsOneWidget);
      expect(
        tester.getSemantics(chip).label,
        contains('held on'),
      );
    });

    testWidgets('rides alongside the chain-off marker rather than replacing '
        'it — bypassed AND pedal-reachable are independent facts', (
      tester,
    ) async {
      await tester.pumpApp(
        summary(
          effects: const [],
          chainEnabled: false,
          stomp: (button: 'stop', held: false),
        ),
      );
      expect(find.byKey(const Key('stomp_chip_stop')), findsOneWidget);
      expect(find.text('Chain off'), findsOneWidget);
    });
  });
}
