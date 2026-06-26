// native_window_controller_win.cpp — host-owned HWND for plugin editors (Windows).
//
// The Win32 counterpart of native_window_controller.mm: the same lpw_window_* C
// ABI (see the header) over a host-owned top-level window so the C++ VST3/CLAP
// host backends (host_vst3.cpp / host_clap.cpp) attach an editor without touching
// the Win32 API themselves. The window is host-owned and NOT embedded in the
// Flutter view tree (umbrella D-WIN), sidestepping the child-window limitation.
//
// A plain child STATIC window fills the client area and is the plugin's attach
// parent (the analogue of macOS's NSView contentView): the plugin re-parents its
// editor under it via VST3 attached(hwnd, kPlatformTypeHWND) / CLAP set_parent.
//
// MAIN THREAD ONLY. A user close (title-bar X) fires WM_CLOSE → the on_close
// callback, then frees the handle on a POSTED message so teardown never runs
// inside the close handler (mirrors the .mm's dispatch_async deferred free). A
// host-driven lpw_window_close suppresses that callback.

#if defined(LOOPY_ENABLE_PLUGINS) && defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <cstdlib>
#include <string>

#include "native_window_controller.h"

namespace {

const wchar_t* kWindowClass = L"LoopyPluginEditorWindow";

// Converts UTF-8 to a wide string for the Win32 …W APIs. Returns an empty string
// on failure (an unnamed window, never a crash).
std::wstring widen(const char* utf8) {
  if (!utf8 || !*utf8) return std::wstring();
  const int n =
      MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
  if (n <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(n - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out.data(), n);
  return out;
}

}  // namespace

// The handle owns its two HWNDs plus the user-close callback. `suppress` is set
// when the HOST initiates the close (lpw_window_close), so WM_CLOSE fires the
// callback only for a genuine user close — never a double teardown.
struct lpw_window {
  HWND top = nullptr;      // top-level editor frame
  HWND content = nullptr;  // child STATIC; the plugin's attach parent
  lpw_close_cb cb = nullptr;
  void* ctx = nullptr;
  bool suppress = false;
};

namespace {

LRESULT CALLBACK wndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  auto* h = reinterpret_cast<lpw_window*>(
      GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  switch (msg) {
    case WM_CLOSE: {
      // User clicked the title-bar X. (A host-driven close goes through
      // lpw_window_close → DestroyWindow, which never sends WM_CLOSE.) Notify
      // the host so it detaches the plugin view, then destroy the window. The
      // handle is freed in WM_NCDESTROY below — the canonical place — so there
      // is no posted-message dependency that a stopping run-loop could drop.
      if (!h || h->suppress) return 0;  // guard against re-entry
      h->suppress = true;
      if (h->cb) h->cb(h->ctx);  // the host detaches the plugin view now
      DestroyWindow(hwnd);       // also destroys the content child
      return 0;
    }
    case WM_SIZE:
      // Keep the content child filling the client area so the plugin's editor
      // resizes with the frame.
      if (h && h->content) {
        MoveWindow(h->content, 0, 0, LOWORD(lParam), HIWORD(lParam), TRUE);
      }
      return 0;
    case WM_NCDESTROY:
      // The window's final message: free the handle exactly once, for both the
      // user-close (above) and host-driven (lpw_window_close) paths. Clearing
      // GWLP_USERDATA first means any later stray message reads a null handle.
      if (h) {
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        std::free(h);
      }
      return 0;
    default:
      break;
  }
  return DefWindowProcW(hwnd, msg, wParam, lParam);
}

// Registers the editor window class once (idempotent; main-thread only).
void ensureWindowClass() {
  static bool registered = false;
  if (registered) return;
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.style = CS_HREDRAW | CS_VREDRAW;
  wc.lpfnWndProc = wndProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  wc.lpszClassName = kWindowClass;
  RegisterClassExW(&wc);  // a benign failure (already registered) is fine
  registered = true;
}

// The top-level window rect that yields a `width`×`height` client area, centred
// on the primary monitor's work area. Physical pixels.
RECT centredFrameRect(int width, int height, DWORD style) {
  RECT r = {0, 0, width, height};
  AdjustWindowRect(&r, style, FALSE);
  const int frameW = r.right - r.left;
  const int frameH = r.bottom - r.top;
  RECT work = {};
  if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0)) {
    work.left = 0;
    work.top = 0;
    work.right = GetSystemMetrics(SM_CXSCREEN);
    work.bottom = GetSystemMetrics(SM_CYSCREEN);
  }
  const int x = work.left + ((work.right - work.left) - frameW) / 2;
  const int y = work.top + ((work.bottom - work.top) - frameH) / 2;
  RECT out = {x, y, x + frameW, y + frameH};
  return out;
}

}  // namespace

extern "C" {

lpw_window* lpw_window_open(int32_t width, int32_t height, const char* title,
                            lpw_close_cb on_close, void* ctx) {
  if (width <= 0) width = 400;
  if (height <= 0) height = 300;
  ensureWindowClass();

  const DWORD style = WS_OVERLAPPEDWINDOW;
  const RECT frame = centredFrameRect(width, height, style);
  const std::wstring wtitle = title ? widen(title) : std::wstring();

  HWND top = CreateWindowExW(
      0, kWindowClass, wtitle.empty() ? L"Plugin Editor" : wtitle.c_str(), style,
      frame.left, frame.top, frame.right - frame.left, frame.bottom - frame.top,
      nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (!top) return nullptr;

  // A plain child fills the client area as the plugin's attach parent. WS_CLIPCHILDREN
  // on neither is needed for a single child; the plugin paints inside it.
  RECT client = {};
  GetClientRect(top, &client);
  HWND content = CreateWindowExW(
      0, L"STATIC", L"", WS_CHILD | WS_VISIBLE, 0, 0, client.right,
      client.bottom, top, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (!content) {
    DestroyWindow(top);
    return nullptr;
  }

  auto* handle = static_cast<lpw_window*>(std::calloc(1, sizeof(lpw_window)));
  if (!handle) {
    DestroyWindow(top);  // also destroys content
    return nullptr;
  }
  handle->top = top;
  handle->content = content;
  handle->cb = on_close;
  handle->ctx = ctx;
  handle->suppress = false;
  SetWindowLongPtrW(top, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(handle));
  return handle;
}

void* lpw_window_content_view(lpw_window* window) {
  if (!window) return nullptr;
  return window->content;  // the plugin attaches under this HWND
}

void lpw_window_resize(lpw_window* window, int32_t width, int32_t height) {
  if (!window || !window->top || width <= 0 || height <= 0) return;
  const DWORD style =
      static_cast<DWORD>(GetWindowLongPtrW(window->top, GWL_STYLE));
  RECT r = {0, 0, width, height};
  AdjustWindowRect(&r, style, FALSE);
  RECT cur = {};
  GetWindowRect(window->top, &cur);  // keep the top-left corner fixed
  SetWindowPos(window->top, nullptr, cur.left, cur.top, r.right - r.left,
               r.bottom - r.top, SWP_NOZORDER | SWP_NOACTIVATE);
  // WM_SIZE resizes the content child to the new client area.
}

void lpw_window_show(lpw_window* window) {
  if (!window || !window->top) return;
  ShowWindow(window->top, SW_SHOW);
  SetForegroundWindow(window->top);
}

void lpw_window_close(lpw_window* window) {
  if (!window || !window->top) return;
  // Host-driven close: suppress the WM_CLOSE callback (the caller is already in
  // teardown — DestroyWindow does not send WM_CLOSE anyway) and tear down
  // synchronously. DestroyWindow → WM_NCDESTROY frees the handle, so the handle
  // is dangling after this call returns (the host drops its pointer).
  window->suppress = true;
  DestroyWindow(window->top);  // also destroys the content child
}

}  // extern "C"

#else
typedef int loopy_native_window_win_tu_unused;  // keep the TU non-empty elsewhere
#endif  // LOOPY_ENABLE_PLUGINS && _WIN32
