// native_window_controller.mm — host-owned NSWindow for plugin editors (macOS).
//
// The only Objective-C in the plugin host: a thin C ABI (see the header) over an
// AppKit NSWindow, so the C++ VST3/CLAP backends stay free of AppKit. Written to
// compile under BOTH ARC (the Flutter SPM/CocoaPods build) and non-ARC (the
// native test harness): ObjC objects are held in the malloc'd C handle as
// bridged CFTypeRefs (CFBridgingRetain/Release), and no explicit retain/release
// message is sent. MAIN THREAD ONLY — the FFI editor calls run on the platform
// thread.

#if defined(LOOPY_ENABLE_PLUGINS) && defined(__APPLE__)

#import <Cocoa/Cocoa.h>

#include <cstdlib>

#include "native_window_controller.h"

struct lpw_window;

// Window delegate: bridges a user-initiated title-bar close to the host's
// on_close callback. `suppress` is set when the HOST initiates the close
// (lpw_window_close), so the callback fires only for a user close — never a
// double detach.
@interface LpwWindowDelegate : NSObject <NSWindowDelegate> {
 @public
  lpw_close_cb cb;
  void* ctx;
  bool suppress;
  lpw_window* handle;
}
@end

// The handle holds its NSWindow / delegate as bridged-retained CFTypeRefs so a
// malloc'd C struct can own ObjC objects under ARC. In the embed spike
// (LOOPY_EDITOR_EMBED=1) there is no window: [embedded] is the container NSView
// added as a subview of the Loopy window, and [window]/[delegate] are null.
struct lpw_window {
  CFTypeRef window;    // NSWindow*
  CFTypeRef delegate;  // LpwWindowDelegate*
  CFTypeRef embedded;  // NSView* (embed spike only)
};

@implementation LpwWindowDelegate
- (void)windowWillClose:(NSNotification*)notification {
  (void)notification;
  if (suppress) return;  // host-driven close: lpw_window_close does the cleanup
  suppress = true;       // guard against re-entry
  if (cb) cb(ctx);       // the host detaches the plugin view now
  // Free the handle (releases the window + delegate) once this close
  // notification has fully unwound — releasing the window mid-notification is
  // unsafe. The window is already closed, so the deferred close is a no-op.
  lpw_window* h = handle;
  dispatch_async(dispatch_get_main_queue(), ^{
    lpw_window_close(h);
  });
}
@end

extern "C" {

// Centres [child] over [host] in the host window's content coordinates.
static NSRect lpw_center_in(NSView* host, int32_t width, int32_t height) {
  const NSRect b = [host bounds];
  return NSMakeRect((b.size.width - width) / 2.0, (b.size.height - height) / 2.0,
                    width, height);
}

lpw_window* lpw_window_open(int32_t width, int32_t height, const char* title,
                            lpw_close_cb on_close, void* ctx) {
  if (width <= 0) width = 400;
  if (height <= 0) height = 300;
  const NSRect frame = NSMakeRect(0, 0, width, height);

  // EMBED SPIKE (Option B viability): attach the plugin editor to a container
  // NSView placed INSIDE the Loopy window (a centred subview of its content
  // view) instead of a top-level window. Answers "does a plugin editor render
  // when embedded in the app's window at all?" — the make-or-break for a real
  // AppKitView platform-view embed. No titlebar/close (the host drives close).
  const char* embedEnv = std::getenv("LOOPY_EDITOR_EMBED");
  const bool embed = embedEnv && embedEnv[0] == '1';
  NSWindow* host = [NSApp mainWindow] ?: [NSApp keyWindow];
  if (embed && host) {
    NSView* root = [host contentView];
    NSView* container = [[NSView alloc] initWithFrame:frame];
    [container setWantsLayer:YES];
    [container setFrame:lpw_center_in(root, width, height)];
    [container setAutoresizingMask:NSViewMinXMargin | NSViewMaxXMargin |
                                   NSViewMinYMargin | NSViewMaxYMargin];
    [root addSubview:container];
    lpw_window* h = static_cast<lpw_window*>(std::calloc(1, sizeof(lpw_window)));
    if (!h) return nullptr;
    h->embedded = CFBridgingRetain(container);
    (void)on_close;  // no user-initiated close in embed mode
    (void)ctx;
    return h;
  }

  const NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskResizable |
                           NSWindowStyleMaskMiniaturizable;
  NSWindow* window =
      [[NSWindow alloc] initWithContentRect:frame
                                  styleMask:style
                                    backing:NSBackingStoreBuffered
                                      defer:NO];
  if (!window) return nullptr;
  // We own the window's lifetime via the bridged retain below; a self-releasing
  // window would dangle the handle.
  [window setReleasedWhenClosed:NO];
  if (title) {
    NSString* t = [NSString stringWithUTF8String:title];
    if (t) [window setTitle:t];
  }
  // SPIKE (Option A): anchor the editor as a centered popup OVER the Loopy
  // window instead of floating at screen-centre. At open time the editor is not
  // yet key, so NSApp.mainWindow is the Flutter (host) window. Attaching the
  // editor as a child window keeps it centred-over + above Loopy and moving
  // with it — the "popup inside the app" feel. NOTE (D-WIN): the header records
  // that child-windowing Flutter's window was previously avoided; this spike
  // deliberately exercises it. Falls back to screen-centre when there is no
  // host window (e.g. the native probe / headless harness).
  NSWindow* parent = [NSApp mainWindow] ?: [NSApp keyWindow];
  if (parent && parent != window) {
    const NSRect pf = [parent frame];
    NSRect wf = [window frame];
    wf.origin = NSMakePoint(pf.origin.x + (pf.size.width - wf.size.width) / 2.0,
                            pf.origin.y + (pf.size.height - wf.size.height) / 2.0);
    [window setFrame:wf display:NO];
    [parent addChildWindow:window ordered:NSWindowAbove];
  } else {
    [window center];
  }

  // A plain content view is the plugin's attach parent.
  NSView* content = [[NSView alloc] initWithFrame:frame];
  [window setContentView:content];  // window retains content

  LpwWindowDelegate* delegate = [[LpwWindowDelegate alloc] init];
  delegate->cb = on_close;
  delegate->ctx = ctx;
  delegate->suppress = false;
  [window setDelegate:delegate];  // weak — the handle keeps the strong ref

  lpw_window* handle =
      static_cast<lpw_window*>(std::calloc(1, sizeof(lpw_window)));
  if (!handle) {
    [window setDelegate:nil];
    return nullptr;
  }
  handle->window = CFBridgingRetain(window);      // handle owns +1
  handle->delegate = CFBridgingRetain(delegate);  // handle owns +1
  delegate->handle = handle;  // for the deferred free on a user close
  return handle;
}

void* lpw_window_content_view(lpw_window* window) {
  if (!window) return nullptr;
  if (window->embedded) {
    NSView* v = (__bridge NSView*)window->embedded;
    return (__bridge void*)v;
  }
  if (!window->window) return nullptr;
  NSWindow* w = (__bridge NSWindow*)window->window;
  return (__bridge void*)[w contentView];
}

void lpw_window_resize(lpw_window* window, int32_t width, int32_t height) {
  if (!window || width <= 0 || height <= 0) return;
  if (window->embedded) {
    NSView* v = (__bridge NSView*)window->embedded;
    NSView* super = [v superview];
    [v setFrame:super ? lpw_center_in(super, width, height)
                      : NSMakeRect(0, 0, width, height)];
    return;
  }
  if (!window->window) return;
  NSWindow* w = (__bridge NSWindow*)window->window;
  const NSRect newContent = NSMakeRect(0, 0, width, height);
  NSRect frame = [w frameRectForContentRect:newContent];
  const NSRect current = [w frame];
  // Keep the window's top-left corner fixed while it grows/shrinks.
  frame.origin.x = current.origin.x;
  frame.origin.y =
      current.origin.y + current.size.height - frame.size.height;
  [w setFrame:frame display:YES];
}

void lpw_window_show(lpw_window* window) {
  if (!window) return;
  if (window->embedded) return;  // already in the view tree
  if (!window->window) return;
  NSWindow* w = (__bridge NSWindow*)window->window;
  [w makeKeyAndOrderFront:nil];
}

void lpw_window_close(lpw_window* window) {
  if (!window) return;
  if (window->embedded) {
    NSView* v = (__bridge NSView*)window->embedded;
    [v removeFromSuperview];
    CFBridgingRelease(window->embedded);  // drops the handle's +1
    window->embedded = nullptr;
    std::free(window);
    return;
  }
  // Host-driven close: suppress the delegate callback (the caller is already in
  // teardown) and detach the delegate before releasing.
  if (window->delegate) {
    LpwWindowDelegate* d = (__bridge LpwWindowDelegate*)window->delegate;
    d->suppress = true;
  }
  if (window->window) {
    NSWindow* w = (__bridge NSWindow*)window->window;
    [w setDelegate:nil];
    [w close];
    CFBridgingRelease(window->window);  // drops the handle's +1
    window->window = nullptr;
  }
  if (window->delegate) {
    CFBridgingRelease(window->delegate);  // drops the handle's +1
    window->delegate = nullptr;
  }
  std::free(window);
}

}  // extern "C"

#endif  // LOOPY_ENABLE_PLUGINS && __APPLE__
