import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/fx_editor/fx_block_chip.dart';

import '../../../helpers/helpers.dart';

void main() {
  Widget chip({
    required TrackEffect effect,
    bool selected = false,
    VoidCallback? onTap,
  }) => Scaffold(
    body: Center(
      child: FxBlockChip(
        chipKey: const Key('chip'),
        effect: effect,
        selected: selected,
        onTap: onTap ?? () {},
      ),
    ),
  );

  testWidgets('names a built-in effect and taps to select', (tester) async {
    var tapped = false;
    await tester.pumpApp(
      chip(
        effect: BuiltInEffect(type: TrackEffectType.reverb),
        onTap: () => tapped = true,
      ),
    );

    expect(find.text('Reverb'), findsOneWidget);
    await tester.tap(find.byKey(const Key('chip')));
    expect(tapped, isTrue);
  });

  testWidgets('an unavailable plugin shows a warning glyph', (tester) async {
    await tester.pumpApp(
      chip(
        effect: const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'abc'),
          name: 'Comp',
          unavailable: true,
        ),
      ),
    );

    expect(find.text('Comp'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('a version-drifted plugin shows an info glyph', (tester) async {
    await tester.pumpApp(
      chip(
        effect: const PluginEffect(
          ref: PluginRef(format: PluginFormat.clap, id: 'v'),
          name: 'Verb',
          versionChanged: true,
        ),
      ),
    );

    expect(find.byIcon(Icons.info_outline), findsOneWidget);
  });

  testWidgets('exposes selected + button semantics', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpApp(
      chip(effect: BuiltInEffect(type: TrackEffectType.drive), selected: true),
    );

    final node = tester.getSemantics(find.byKey(const Key('chip')));
    expect(node, isSemantics(isSelected: true, isButton: true));
    handle.dispose();
  });
}
