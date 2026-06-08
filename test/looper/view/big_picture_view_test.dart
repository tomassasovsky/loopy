import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/looper.dart';
import 'package:loopy/theme/theme.dart';
import 'package:loopy/ui_mode/ui_mode.dart';
import 'package:mocktail/mocktail.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockUiModeCubit extends MockCubit<UiMode> implements UiModeCubit {}

void main() {
  late LooperBloc bloc;
  late UiModeCubit uiMode;

  setUpAll(() => registerFallbackValue(UiMode.desktop));

  setUp(() {
    bloc = _MockLooperBloc();
    uiMode = _MockUiModeCubit();
    whenListen(
      uiMode,
      const Stream<UiMode>.empty(),
      initialState: UiMode.bigPicture,
    );
  });

  void seed(LooperState state) {
    when(() => bloc.state).thenReturn(state);
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
  }

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.bigPicture,
      home: MultiBlocProvider(
        providers: [
          BlocProvider<LooperBloc>.value(value: bloc),
          BlocProvider<UiModeCubit>.value(value: uiMode),
        ],
        child: const BigPictureView(),
      ),
    ),
  );

  testWidgets('renders a tile per track', (tester) async {
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    expect(find.byKey(const Key('bigpicture_tile_0')), findsOneWidget);
    expect(find.byKey(const Key('bigpicture_tile_1')), findsOneWidget);
  });

  testWidgets('tapping a tile records that channel', (tester) async {
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    await tester.tap(find.byKey(const Key('bigpicture_tile_1')));
    verify(() => bloc.add(const LooperRecordPressed(1))).called(1);
  });

  testWidgets('long-pressing a tile stops that channel', (tester) async {
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);

    await tester.longPress(find.byKey(const Key('bigpicture_tile_0')));
    verify(() => bloc.add(const LooperStopPressed(0))).called(1);
  });

  testWidgets('exit button returns to desktop mode', (tester) async {
    when(() => uiMode.setMode(any())).thenAnswer((_) async {});
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);

    await tester.tap(find.byKey(const Key('bigpicture_exit_button')));
    verify(() => uiMode.setMode(UiMode.desktop)).called(1);
  });
}
