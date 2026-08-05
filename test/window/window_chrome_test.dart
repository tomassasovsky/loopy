import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/common/console_mode.dart';
import 'package:segno/window/window_chrome.dart';

void main() {
  group('segnoUsesCursorAutoHide', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('matches segnoUsesFlutterTitleBar on Windows (custom chrome)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(segnoUsesCursorAutoHide, isTrue);
      expect(segnoUsesCursorAutoHide, equals(segnoUsesFlutterTitleBar));
    });

    test('matches segnoUsesFlutterTitleBar on macOS (no custom chrome)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(segnoUsesCursorAutoHide, isFalse);
      expect(segnoUsesCursorAutoHide, equals(segnoUsesFlutterTitleBar));
    });

    test(
      'off on Linux outside console/kiosk builds (regular unit test run)',
      () {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        expect(segnoUsesCursorAutoHide, isFalse);
      },
      // kConsoleMode is a compile-time flag; this checks the regular-build
      // branch, so it's skipped under --dart-define=SEGNO_CONSOLE=true (the
      // Linux-console-mode branch below covers that run instead — mirrors the
      // golden test gating in test/screenshots/tracks_screenshots_test.dart).
      skip: kConsoleMode,
    );

    test(
      'on for the Linux console/kiosk build (run with '
      '--dart-define=SEGNO_CONSOLE=true)',
      () {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        expect(segnoUsesCursorAutoHide, isTrue);
      },
      skip: !kConsoleMode,
    );
  });

  group('shouldFullscreenMainWindow', () {
    test('single display → windowed (no auto-fullscreen)', () {
      expect(shouldFullscreenMainWindow(1), isFalse);
    });

    test('two displays → full-screen the console', () {
      expect(shouldFullscreenMainWindow(2), isTrue);
    });

    test('three or more displays → still full-screen', () {
      expect(shouldFullscreenMainWindow(3), isTrue);
    });

    test('zero displays (headless / unknown) → windowed, never crash', () {
      expect(shouldFullscreenMainWindow(0), isFalse);
    });
  });
}
