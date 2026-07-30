import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/audio_setup/cubit/monitor_cubit.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/bloc/looper_bloc.dart';
import 'package:loopy/looper/view/fx_editor/fx_dock.dart';
import 'package:loopy/looper/view/fx_editor/fx_scope.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

/// A scope the test drives directly, so the dock's chrome is exercised without
/// standing up a whole bloc/cubit graph behind each stage.
class _FakeScope extends FxScope {
  _FakeScope({
    this.effects = const [],
    this.chainEnabled = true,
    this.inheritedFrom = const [],
    this.canResyncFromInput = false,
    this.overdubMismatch = false,
    this.isPresent = true,
  });

  @override
  FxAddress get address => const FxAddress(stage: FxStage.loop);

  @override
  List<TrackEffect> effects;

  @override
  bool chainEnabled;

  @override
  List<int> inheritedFrom;

  @override
  bool canResyncFromInput;

  @override
  bool overdubMismatch;

  @override
  bool isPresent;

  final List<bool> chainToggles = [];
  final List<(int, bool)> slotToggles = [];
  int resyncs = 0;

  @override
  String label(AppLocalizations l10n) => 'Lane 1';

  @override
  String consequence(AppLocalizations l10n) => l10n.fxEditorLaneConsequence;

  @override
  String chainDisabledConsequence(AppLocalizations l10n) =>
      l10n.fxChainOffLoopConsequence;

  @override
  void setChainEnabled({required bool enabled}) => chainToggles.add(enabled);

  @override
  void setEffectEnabled(int index, {required bool enabled}) =>
      slotToggles.add((index, enabled));

  @override
  void resyncFromInput() => resyncs++;

  @override
  void addEffect() {}

  @override
  void insertPlugin(PluginRef ref) {}

  @override
  void removeEffect(int index) {}

  @override
  void moveEffect(int from, int to) {}

  @override
  void setType(int index, TrackEffectType type) {}

  @override
  void setParam(int index, int param, double value) {}

  @override
  void setPluginParam(int index, int paramId, double value) {}

  @override
  void openPluginEditor(int index) {}

  @override
  void relinkPlugin(int index, PluginRef ref) {}

  @override
  String? formatPluginValue(int index, int paramId, double value) => null;
}

void main() {
  group('FxDock', () {
    late LooperBloc bloc;
    late MonitorCubit monitor;
    late LooperRepository repository;
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    setUp(() {
      bloc = _MockLooperBloc();
      whenListen(
        bloc,
        const Stream<LooperState>.empty(),
        initialState: const LooperState(),
      );
      repository = LooperRepository(
        engine: FakeAudioEngine(),
        ticker: const Stream<void>.empty(),
      );
      monitor = MonitorCubit(
        repository: repository,
        settings: SettingsRepository(store: FakeKeyValueStore()),
      );
    });

    tearDown(() => repository.dispose());

    Future<void> pump(WidgetTester tester, _FakeScope scope) async {
      tester.view
        ..physicalSize = const Size(1000, 700)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpApp(
        MultiBlocProvider(
          providers: [
            BlocProvider<LooperBloc>.value(value: bloc),
            BlocProvider<MonitorCubit>.value(value: monitor),
          ],
          child: Scaffold(
            body: FxDock(scope: scope, onClose: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the chain power control turns the whole chain off', (
      tester,
    ) async {
      final scope = _FakeScope(
        effects: [BuiltInEffect(type: TrackEffectType.drive)],
      );
      await pump(tester, scope);

      await tester.tap(find.byKey(const Key('fxDock_chainPower')));
      await tester.pump();

      expect(scope.chainToggles, [false]);
    });

    testWidgets('a disabled chain toggles back on', (tester) async {
      final scope = _FakeScope(chainEnabled: false);
      await pump(tester, scope);

      await tester.tap(find.byKey(const Key('fxDock_chainPower')));
      await tester.pump();

      expect(scope.chainToggles, [true]);
    });

    testWidgets('the consequence line switches to what silence costs', (
      tester,
    ) async {
      await pump(tester, _FakeScope());
      expect(
        tester.widget<Text>(find.byKey(const Key('fxDock_consequence'))).data,
        l10n.fxEditorLaneConsequence,
      );

      await pump(tester, _FakeScope(chainEnabled: false));
      expect(
        tester.widget<Text>(find.byKey(const Key('fxDock_consequence'))).data,
        l10n.fxChainOffLoopConsequence,
      );
    });

    testWidgets('the chain power control announces its state', (tester) async {
      await pump(tester, _FakeScope());
      final on = tester.getSemantics(
        find.byKey(const Key('fxDock_chainPower')),
      );
      expect(on.label, contains(l10n.a11yFxChainOn));

      await pump(tester, _FakeScope(chainEnabled: false));
      final off = tester.getSemantics(
        find.byKey(const Key('fxDock_chainPower')),
      );
      expect(off.label, contains(l10n.a11yFxChainOff));
    });

    testWidgets('a card power control routes to the scope per slot', (
      tester,
    ) async {
      final scope = _FakeScope(
        effects: [
          BuiltInEffect(type: TrackEffectType.drive),
          BuiltInEffect(type: TrackEffectType.reverb),
        ],
      );
      await pump(tester, scope);

      await tester.tap(find.byKey(const Key('fxDock_device_1_power')));
      await tester.pump();

      expect(scope.slotToggles, [(1, false)]);
    });

    testWidgets('an inherited chain shows its provenance badge', (
      tester,
    ) async {
      await pump(tester, _FakeScope(inheritedFrom: [1]));

      expect(find.byKey(const Key('fxDock_inherited')), findsOneWidget);
      expect(
        tester.widget<Tooltip>(find.byType(Tooltip).first).message,
        l10n.signalInheritedFrom(l10n.inputChannelLabel(2)),
      );
    });

    testWidgets('a detached chain shows no badge', (tester) async {
      await pump(tester, _FakeScope());
      expect(find.byKey(const Key('fxDock_inherited')), findsNothing);
    });

    testWidgets('re-sync is offered only when there is something to copy', (
      tester,
    ) async {
      await pump(tester, _FakeScope());
      expect(find.byKey(const Key('fxDock_resync')), findsNothing);

      final scope = _FakeScope(canResyncFromInput: true);
      await pump(tester, scope);
      await tester.tap(find.byKey(const Key('fxDock_resync')));
      await tester.pump();

      expect(scope.resyncs, 1);
    });

    testWidgets('the overdub hint shows only during a mismatch', (
      tester,
    ) async {
      await pump(tester, _FakeScope());
      expect(find.byKey(const Key('fxDock_overdubHint')), findsNothing);

      await pump(tester, _FakeScope(overdubMismatch: true));
      expect(find.byKey(const Key('fxDock_overdubHint')), findsOneWidget);
      expect(find.text(l10n.fxOverdubMismatchHint), findsOneWidget);
    });

    testWidgets('a vanished target withdraws its chain power control', (
      tester,
    ) async {
      // The header outlives the chain body, but a chain whose target is gone
      // has nothing to switch — writing through it would mint a phantom
      // monitor and persist a key that returns on the next boot.
      await pump(tester, _FakeScope(isPresent: false));

      expect(find.byKey(const Key('fxDock_gone')), findsOneWidget);
      expect(find.byKey(const Key('fxDock_chainPower')), findsNothing);
    });
  });
}
