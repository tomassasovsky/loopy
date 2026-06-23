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
