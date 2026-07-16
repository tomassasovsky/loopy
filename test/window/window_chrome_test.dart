import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/window/window_chrome.dart';

void main() {
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
