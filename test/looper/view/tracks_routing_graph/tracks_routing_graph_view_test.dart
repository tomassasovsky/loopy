import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/view/tracks_routing_graph/tracks_routing_graph_view.dart';
import 'package:loopy/theme/theme.dart';

void main() {
  group('TracksRoutingGraphView', () {
    Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.bigPicture,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );

    testWidgets('renders a CustomPaint for the diagram', (tester) async {
      await pump(
        tester,
        const TracksRoutingGraphView(
          tracks: [Track()],
          inputChannels: 2,
          outputChannels: 2,
        ),
      );

      expect(find.byKey(const Key('routingGraph_view')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('routingGraph_view')),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
    });

    testWidgets('paints a diagram with an excluded loopback input', (
      tester,
    ) async {
      // Exercises the dimmed/struck-through excluded-node paint path.
      await pump(
        tester,
        const TracksRoutingGraphView(
          tracks: [Track()],
          inputChannels: 4,
          outputChannels: 2,
          excludedInputMask: 0x8, // input 4 is loopback
        ),
      );

      expect(find.byKey(const Key('routingGraph_view')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a routing node is a labelled, focusable button (a11y)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        TracksRoutingGraphView(
          tracks: const [Track()],
          inputChannels: 2,
          outputChannels: 2,
          onInputMaskChanged: (_, _) {},
        ),
      );

      final node = tester.getSemantics(
        find.byKey(const Key('routingNode_track_0')),
      );
      expect(node, isSemantics(isButton: true, hasTapAction: true));
      expect(node.label, isNotEmpty);
      handle.dispose();
    });

    testWidgets('arm a track then click an input to connect it', (
      tester,
    ) async {
      int? channel;
      int? mask;
      await pump(
        tester,
        TracksRoutingGraphView(
          tracks: const [Track()], // inputMask 0x1
          inputChannels: 2,
          outputChannels: 2,
          onInputMaskChanged: (c, m) {
            channel = c;
            mask = m;
          },
        ),
      );

      // Clicking a channel before arming a track does nothing.
      await tester.tap(find.byKey(const Key('routingNode_input_1')));
      await tester.pump();
      expect(channel, isNull);

      // Arm the track, then click input 2 (bit 1) to add it.
      await tester.tap(find.byKey(const Key('routingNode_track_0')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('routingNode_input_1')));
      await tester.pump();

      expect(channel, 0);
      expect(mask, 0x3); // 0x1 | (1 << 1)
    });

    testWidgets('clicking an already-connected channel disconnects it', (
      tester,
    ) async {
      int? mask;
      await pump(
        tester,
        TracksRoutingGraphView(
          tracks: const [Track()], // inputMask 0x1 (input 1 wired)
          inputChannels: 2,
          outputChannels: 2,
          onInputMaskChanged: (_, m) => mask = m,
        ),
      );

      await tester.tap(find.byKey(const Key('routingNode_track_0')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('routingNode_input_0')));
      await tester.pump();

      expect(mask, 0x0); // 0x1 & ~(1 << 0)
    });

    testWidgets('arm a track then click an output toggles its output', (
      tester,
    ) async {
      int? channel;
      int? mask;
      await pump(
        tester,
        TracksRoutingGraphView(
          tracks: const [Track()], // outputMask 0x3 (out 1 & 2)
          inputChannels: 2,
          outputChannels: 2,
          onOutputMaskChanged: (c, m) {
            channel = c;
            mask = m;
          },
        ),
      );

      await tester.tap(find.byKey(const Key('routingNode_track_0')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('routingNode_output_1')));
      await tester.pump();

      expect(channel, 0);
      expect(mask, 0x1); // 0x3 & ~(1 << 1)
    });

    testWidgets('a loopback input is not clickable', (tester) async {
      var called = false;
      await pump(
        tester,
        TracksRoutingGraphView(
          tracks: const [Track()],
          inputChannels: 2,
          outputChannels: 2,
          excludedInputMask: 0x2, // input 2 is loopback
          onInputMaskChanged: (_, _) => called = true,
        ),
      );

      await tester.tap(find.byKey(const Key('routingNode_track_0')));
      await tester.pump();
      // The excluded input has no tappable node key.
      expect(find.byKey(const Key('routingNode_input_1')), findsNothing);
      await tester.tap(find.byKey(const Key('routingNode_input_0')));
      await tester.pump();
      // Input 1 (not loopback) still works; the loopback one never fires.
      expect(called, isTrue);
    });

    testWidgets('read-only graph exposes no interactive node keys', (
      tester,
    ) async {
      await pump(
        tester,
        const TracksRoutingGraphView(
          tracks: [Track()],
          inputChannels: 2,
          outputChannels: 2,
        ),
      );

      expect(find.byKey(const Key('routingNode_track_0')), findsNothing);
    });

    group('structural output gate', () {
      testWidgets('tapping a live output with nothing armed disables it', (
        tester,
      ) async {
        int? toggledOutput;
        bool? toggledEnabled;
        await pump(
          tester,
          TracksRoutingGraphView(
            tracks: const [Track()],
            inputChannels: 2,
            outputChannels: 2,
            onOutputEnabledToggled: (output, {required enabled}) {
              toggledOutput = output;
              toggledEnabled = enabled;
            },
          ),
        );

        await tester.tap(find.byKey(const Key('routingNode_output_1')));
        await tester.pumpAndSettle();
        expect(toggledOutput, 1);
        expect(toggledEnabled, isFalse); // a live output toggles OFF
      });

      testWidgets('tapping a gated-off (greyed) output re-enables it', (
        tester,
      ) async {
        int? toggledOutput;
        bool? toggledEnabled;
        await pump(
          tester,
          TracksRoutingGraphView(
            tracks: const [Track()],
            inputChannels: 2,
            outputChannels: 2,
            outputEnabledMask: 0x1, // output 1 is gated off
            onOutputEnabledToggled: (output, {required enabled}) {
              toggledOutput = output;
              toggledEnabled = enabled;
            },
          ),
        );

        await tester.tap(find.byKey(const Key('routingNode_output_1')));
        await tester.pumpAndSettle();
        expect(toggledOutput, 1);
        expect(toggledEnabled, isTrue); // a disabled output toggles back ON
      });

      testWidgets('a gated output is announced as disabled (NF-5 a11y)', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pump(
          tester,
          TracksRoutingGraphView(
            tracks: const [Track()],
            inputChannels: 2,
            outputChannels: 2,
            outputEnabledMask: 0x1, // output 1 disabled
            onOutputEnabledToggled: (_, {required enabled}) {},
          ),
        );

        final node = tester.getSemantics(
          find.byKey(const Key('routingNode_output_1')),
        );
        // The disabled state + the toggle action are named for assistive tech,
        // not conveyed by colour alone (WCAG 1.4.1 / 4.1.2).
        expect(node.label.toLowerCase(), contains('disabled'));
        expect(node, isSemantics(isButton: true, hasTapAction: true));
        handle.dispose();
      });

      testWidgets('an enabled output toggle has a semantic label', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pump(
          tester,
          TracksRoutingGraphView(
            tracks: const [Track()],
            inputChannels: 2,
            outputChannels: 2,
            onOutputEnabledToggled: (_, {required enabled}) {},
          ),
        );

        final node = tester.getSemantics(
          find.byKey(const Key('routingNode_output_0')),
        );
        expect(node.label.toLowerCase(), contains('enabled'));
        handle.dispose();
      });
    });
  });
}
