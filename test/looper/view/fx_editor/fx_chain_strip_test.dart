import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/fx_editor/fx_chain_strip.dart';

import '../../../helpers/helpers.dart';

void main() {
  List<TrackEffect> chain(int n) => [
    for (var i = 0; i < n; i++)
      BuiltInEffect(
        type: i.isEven ? TrackEffectType.drive : TrackEffectType.reverb,
      ),
  ];

  Widget strip({
    required List<TrackEffect> effects,
    int? selectedIndex,
    bool canAdd = true,
    ValueChanged<int>? onSelect,
    void Function(int from, int to)? onReorder,
    VoidCallback? onAddEffect,
    VoidCallback? onAddPlugin,
  }) => Scaffold(
    body: FxChainStrip(
      effects: effects,
      selectedIndex: selectedIndex,
      canAdd: canAdd,
      onSelect: onSelect ?? (_) {},
      onReorder: onReorder ?? (_, _) {},
      onAddEffect: onAddEffect ?? () {},
      onAddPlugin: onAddPlugin ?? () {},
    ),
  );

  testWidgets('renders IN / OUT terminals and a block per entry', (
    tester,
  ) async {
    await tester.pumpApp(strip(effects: chain(2)));

    expect(find.text('IN'), findsOneWidget);
    expect(find.text('OUT'), findsOneWidget);
    expect(find.byKey(const Key('fxChain_block_0')), findsOneWidget);
    expect(find.byKey(const Key('fxChain_block_1')), findsOneWidget);
  });

  testWidgets('tapping a block selects it', (tester) async {
    int? selected;
    await tester.pumpApp(
      strip(effects: chain(2), onSelect: (i) => selected = i),
    );

    await tester.tap(find.byKey(const Key('fxChain_block_1')));
    expect(selected, 1);
  });

  testWidgets('the "+" adds a built-in effect via its menu', (tester) async {
    var added = false;
    await tester.pumpApp(
      strip(effects: chain(1), onAddEffect: () => added = true),
    );

    await tester.tap(find.byKey(const Key('fxChain_add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add effect'));
    await tester.pumpAndSettle();
    expect(added, isTrue);
  });

  testWidgets('the "+" is disabled at the chain cap', (tester) async {
    await tester.pumpApp(strip(effects: chain(1), canAdd: false));

    final button = tester.widget<PopupMenuButton<Object?>>(
      find.byKey(const Key('fxChain_add')),
    );
    expect(button.enabled, isFalse);
  });

  testWidgets('a long-press drag reorders through onReorder', (tester) async {
    final moves = <(int, int)>[];
    await tester.pumpApp(
      strip(effects: chain(2), onReorder: (f, t) => moves.add((f, t))),
    );

    // Lift block 0 and drop it on the gap after the last block (index 2):
    // _reorderTo(0, 2) normalises to moveEffect(0, 1).
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('fxChain_block_0'))),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(
      tester.getCenter(find.byKey(const Key('fxChain_drop_2'))),
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(moves, contains((0, 1)));
  });
}
