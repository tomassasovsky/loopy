/*
 * native_window_controller.h — host-owned native editor window (macOS).
 *
 * A tiny C ABI over an AppKit NSWindow so the C++ VST3/CLAP host backends
 * (host_vst3.cpp / host_clap.cpp) can open a top-level editor window WITHOUT
 * importing AppKit themselves — all Objective-C lives in
 * native_window_controller.mm. The window is host-owned and not embedded in the
 * Flutter view tree (umbrella D-WIN), sidestepping the child-window limitation.
 *
 * MAIN THREAD ONLY. The plugin attaches its view to the window's contentView
 * (a plain NSView). When the plugin requests a resize it calls lpw_window_resize;
 * when the user closes the window (red button) the on_close callback fires so the
 * host can detach + release the plugin view exactly once.
 */
#ifndef LOOPY_HOST_NATIVE_WINDOW_CONTROLLER_H
#define LOOPY_HOST_NATIVE_WINDOW_CONTROLLER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque host-owned window handle. */
typedef struct lpw_window lpw_window;

/* Fired (once) when the user closes the window via its title-bar control, so the
 * host can detach the plugin view. The window is already closing — the host must
 * NOT call lpw_window_close again from this callback. */
typedef void (*lpw_close_cb)(void* ctx);

/* Creates and retains a centered, titled, resizable window sized to the plugin's
 * requested content size, with a blank NSView contentView ready for the plugin
 * to attach to. Not shown yet (call lpw_window_show). Returns NULL on failure.
 * `title` may be NULL. */
lpw_window* lpw_window_open(int32_t width, int32_t height, const char* title,
                            lpw_close_cb on_close, void* ctx);

/* The window's contentView as an NSView* (the plugin's attach parent). */
void* lpw_window_content_view(lpw_window* window);

/* Resizes the window's content area to (width, height) — used to honour a
 * plugin-requested resize. */
void lpw_window_resize(lpw_window* window, int32_t width, int32_t height);

/* Brings the window on-screen and to the front. */
void lpw_window_show(lpw_window* window);

/* Closes the window, releases it, and frees the handle. Safe with NULL. Does
 * NOT invoke on_close (the host is the caller here). After this the handle is
 * invalid. */
void lpw_window_close(lpw_window* window);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_HOST_NATIVE_WINDOW_CONTROLLER_H */
