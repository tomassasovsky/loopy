import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/looper/view/signal_graph/plugin_browser.dart';

import '../../../helpers/helpers.dart';

void main() {
  group('plugin browser', () {
    // A repository whose mock engine scans to a fixed set: one VST3, one CLAP,
    // and one failed entry (empty id) that must be filtered out.
    LooperRepository buildRepo() =>
        LooperRepository(engine: createMockEngine().engine);

    Widget host(
      LooperRepository repo,
      void Function(PluginDescriptor?) onPicked,
    ) => RepositoryProvider<LooperRepository>.value(
      value: repo,
      child: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async => onPicked(await showPluginBrowser(context)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    testWidgets('lists scanned plugins, filters failed, returns the pick', (
      tester,
    ) async {
      final repo = buildRepo();
      addTearDown(repo.dispose);
      // Pre-scan so the dialog shows results without waiting on the poll timer.
      await tester.runAsync(() => repo.pluginCatalog.scan());

      PluginDescriptor? picked;
      await tester.pumpApp(host(repo, (p) => picked = p));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Mock Reverb'), findsOneWidget); // VST3
      expect(find.text('Mock Delay'), findsOneWidget); // CLAP
      expect(find.text('Broken Plugin.clap'), findsNothing); // failed entry
      expect(find.text('VST3'), findsOneWidget);
      expect(find.text('CLAP'), findsOneWidget);

      // The search field filters by name.
      await tester.enterText(
        find.byKey(const Key('pluginBrowser_search')),
        'delay',
      );
      await tester.pumpAndSettle();
      expect(find.text('Mock Reverb'), findsNothing);
      expect(find.text('Mock Delay'), findsOneWidget);

      await tester.tap(find.text('Mock Delay'));
      await tester.pumpAndSettle();
      expect(picked?.name, 'Mock Delay');
      expect(picked?.format, PluginFormat.clap);
    });

    testWidgets('Cancel stops an in-progress scan', (tester) async {
      final repo = buildRepo();
      addTearDown(repo.dispose);
      // Don't pre-scan: the dialog kicks off its own scan on open and shows a
      // Cancel control until the poll completes.
      await tester.pumpApp(host(repo, (_) {}));
      await tester.tap(find.text('open'));
      // Advance the dialog transition but stay under the catalog's 100ms poll,
      // so the scan is still in flight and the Cancel control is shown.
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byKey(const Key('pluginBrowser_cancel')), findsOneWidget);

      await tester.tap(find.byKey(const Key('pluginBrowser_cancel')));
      await tester.pumpAndSettle();
      // The scan stopped: the Cancel control is gone (back to a settled state).
      expect(find.byKey(const Key('pluginBrowser_cancel')), findsNothing);
    });

    testWidgets('closing the browser resolves to null', (tester) async {
      final repo = buildRepo();
      addTearDown(repo.dispose);
      await tester.runAsync(() => repo.pluginCatalog.scan());

      var completed = false;
      PluginDescriptor? picked;
      await tester.pumpApp(
        host(repo, (p) {
          completed = true;
          picked = p;
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pluginBrowser_close')));
      await tester.pumpAndSettle();

      expect(completed, isTrue);
      expect(picked, isNull);
    });
  });
}
