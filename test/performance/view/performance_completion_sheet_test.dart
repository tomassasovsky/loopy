import 'package:bloc_test/bloc_test.dart';
import 'package:daw_export/daw_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/performance/cubit/performance_recorder_cubit.dart';
import 'package:loopy/performance/view/performance_completion_sheet.dart';
import 'package:mocktail/mocktail.dart';
import 'package:performance_repository/performance_repository.dart';

import '../../helpers/helpers.dart';

class _MockPerformanceRecorderCubit extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

void main() {
  late _MockPerformanceRecorderCubit cubit;

  setUp(() {
    cubit = _MockPerformanceRecorderCubit();
  });

  Future<void> pump(WidgetTester tester, PerformanceRecorderState state) async {
    whenListen(
      cubit,
      const Stream<PerformanceRecorderState>.empty(),
      initialState: state,
    );
    await tester.pumpApp(
      BlocProvider<PerformanceRecorderCubit>.value(
        value: cubit,
        child: const Scaffold(body: PerformanceCompletionSheet()),
      ),
    );
  }

  Future<AppLocalizations> l10n() =>
      AppLocalizations.delegate.load(const Locale('en'));

  testWidgets('renders nothing when not Completed', (tester) async {
    await pump(tester, const PerformanceRecorderIdle());
    expect(find.byKey(const Key('perfCompletion_sheet')), findsNothing);
  });

  testWidgets('renders nothing for a discarded-short completion (no result)', (
    tester,
  ) async {
    await pump(tester, const PerformanceRecorderCompleted.discardedShort());
    expect(find.byKey(const Key('perfCompletion_sheet')), findsNothing);
  });

  testWidgets('a Done result shows no extra message, just the path', (
    tester,
  ) async {
    await pump(
      tester,
      const PerformanceRecorderCompleted(
        PerformanceRecordDone('/exports/perf-1'),
      ),
    );

    expect(find.byKey(const Key('perfCompletion_sheet')), findsOneWidget);
    expect(find.text('perf-1'), findsOneWidget);
  });

  testWidgets('a Partial result shows the partial-failure message', (
    tester,
  ) async {
    await pump(
      tester,
      const PerformanceRecorderCompleted(
        PerformanceRecordPartial('/exports/perf-2'),
      ),
    );
    final strings = await l10n();

    expect(find.text(strings.perfPartial), findsOneWidget);
  });

  testWidgets('a StoppedEarly/diskFull result shows the disk-full message', (
    tester,
  ) async {
    await pump(
      tester,
      const PerformanceRecorderCompleted(
        PerformanceRecordStoppedEarly(
          '/exports/perf-3',
          PerformanceStopReason.diskFull,
        ),
      ),
    );
    final strings = await l10n();

    expect(find.text(strings.perfStoppedDiskFull), findsOneWidget);
  });

  testWidgets(
    'a StoppedEarly/deviceChanged result shows the device-change message',
    (tester) async {
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordStoppedEarly(
            '/exports/perf-4',
            PerformanceStopReason.deviceChanged,
          ),
        ),
      );
      final strings = await l10n();

      expect(find.text(strings.perfStoppedDeviceChange), findsOneWidget);
    },
  );

  testWidgets('the reveal button is present with a non-empty label', (
    tester,
  ) async {
    await pump(
      tester,
      const PerformanceRecorderCompleted(
        PerformanceRecordDone('/exports/perf-1'),
      ),
    );

    final reveal = tester.widget<TextButton>(
      find.byKey(const Key('perfCompletion_reveal')),
    );
    expect(find.byKey(const Key('perfCompletion_reveal')), findsOneWidget);
    expect(reveal.onPressed, isNotNull);
    // Portable across host platforms: assert SOME localized label renders
    // rather than pinning the exact macOS/Windows/other string.
    final labelFinder = find.descendant(
      of: find.byKey(const Key('perfCompletion_reveal')),
      matching: find.byType(Text),
    );
    final label = tester.widget<Text>(labelFinder).data;
    expect(label, isNotNull);
    expect(label, isNotEmpty);
  });

  testWidgets('the rename button opens the rename dialog', (tester) async {
    await pump(
      tester,
      const PerformanceRecorderCompleted(
        PerformanceRecordDone('/exports/perf-1'),
      ),
    );

    await tester.tap(find.byKey(const Key('perfCompletion_rename')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('perfRename_field')), findsOneWidget);
  });

  testWidgets(
    'submitting a valid name in the rename dialog calls '
    'renameCompletedCapture',
    (tester) async {
      when(
        () => cubit.renameCompletedCapture(any()),
      ).thenAnswer((_) async {});
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
        ),
      );

      await tester.tap(find.byKey(const Key('perfCompletion_rename')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('perfRename_field')),
        'My Take',
      );
      await tester.tap(find.byKey(const Key('perfRename_save')));
      await tester.pumpAndSettle();

      verify(() => cubit.renameCompletedCapture('My Take')).called(1);
    },
  );

  testWidgets(
    'a PerformanceNameCollision thrown by the cubit shows a SnackBar with '
    'the duplicate message',
    (tester) async {
      when(
        () => cubit.renameCompletedCapture(any()),
      ).thenThrow(const PerformanceNameCollision(slug: 'Taken'));
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
        ),
      );
      final strings = await l10n();

      await tester.tap(find.byKey(const Key('perfCompletion_rename')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('perfRename_field')),
        'Taken',
      );
      await tester.tap(find.byKey(const Key('perfRename_save')));
      await tester.pumpAndSettle();

      expect(find.text(strings.perfRenameDuplicate('Taken')), findsOneWidget);
    },
  );

  testWidgets(
    'no export summary is shown when the completed state has no tracks',
    (tester) async {
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
        ),
      );
      expect(find.byKey(const Key('exportSummary')), findsNothing);
    },
  );

  testWidgets(
    'a live-plugin track shows its name and the live-plugins label',
    (tester) async {
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
          tracks: [
            DawTrack(
              name: 'Track 0',
              deviceChain: [
                DawEffect(type: 3, params: [0.35, 0.35, 0.35, 0.0]),
              ],
            ),
          ],
        ),
      );
      final strings = await l10n();

      expect(find.byKey(const Key('exportSummary')), findsOneWidget);
      expect(find.text('Track 0'), findsOneWidget);
      expect(find.text(strings.perfExportTrackLive), findsOneWidget);
    },
  );

  testWidgets(
    'a bounced track with a fallback reason shows the bounced label and '
    'the specific reason',
    (tester) async {
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
          tracks: [
            DawTrack(
              name: 'Track 1',
              deviceChainFallbackReason:
                  DeviceChainFallbackReason.mixedLaneChains,
            ),
          ],
        ),
      );
      final strings = await l10n();

      expect(find.text(strings.perfExportTrackBounced), findsOneWidget);
      expect(find.text(strings.perfExportReasonMixedLanes), findsOneWidget);
    },
  );

  testWidgets(
    'a bounced track with no effects at all shows no fallback callout',
    (tester) async {
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
          tracks: [DawTrack(name: 'Track 2', deviceChain: [])],
        ),
      );
      final strings = await l10n();

      expect(find.text(strings.perfExportTrackBounced), findsOneWidget);
      expect(find.text(strings.perfExportReasonMixedLanes), findsNothing);
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

  testWidgets('the re-export button calls cubit.reExport when tapped', (
    tester,
  ) async {
    when(() => cubit.reExport()).thenAnswer((_) async {});
    await pump(
      tester,
      const PerformanceRecorderCompleted(
        PerformanceRecordDone('/exports/perf-1'),
      ),
    );

    await tester.tap(find.byKey(const Key('perfCompletion_reExport')));
    await tester.pumpAndSettle();

    verify(() => cubit.reExport()).called(1);
  });

  testWidgets(
    'the re-export button is disabled while a re-export is in progress',
    (tester) async {
      await pump(
        tester,
        const PerformanceRecorderCompleted(
          PerformanceRecordDone('/exports/perf-1'),
          isReExporting: true,
        ),
      );

      final button = tester.widget<TextButton>(
        find.byKey(const Key('perfCompletion_reExport')),
      );
      expect(button.onPressed, isNull);
    },
  );

  testWidgets('a failed re-export shows the failure message', (
    tester,
  ) async {
    await pump(
      tester,
      const PerformanceRecorderCompleted(
        PerformanceRecordDone('/exports/perf-1'),
        reExportFailed: true,
      ),
    );
    final strings = await l10n();

    expect(find.text(strings.perfExportReExportFailed), findsOneWidget);
  });
}
