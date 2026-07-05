import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/fx_editor/fx_inspector.dart';

import '../../../helpers/helpers.dart';

void main() {
  Widget inspector({
    required TrackEffect? effect,
    String emptyHint = 'nothing selected',
    void Function(TrackEffectType type)? onSetType,
    void Function(int param, double value)? onSetParam,
    void Function(int paramId, double value)? onSetPluginParam,
    VoidCallback? onOpenEditor,
    VoidCallback? onRelink,
    VoidCallback? onRemove,
  }) => Scaffold(
    body: FxInspector(
      effect: effect,
      emptyHint: emptyHint,
      onSetType: onSetType ?? (_) {},
      onSetParam: onSetParam ?? (_, _) {},
      onSetPluginParam: onSetPluginParam ?? (_, _) {},
      onOpenEditor: onOpenEditor ?? () {},
      onRelink: onRelink ?? () {},
      onRemove: onRemove ?? () {},
      onFormatPluginValue: (_, _) => null,
    ),
  );

  testWidgets('nothing selected shows the empty hint', (tester) async {
    await tester.pumpApp(inspector(effect: null, emptyHint: 'pick a block'));

    expect(find.byKey(const Key('fxInspector_empty')), findsOneWidget);
    expect(find.text('pick a block'), findsOneWidget);
  });

  testWidgets('a built-in effect renders one slider per param', (tester) async {
    await tester.pumpApp(
      inspector(effect: BuiltInEffect(type: TrackEffectType.delay)),
    );

    // Delay exposes several params; each renders exactly one slider.
    final params = TrackEffectType.delay.params.length;
    expect(find.byType(Slider), findsNWidgets(params));
    expect(find.byKey(const Key('fxInspector_param_0')), findsOneWidget);
  });

  testWidgets('changing a built-in slider fires onSetParam', (tester) async {
    final calls = <(int, double)>[];
    await tester.pumpApp(
      inspector(
        effect: BuiltInEffect(type: TrackEffectType.drive),
        onSetParam: (p, v) => calls.add((p, v)),
      ),
    );

    await tester.drag(
      find.byKey(const Key('fxInspector_param_0')),
      const Offset(150, 0),
    );
    expect(calls, isNotEmpty);
    expect(calls.first.$1, 0);
  });

  testWidgets('retyping a built-in block fires onSetType', (tester) async {
    TrackEffectType? picked;
    await tester.pumpApp(
      inspector(
        effect: BuiltInEffect(type: TrackEffectType.drive),
        onSetType: (t) => picked = t,
      ),
    );

    await tester.tap(find.byKey(const Key('fxInspector_type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reverb').last);
    await tester.pumpAndSettle();
    expect(picked, TrackEffectType.reverb);
  });

  testWidgets('a plugin block offers no type picker', (tester) async {
    await tester.pumpApp(
      inspector(
        effect: const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'p'),
          name: 'Comp',
        ),
      ),
    );

    expect(find.byKey(const Key('fxInspector_type')), findsNothing);
  });

  testWidgets('the remove action fires onRemove', (tester) async {
    var removed = false;
    await tester.pumpApp(
      inspector(
        effect: BuiltInEffect(type: TrackEffectType.drive),
        onRemove: () => removed = true,
      ),
    );

    await tester.tap(find.byKey(const Key('fxInspector_remove')));
    expect(removed, isTrue);
  });

  testWidgets('an available plugin shows its params and Open Editor', (
    tester,
  ) async {
    var opened = false;
    await tester.pumpApp(
      inspector(
        effect: const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'p'),
          name: 'Comp',
          params: [
            PluginParamInfo(
              id: 3,
              name: 'Ratio',
              unit: '',
              min: 1,
              max: 10,
              def: 2,
              stepCount: 0,
              flags: 0x01,
            ),
          ],
        ),
        onOpenEditor: () => opened = true,
      ),
    );

    expect(find.byKey(const Key('fxInspector_param_3')), findsOneWidget);
    await tester.tap(find.byKey(const Key('fxInspector_openEditor')));
    expect(opened, isTrue);
  });

  testWidgets('an unavailable plugin shows a relink placeholder', (
    tester,
  ) async {
    var relinked = false;
    await tester.pumpApp(
      inspector(
        effect: const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'p'),
          name: 'Ghost',
          unavailable: true,
        ),
        onRelink: () => relinked = true,
      ),
    );

    expect(find.byKey(const Key('fxInspector_reason')), findsOneWidget);
    expect(find.text('Plugin unavailable'), findsOneWidget);
    // No live params for an unresolved plugin.
    expect(find.byType(Slider), findsNothing);

    await tester.tap(find.byKey(const Key('fxInspector_relink')));
    expect(relinked, isTrue);
  });

  testWidgets('a rejected plugin shows the unsupported message', (
    tester,
  ) async {
    await tester.pumpApp(
      inspector(
        effect: const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'p'),
          name: 'Synth',
          unavailable: true,
          unsupported: true,
        ),
      ),
    );

    expect(find.text('Plugin unsupported'), findsOneWidget);
  });

  testWidgets('a version-drifted plugin still edits, with a note', (
    tester,
  ) async {
    await tester.pumpApp(
      inspector(
        effect: const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'p'),
          name: 'Verb',
          versionChanged: true,
          params: [
            PluginParamInfo(
              id: 1,
              name: 'Size',
              unit: '',
              min: 0,
              max: 1,
              def: 0.5,
              stepCount: 0,
              flags: 0x01,
            ),
          ],
        ),
      ),
    );

    expect(find.byKey(const Key('fxInspector_versionChanged')), findsOneWidget);
    expect(find.byKey(const Key('fxInspector_param_1')), findsOneWidget);
  });
}
