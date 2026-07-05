// Hand-written user32 glue: the single-use function typedefs read clearer than
// inlining two type arguments per lookupFunction call.
// ignore_for_file: avoid_private_typedef_functions

import 'dart:ffi' hide Size; // dart:ffi's Size (size_t) clashes with dart:ui's
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Embeds the engine's native plugin-editor window (`LoopyPluginEditorWindow`)
/// **inside** the Flutter window on Windows.
///
/// True widget-tree embedding is impossible on Flutter Windows — `FLUTTERVIEW`
/// composites over any reparented child (the airspace problem). The working
/// technique (proven live) is an **owned, borderless overlay**: keep the editor
/// a separate top-level window (its own DWM surface, so it draws above Flutter
/// and stays interactive), make it owned by the Flutter window so it
/// follows / minimizes with it, and pin it over the dock's region — repositioned
/// each frame so it tracks scrolls, resizes, and window moves.
///
/// All Win32 here (via `user32.dll`); a no-op on non-Windows. Same-process
/// window manipulation, so no special privileges are needed.
class PluginEditorHost {
  PluginEditorHost._();

  /// The process-wide instance.
  static final PluginEditorHost instance = PluginEditorHost._();

  static const int _gwlStyle = -16;
  static const int _gwlpHwndParent = -8;
  static const int _wsOverlappedWindow = 0x00CF0000;
  static const int _wsPopup = 0x80000000;
  static const int _wsClipSiblings = 0x04000000;
  static const int _wsVisible = 0x10000000;
  static const int _swpNoZOrder = 0x0004;
  static const int _swpNoActivate = 0x0010;
  static const int _swpFrameChanged = 0x0020;
  static const int _swpShowWindow = 0x0040;
  static const int _swHide = 0;

  bool get isSupported => !kIsWeb && Platform.isWindows;

  bool _loaded = false;
  late final _FindWindow _findWindow;
  late final _GetWindowLongPtr _getStyle;
  late final _SetWindowLongPtr _setStyle;
  late final _SetWindowPos _setWindowPos;
  late final _ClientToScreen _clientToScreen;
  late final _GetClientRect _getClientRect;
  late final _ShowWindow _showWindow;
  late final _BoolFromHandle _isWindow;

  void _ensure() {
    if (_loaded || !isSupported) return;
    final user32 = DynamicLibrary.open('user32.dll');
    _findWindow = user32.lookupFunction<_FindWindowC, _FindWindow>(
      'FindWindowW',
    );
    _getStyle = user32.lookupFunction<_GetWindowLongPtrC, _GetWindowLongPtr>(
      'GetWindowLongPtrW',
    );
    _setStyle = user32.lookupFunction<_SetWindowLongPtrC, _SetWindowLongPtr>(
      'SetWindowLongPtrW',
    );
    _setWindowPos = user32.lookupFunction<_SetWindowPosC, _SetWindowPos>(
      'SetWindowPos',
    );
    _clientToScreen = user32.lookupFunction<_ClientToScreenC, _ClientToScreen>(
      'ClientToScreen',
    );
    _getClientRect = user32.lookupFunction<_GetClientRectC, _GetClientRect>(
      'GetClientRect',
    );
    _showWindow = user32.lookupFunction<_ShowWindowC, _ShowWindow>(
      'ShowWindow',
    );
    _isWindow = user32.lookupFunction<_BoolFromHandleC, _BoolFromHandle>(
      'IsWindow',
    );
    _loaded = true;
  }

  int _find(String className) {
    final cls = className.toNativeUtf16();
    try {
      return _findWindow(cls, nullptr);
    } finally {
      malloc.free(cls);
    }
  }

  int get _editor => _find('LoopyPluginEditorWindow');
  int get _flutter => _find('FLUTTER_RUNNER_WIN32_WINDOW');

  /// The editor window's client size in **physical** pixels, or null when no
  /// editor window exists yet (its open call may still be in flight).
  Size? editorPhysicalSize() {
    if (!isSupported) return null;
    _ensure();
    final editor = _editor;
    if (editor == 0 || _isWindow(editor) == 0) return null;
    final rect = calloc<_Rect>();
    try {
      if (_getClientRect(editor, rect) == 0) return null;
      final r = rect.ref;
      final w = r.right - r.left;
      final h = r.bottom - r.top;
      if (w <= 0 || h <= 0) return null;
      return Size(w.toDouble(), h.toDouble());
    } finally {
      calloc.free(rect);
    }
  }

  /// Pins the editor over [clientRectPhysical] (physical px, relative to the
  /// Flutter window's client area), reconfiguring it as an owned borderless
  /// overlay the first time. Idempotent per frame; returns whether it landed.
  bool position(Rect clientRectPhysical, {required bool firstAttach}) {
    if (!isSupported) return false;
    _ensure();
    final editor = _editor;
    final flutter = _flutter;
    if (editor == 0 || flutter == 0 || _isWindow(editor) == 0) return false;

    if (firstAttach) {
      final style =
          (_getStyle(editor, _gwlStyle) & ~_wsOverlappedWindow) |
          _wsPopup |
          _wsClipSiblings |
          _wsVisible;
      _setStyle(editor, _gwlStyle, style);
      _setStyle(editor, _gwlpHwndParent, flutter); // own it to the app window
    }

    final pt = calloc<_Point>()
      ..ref.x = clientRectPhysical.left.round()
      ..ref.y = clientRectPhysical.top.round();
    try {
      _clientToScreen(flutter, pt); // client → screen (tracks window moves)
      final flags = firstAttach
          ? _swpFrameChanged | _swpShowWindow | _swpNoActivate
          : _swpNoZOrder | _swpNoActivate | _swpShowWindow;
      _setWindowPos(
        editor,
        0, // HWND_TOP on first attach; NOZORDER keeps it after
        pt.ref.x,
        pt.ref.y,
        clientRectPhysical.width.round(),
        clientRectPhysical.height.round(),
        flags,
      );
      return true;
    } finally {
      calloc.free(pt);
    }
  }

  /// Hides the overlay (e.g. before the engine tears it down, or when the dock
  /// closes) so no orphaned window flashes.
  void hide() {
    if (!isSupported) return;
    _ensure();
    final editor = _editor;
    if (editor != 0 && _isWindow(editor) != 0) _showWindow(editor, _swHide);
  }
}

// ---- user32 signatures ----

final class _Rect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

final class _Point extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

typedef _FindWindowC = IntPtr Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _FindWindow = int Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _GetWindowLongPtrC = IntPtr Function(IntPtr, Int32);
typedef _GetWindowLongPtr = int Function(int, int);
typedef _SetWindowLongPtrC = IntPtr Function(IntPtr, Int32, IntPtr);
typedef _SetWindowLongPtr = int Function(int, int, int);
typedef _SetWindowPosC =
    Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32);
typedef _SetWindowPos = int Function(int, int, int, int, int, int, int);
typedef _ClientToScreenC = Int32 Function(IntPtr, Pointer<_Point>);
typedef _ClientToScreen = int Function(int, Pointer<_Point>);
typedef _GetClientRectC = Int32 Function(IntPtr, Pointer<_Rect>);
typedef _GetClientRect = int Function(int, Pointer<_Rect>);
typedef _ShowWindowC = Int32 Function(IntPtr, Int32);
typedef _ShowWindow = int Function(int, int);
typedef _BoolFromHandleC = Int32 Function(IntPtr);
typedef _BoolFromHandle = int Function(int);
