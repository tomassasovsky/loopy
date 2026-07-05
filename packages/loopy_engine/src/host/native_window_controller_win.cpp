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

// Height of our own drawn title strip (the window is borderless — WS_POPUP —
// so it reads as an in-app overlay, not an OS-chromed native window). The strip
// carries the plugin name and a close button; the plugin's editor sits below.
const int kTitleH = 30;

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
    case WM_KEYDOWN:
      // Esc closes the overlay (when the frame — not the plugin child — holds
      // focus; the drawn close button is the always-available affordance).
      if (wParam == VK_ESCAPE) {
        SendMessageW(hwnd, WM_CLOSE, 0, 0);
        return 0;
      }
      break;
    case WM_PAINT: {
      // Our own title strip: the plugin name + a close button, so the
      // borderless window reads as an in-app overlay, not OS chrome.
      PAINTSTRUCT ps;
      HDC dc = BeginPaint(hwnd, &ps);
      RECT c;
      GetClientRect(hwnd, &c);
      RECT strip = {0, 0, c.right, kTitleH};
      HBRUSH bg = CreateSolidBrush(RGB(26, 26, 30));
      FillRect(dc, &strip, bg);
      DeleteObject(bg);
      SetBkMode(dc, TRANSPARENT);
      SetTextColor(dc, RGB(220, 220, 226));
      wchar_t title[256] = {};
      GetWindowTextW(hwnd, title, 256);
      RECT tr = {12, 0, c.right - kTitleH, kTitleH};
      DrawTextW(dc, title, -1, &tr,
                DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
      RECT xr = {c.right - kTitleH, 0, c.right, kTitleH};
      const wchar_t kClose[] = {0x2715, 0};  // a plain multiply-x close glyph
      DrawTextW(dc, kClose, -1, &xr, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_NCHITTEST: {
      // The title strip is draggable; its right end is the close button.
      POINT p = {static_cast<SHORT>(LOWORD(lParam)),
                 static_cast<SHORT>(HIWORD(lParam))};
      ScreenToClient(hwnd, &p);
      RECT c;
      GetClientRect(hwnd, &c);
      if (p.y >= 0 && p.y < kTitleH) {
        if (p.x >= c.right - kTitleH) return HTCLOSE;
        return HTCAPTION;
      }
      return HTCLIENT;
    }
    case WM_NCLBUTTONDOWN:
      if (wParam == HTCLOSE) {
        SendMessageW(hwnd, WM_CLOSE, 0, 0);
        return 0;
      }
      break;  // HTCAPTION → DefWindowProc drags the overlay
    case WM_MOVING: {
      // Keep the overlay inside the app window — it can never be dragged out of
      // the main Flutter view.
      auto* r = reinterpret_cast<RECT*>(lParam);
      RECT o = {};
      if (GetWindowRect(GetWindow(hwnd, GW_OWNER), &o)) {
        const int w = r->right - r->left;
        const int ht = r->bottom - r->top;
        if (r->left < o.left) r->left = o.left;
        if (r->top < o.top) r->top = o.top;
        if (r->left > o.right - w) r->left = o.right - w;
        if (r->top > o.bottom - ht) r->top = o.bottom - ht;
        if (r->left < o.left) r->left = o.left;  // owner smaller than overlay
        if (r->top < o.top) r->top = o.top;
        r->right = r->left + w;
        r->bottom = r->top + ht;
      }
      return TRUE;
    }
    case WM_SIZE:
      // The plugin's editor fills the client BELOW the title strip.
      if (h && h->content) {
        const int ht = HIWORD(lParam) - kTitleH;
        MoveWindow(h->content, 0, kTitleH, LOWORD(lParam), ht > 0 ? ht : 0,
                   TRUE);
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

// The process's Flutter top-level window, or null. Used as the editor window's
// OWNER so the editor is an overlay of the app (no separate taskbar button;
// floats above the app and minimizes / restores with it) — the Windows analogue
// of a macOS app window, rather than a detached top-level window.
BOOL CALLBACK findAppWindowProc(HWND hwnd, LPARAM lparam) {
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid != GetCurrentProcessId()) return TRUE;  // keep scanning
  wchar_t cls[64] = {};
  GetClassNameW(hwnd, cls, 64);
  if (lstrcmpW(cls, L"FLUTTER_RUNNER_WIN32_WINDOW") == 0) {
    *reinterpret_cast<HWND*>(lparam) = hwnd;
    return FALSE;  // found it; stop
  }
  return TRUE;
}

HWND findAppWindow() {
  HWND found = nullptr;
  EnumWindows(findAppWindowProc, reinterpret_cast<LPARAM>(&found));
  return found;
}

}  // namespace

extern "C" {

lpw_window* lpw_window_open(int32_t width, int32_t height, const char* title,
                            lpw_close_cb on_close, void* ctx) {
  if (width <= 0) width = 400;
  if (height <= 0) height = 300;
  ensureWindowClass();

  // Borderless (WS_POPUP) so it reads as an in-app overlay with our own drawn
  // title strip, not an OS-chromed native window. Client = plugin size plus the
  // strip. WS_CLIPCHILDREN so our title paint never overdraws the plugin child.
  const int clientW = width;
  const int clientH = height + kTitleH;
  const DWORD style = WS_POPUP | WS_CLIPCHILDREN;
  const std::wstring wtitle = title ? widen(title) : std::wstring();

  // Owned by the app's Flutter window (when found): an overlay of the app —
  // no taskbar button, always above it, minimizes / restores with it.
  HWND owner = findAppWindow();

  // Centre the overlay over the owner (or the work area if there is none).
  RECT anchor = {};
  if (!owner || !GetWindowRect(owner, &anchor)) {
    if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &anchor, 0)) {
      anchor = {0, 0, GetSystemMetrics(SM_CXSCREEN),
                GetSystemMetrics(SM_CYSCREEN)};
    }
  }
  const int x = anchor.left + ((anchor.right - anchor.left) - clientW) / 2;
  const int y = anchor.top + ((anchor.bottom - anchor.top) - clientH) / 2;

  HWND top = CreateWindowExW(
      0, kWindowClass, wtitle.empty() ? L"Plugin Editor" : wtitle.c_str(),
      style, x, y, clientW, clientH, owner, nullptr, GetModuleHandleW(nullptr),
      nullptr);
  if (!top) return nullptr;

  // The plugin's attach parent sits BELOW the title strip.
  HWND content = CreateWindowExW(
      0, L"STATIC", L"", WS_CHILD | WS_VISIBLE, 0, kTitleH, clientW, height,
      top, nullptr, GetModuleHandleW(nullptr), nullptr);
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
  // Borderless: client == outer. Add our title strip to the plugin's requested
  // size; WM_SIZE re-lays the content child below the strip. Top-left fixed.
  RECT cur = {};
  GetWindowRect(window->top, &cur);
  SetWindowPos(window->top, nullptr, cur.left, cur.top, width,
               height + kTitleH, SWP_NOZORDER | SWP_NOACTIVATE);
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
