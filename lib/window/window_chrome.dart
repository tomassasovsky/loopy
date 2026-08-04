import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:segno/common/console_mode.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:window_manager/window_manager.dart';

/// The chrome renders in both the main window and the secondary waveform window
/// (which has no Localizations ancestor), so labels resolve from the platform
/// locale rather than a [BuildContext].
AppLocalizations get _chromeL10n =>
    lookupAppLocalizations(PlatformDispatcher.instance.locale);

/// Whether Segno uses a Flutter-drawn title bar instead of the native one.
///
/// Enabled on Windows so the chrome matches the dark tracks theme.
bool get segnoUsesFlutterTitleBar =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// Whether Segno should auto-hide the idle mouse cursor.
///
/// Enabled wherever [segnoUsesFlutterTitleBar] draws custom chrome, and also
/// on the Linux console/kiosk build ([kConsoleMode]) — the RPi floor console
/// has no title bar (it's driven by foot pedals, not a pointer), but the OS
/// cursor should still vanish after idle instead of sitting on the touchscreen.
bool get segnoUsesCursorAutoHide =>
    segnoUsesFlutterTitleBar ||
    (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux && kConsoleMode);

/// Hides the native title bar on Windows so Flutter can draw
/// [SegnoWindowTitleBar].
Future<void> configureSegnoDesktopWindow({String title = 'Segno'}) async {
  if (!segnoUsesFlutterTitleBar) return;
  await windowManager.ensureInitialized();
  await windowManager.setTitle(title);
  await windowManager.setTitleBarStyle(
    TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
}

/// Whether desktop window controls (fullscreen, etc.) are available.
bool get segnoSupportsDesktopWindowing =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

/// Toggles OS fullscreen for the current window.
Future<void> toggleSegnoFullScreen() async {
  if (!segnoSupportsDesktopWindowing) return;
  try {
    await windowManager.ensureInitialized();
    await windowManager.setFullScreen(!(await windowManager.isFullScreen()));
  } on Object {
    // Platform channel unavailable in widget tests.
  }
}

/// Whether the main window should launch full-screen: only on a multi-display
/// console, so a single-monitor / dev machine keeps a normal window. Pure so it
/// can be unit-tested without a real desktop.
bool shouldFullscreenMainWindow(int displayCount) => displayCount >= 2;

/// Full-screens the main window on the primary display at launch when the
/// console has a second display (the output waveform fills the secondary, so
/// the control surface fills the primary). No-op on a single display or in
/// tests; the user can still toggle it off with [toggleSegnoFullScreen].
Future<void> applyMainWindowFullscreen(int displayCount) async {
  if (!segnoSupportsDesktopWindowing) return;
  if (!shouldFullscreenMainWindow(displayCount)) return;
  try {
    await windowManager.ensureInitialized();
    await windowManager.setFullScreen(true);
  } on Object {
    // Platform channel unavailable in widget tests.
  }
}

/// Wraps [body] with an optional hideable custom title bar on Windows.
class SegnoWindowChromeShell extends StatefulWidget {
  /// Creates a [SegnoWindowChromeShell].
  const SegnoWindowChromeShell({
    required this.title,
    required this.body,
    this.backgroundColor = const Color(0xFF06060A),
    super.key,
  });

  /// OS window title.
  final String title;

  /// Content below the title bar.
  final Widget body;

  /// Scaffold background when the Flutter title bar is shown.
  final Color backgroundColor;

  @override
  State<SegnoWindowChromeShell> createState() => _SegnoWindowChromeShellState();
}

/// Height of the drag strip when the title bar is hidden.
const segnoHiddenTitleStripHeight = 12.0;

/// How long the reveal button stays visible after the last pointer move.
const segnoChromeRevealIdle = Duration(seconds: 2);

/// How long after the last pointer move before the cursor is hidden.
const segnoCursorHideIdle = Duration(seconds: 3);

class _SegnoWindowChromeShellState extends State<SegnoWindowChromeShell> {
  var _titleBarVisible = true;
  var _chromeRevealed = false;
  var _cursorVisible = true;
  Timer? _chromeHideTimer;
  Timer? _cursorHideTimer;

  @override
  void initState() {
    super.initState();
    if (segnoUsesCursorAutoHide) {
      _scheduleCursorHide();
    }
  }

  @override
  void dispose() {
    _chromeHideTimer?.cancel();
    _cursorHideTimer?.cancel();
    super.dispose();
  }

  void _hideTitleBar() {
    setState(() {
      _titleBarVisible = false;
      _chromeRevealed = false;
    });
    _chromeHideTimer?.cancel();
    _scheduleCursorHide();
  }

  void _showTitleBar() {
    setState(() {
      _titleBarVisible = true;
      _chromeRevealed = false;
    });
    _chromeHideTimer?.cancel();
    _onPointerActivity();
  }

  void _onPointerActivity() {
    final needsUpdate =
        !_cursorVisible || (!_titleBarVisible && !_chromeRevealed);
    if (needsUpdate) {
      setState(() {
        _cursorVisible = true;
        if (!_titleBarVisible) {
          _chromeRevealed = true;
        }
      });
    }
    _scheduleIdleHides();
  }

  void _scheduleIdleHides() {
    _chromeHideTimer?.cancel();
    _cursorHideTimer?.cancel();

    if (!_titleBarVisible) {
      _chromeHideTimer = Timer(segnoChromeRevealIdle, () {
        if (mounted && !_titleBarVisible) {
          setState(() => _chromeRevealed = false);
        }
      });
    }

    _scheduleCursorHide();
  }

  void _scheduleCursorHide() {
    _cursorHideTimer?.cancel();
    _cursorHideTimer = Timer(segnoCursorHideIdle, () {
      if (mounted) {
        setState(() => _cursorVisible = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!segnoUsesFlutterTitleBar && !segnoUsesCursorAutoHide) {
      return widget.body;
    }

    var content = widget.body;
    if (segnoUsesFlutterTitleBar) {
      content = Scaffold(
        backgroundColor: widget.backgroundColor,
        appBar: _titleBarVisible
            ? SegnoWindowTitleBar(
                title: widget.title,
                onHide: _hideTitleBar,
              )
            : SegnoWindowHiddenTitleStrip(
                revealed: _chromeRevealed,
                onShow: _showTitleBar,
              ),
        body: widget.body,
      );
    }

    if (!segnoUsesCursorAutoHide) {
      return content;
    }

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerMove: (_) => _onPointerActivity(),
      onPointerHover: (_) => _onPointerActivity(),
      onPointerDown: (_) => _onPointerActivity(),
      child: MouseRegion(
        cursor: _cursorVisible ? MouseCursor.defer : SystemMouseCursors.none,
        child: content,
      ),
    );
  }
}

/// Dark custom title bar for Segno desktop windows on Windows.
class SegnoWindowTitleBar extends StatefulWidget
    implements PreferredSizeWidget {
  /// Creates a [SegnoWindowTitleBar] showing [title].
  const SegnoWindowTitleBar({
    required this.title,
    this.onHide,
    super.key,
  });

  /// OS window title.
  final String title;

  /// Called when the user hides the title bar.
  final VoidCallback? onHide;

  /// Dark surface tone matching the tracks theme (`#0D0D11`).
  static const barColor = Color(0xFF0D0D11);

  @override
  Size get preferredSize => const Size.fromHeight(kWindowCaptionHeight);

  @override
  State<SegnoWindowTitleBar> createState() => _SegnoWindowTitleBarState();
}

class _SegnoWindowTitleBarState extends State<SegnoWindowTitleBar>
    with WindowListener {
  var _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(
      windowManager.isMaximized().then((maximized) {
        if (mounted) setState(() => _isMaximized = maximized);
      }),
    );
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const brightness = Brightness.dark;
    return SizedBox(
      height: kWindowCaptionHeight,
      child: DecoratedBox(
        decoration: const BoxDecoration(color: SegnoWindowTitleBar.barColor),
        child: Row(
          children: [
            Expanded(
              child: DragToMoveArea(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Text(
                      widget.title,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
            if (widget.onHide != null)
              _SegnoChromeIconButton(
                icon: Icons.expand_less,
                tooltip: _chromeL10n.a11yHideTitleBar,
                onPressed: widget.onHide!,
              ),
            WindowCaptionButton.minimize(
              brightness: brightness,
              onPressed: () async {
                if (await windowManager.isMinimized()) {
                  await windowManager.restore();
                } else {
                  await windowManager.minimize();
                }
              },
            ),
            if (_isMaximized)
              WindowCaptionButton.unmaximize(
                brightness: brightness,
                onPressed: windowManager.unmaximize,
              )
            else
              WindowCaptionButton.maximize(
                brightness: brightness,
                onPressed: windowManager.maximize,
              ),
            WindowCaptionButton.close(
              brightness: brightness,
              onPressed: windowManager.close,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void onWindowMaximize() => setState(() => _isMaximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);
}

/// Thin drag strip shown when the title bar is hidden.
class SegnoWindowHiddenTitleStrip extends StatelessWidget
    implements PreferredSizeWidget {
  /// Creates a [SegnoWindowHiddenTitleStrip].
  const SegnoWindowHiddenTitleStrip({
    required this.onShow,
    this.revealed = false,
    super.key,
  });

  /// Restores the full title bar.
  final VoidCallback onShow;

  /// Whether the show button and strip tint are visible.
  final bool revealed;

  @override
  Size get preferredSize => const Size.fromHeight(segnoHiddenTitleStripHeight);

  @override
  Widget build(BuildContext context) {
    // Honor the OS "reduce motion" preference (WCAG 2.3.3): collapse the
    // reveal transitions to an instant state change.
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    return AnimatedContainer(
      duration: motion,
      color: revealed
          ? SegnoWindowTitleBar.barColor.withValues(alpha: 0.85)
          : Colors.transparent,
      child: Row(
        children: [
          const Expanded(
            child: DragToMoveArea(
              child: SizedBox(height: segnoHiddenTitleStripHeight),
            ),
          ),
          AnimatedOpacity(
            opacity: revealed ? 1 : 0,
            duration: motion,
            child: IgnorePointer(
              ignoring: !revealed,
              child: _SegnoChromeIconButton(
                icon: Icons.expand_more,
                tooltip: _chromeL10n.a11yShowTitleBar,
                onPressed: onShow,
                compact: true,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SegnoChromeIconButton extends StatelessWidget {
  const _SegnoChromeIconButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.compact = false,
  });

  final IconData icon;
  final VoidCallback onPressed;

  /// Accessible name + hover tooltip for this icon-only control (WCAG 4.1.2).
  final String tooltip;

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final height = compact ? segnoHiddenTitleStripHeight : kWindowCaptionHeight;
    final width = compact ? 28.0 : 46.0;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          child: Semantics(
            button: true,
            label: tooltip,
            child: SizedBox(
              width: width,
              height: height,
              child: Icon(icon, size: compact ? 14 : 16, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}
