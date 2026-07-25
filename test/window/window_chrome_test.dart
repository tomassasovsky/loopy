import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/common/console_mode.dart';
import 'package:loopy/window/window_chrome.dart';

void main() {
  group('loopyUsesCursorAutoHide', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('matches loopyUsesFlutterTitleBar on Windows (custom chrome)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(loopyUsesCursorAutoHide, isTrue);
      expect(loopyUsesCursorAutoHide, equals(loopyUsesFlutterTitleBar));
    });

    test('matches loopyUsesFlutterTitleBar on macOS (no custom chrome)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(loopyUsesCursorAutoHide, isFalse);
      expect(loopyUsesCursorAutoHide, equals(loopyUsesFlutterTitleBar));
    });

    test(
      'off on Linux outside console/kiosk builds (regular unit test run)',
      () {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        expect(loopyUsesCursorAutoHide, isFalse);
      },
      // kConsoleMode is a compile-time flag; this checks the regular-build
      // branch, so it's skipped under --dart-define=LOOPY_CONSOLE=true (the
      // Linux-console-mode branch below covers that run instead — mirrors the
      // golden test gating in test/screenshots/tracks_screenshots_test.dart).
      skip: kConsoleMode,
    );

    test(
      'on for the Linux console/kiosk build (run with '
      '--dart-define=LOOPY_CONSOLE=true)',
      () {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        expect(loopyUsesCursorAutoHide, isTrue);
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
