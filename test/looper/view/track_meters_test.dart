import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/control/control.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/looper/view/track_meters.dart';
import 'package:loopy/theme/theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late LooperBloc bloc;
  late TracksCubit tracks;
  late ControlCubit control;

  setUp(() {
    final settings = SettingsRepository(store: FakeKeyValueStore());
    bloc = _MockLooperBloc();
    tracks = TracksCubit(settings: settings);
    final looper = _MockLooperRepository();
    when(
      () => looper.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    // The row reads the mode / cursor / bank from the shared control cubit.
    final pedalRepo = PedalRepository(const NoopPedalTransport());
    addTearDown(pedalRepo.dispose);
    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    control = ControlCubit(
      looper: looper,
      pedal: pedalRepo,
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
    );
    addTearDown(control.close);
  });

  void seed(LooperState state) {
    when(() => bloc.state).thenReturn(state);
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
  }

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.neon,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MultiBlocProvider(
        providers: [
          BlocProvider<LooperBloc>.value(value: bloc),
          BlocProvider<TracksCubit>.value(value: tracks),
          BlocProvider<ControlCubit>.value(value: control),
        ],
        child: const Scaffold(body: TrackMeterRow()),
      ),
    ),
  );

  Color borderColor(WidgetTester tester, int channel) {
    final container = tester.widget<Container>(
      find.byKey(Key('pedalScreen_bar_$channel')),
    );
    return ((container.decoration! as BoxDecoration).border! as Border)
        .top
        .color;
  }

  testWidgets('renders a bar only for the active bank tracks', (tester) async {
    seed(LooperState(tracks: [for (var i = 0; i < 8; i++) Track(channel: i)]));
    await pump(tester);

    // Bank A: channels 0..3 render; 4..7 do not.
    for (var c = 0; c < 4; c++) {
      expect(find.byKey(Key('pedalScreen_bar_$c')), findsOneWidget);
    }
    expect(find.byKey(const Key('pedalScreen_bar_4')), findsNothing);
  });

  testWidgets('the selected track bar has a white border', (tester) async {
    seed(LooperState(tracks: [for (var i = 0; i < 4; i++) Track(channel: i)]));
    control.selectTrack(1);
    await pump(tester);

    expect(borderColor(tester, 1), Colors.white);
    expect(borderColor(tester, 0), Colors.transparent);
  });
}
