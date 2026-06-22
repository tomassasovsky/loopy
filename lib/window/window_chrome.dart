import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:window_manager/window_manager.dart';

/// The chrome renders in both the main window and the secondary waveform window
/// (which has no Localizations ancestor), so labels resolve from the platform
/// locale rather than a [BuildContext].
AppLocalizations get _chromeL10n =>
    lookupAppLocalizations(PlatformDispatcher.instance.locale);

/// Whether Loopy uses a Flutter-drawn title bar instead of the native one.
///
/// Enabled on Windows so the chrome matches the dark big-picture theme.
bool get loopyUsesFlutterTitleBar =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// Hides the native title bar on Windows so Flutter can draw
/// [LoopyWindowTitleBar].
Future<void> configureLoopyDesktopWindow({String title = 'Loopy'}) async {
  if (!loopyUsesFlutterTitleBar) return;
  await windowManager.ensureInitialized();
  await windowManager.setTitle(title);
  await windowManager.setTitleBarStyle(
    TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
}

/// Whether desktop window controls (fullscreen, etc.) are available.
bool get loopySupportsDesktopWindowing =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

/// Toggles OS fullscreen for the current window.
Future<void> toggleLoopyFullScreen() async {
  if (!loopySupportsDesktopWindowing) return;
  try {
    await windowManager.ensureInitialized();
    await windowManager.setFullScreen(!(await windowManager.isFullScreen()));
  } on Object {
    // Platform channel unavailable in widget tests.
  }
}

/// Wraps [body] with an optional hideable custom title bar on Windows.
class LoopyWindowChromeShell extends StatefulWidget {
  /// Creates a [LoopyWindowChromeShell].
  const LoopyWindowChromeShell({
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
  State<LoopyWindowChromeShell> createState() => _LoopyWindowChromeShellState();
}

/// Height of the drag strip when the title bar is hidden.
const loopyHiddenTitleStripHeight = 12.0;

/// How long the reveal button stays visible after the last pointer move.
const loopyChromeRevealIdle = Duration(seconds: 2);

/// How long after the last pointer move before the cursor is hidden.
const loopyCursorHideIdle = Duration(seconds: 3);

class _LoopyWindowChromeShellState extends State<LoopyWindowChromeShell> {
  var _titleBarVisible = true;
  var _chromeRevealed = false;
  var _cursorVisible = true;
  Timer? _chromeHideTimer;
  Timer? _cursorHideTimer;

  @override
  void initState() {
    super.initState();
    if (loopyUsesFlutterTitleBar) {
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
      _chromeHideTimer = Timer(loopyChromeRevealIdle, () {
        if (mounted && !_titleBarVisible) {
          setState(() => _chromeRevealed = false);
        }
      });
    }

    _scheduleCursorHide();
  }

  void _scheduleCursorHide() {
    _cursorHideTimer?.cancel();
    _cursorHideTimer = Timer(loopyCursorHideIdle, () {
      if (mounted) {
        setState(() => _cursorVisible = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!loopyUsesFlutterTitleBar) {
      return widget.body;
    }

    final scaffold = Scaffold(
      backgroundColor: widget.backgroundColor,
      appBar: _titleBarVisible
          ? LoopyWindowTitleBar(
              title: widget.title,
              onHide: _hideTitleBar,
            )
          : LoopyWindowHiddenTitleStrip(
              revealed: _chromeRevealed,
              onShow: _showTitleBar,
            ),
      body: widget.body,
    );

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerMove: (_) => _onPointerActivity(),
      onPointerHover: (_) => _onPointerActivity(),
      onPointerDown: (_) => _onPointerActivity(),
      child: MouseRegion(
        cursor: _cursorVisible ? MouseCursor.defer : SystemMouseCursors.none,
        child: scaffold,
      ),
    );
  }
}

/// Dark custom title bar for Loopy desktop windows on Windows.
class LoopyWindowTitleBar extends StatefulWidget
    implements PreferredSizeWidget {
  /// Creates a [LoopyWindowTitleBar] showing [title].
  const LoopyWindowTitleBar({
    required this.title,
    this.onHide,
    super.key,
  });

  /// OS window title.
  final String title;

  /// Called when the user hides the title bar.
  final VoidCallback? onHide;

  /// Dark surface tone matching the big-picture theme (`#0D0D11`).
  static const barColor = Color(0xFF0D0D11);

  @override
  Size get preferredSize => const Size.fromHeight(kWindowCaptionHeight);

  @override
  State<LoopyWindowTitleBar> createState() => _LoopyWindowTitleBarState();
}

class _LoopyWindowTitleBarState extends State<LoopyWindowTitleBar>
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
        decoration: const BoxDecoration(color: LoopyWindowTitleBar.barColor),
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
              _LoopyChromeIconButton(
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
class LoopyWindowHiddenTitleStrip extends StatelessWidget
    implements PreferredSizeWidget {
  /// Creates a [LoopyWindowHiddenTitleStrip].
  const LoopyWindowHiddenTitleStrip({
    required this.onShow,
    this.revealed = false,
    super.key,
  });

  /// Restores the full title bar.
  final VoidCallback onShow;

  /// Whether the show button and strip tint are visible.
  final bool revealed;

  @override
  Size get preferredSize => const Size.fromHeight(loopyHiddenTitleStripHeight);

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
          ? LoopyWindowTitleBar.barColor.withValues(alpha: 0.85)
          : Colors.transparent,
      child: Row(
        children: [
          const Expanded(
            child: DragToMoveArea(
              child: SizedBox(height: loopyHiddenTitleStripHeight),
            ),
          ),
          AnimatedOpacity(
            opacity: revealed ? 1 : 0,
            duration: motion,
            child: IgnorePointer(
              ignoring: !revealed,
              child: _LoopyChromeIconButton(
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

class _LoopyChromeIconButton extends StatelessWidget {
  const _LoopyChromeIconButton({
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
    final height = compact ? loopyHiddenTitleStripHeight : kWindowCaptionHeight;
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
