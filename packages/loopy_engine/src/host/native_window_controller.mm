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
  CFTypeRef window;      // NSWindow*
  CFTypeRef delegate;    // LpwWindowDelegate* or LpwCloseTarget* (embed)
  CFTypeRef embedded;    // NSView* scrim backdrop (embed mode)
  CFTypeRef container;   // NSView* the plugin attaches to (embed mode)
  CFTypeRef keyMonitor;  // id, local Escape monitor (embed mode)
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

// Close-button target for the embedded popup — mirrors the window delegate's
// user-close path: fire on_close (host detaches the plugin) then defer the free.
@interface LpwCloseTarget : NSObject {
 @public
  lpw_close_cb cb;
  void* ctx;
  bool suppress;
  lpw_window* handle;
}
- (void)onClose:(id)sender;
@end

@implementation LpwCloseTarget
- (void)onClose:(id)sender {
  (void)sender;
  if (suppress) return;
  suppress = true;
  if (cb) cb(ctx);  // host detaches the plugin view now
  lpw_window* h = handle;
  dispatch_async(dispatch_get_main_queue(), ^{
    lpw_window_close(h);
  });
}
@end

// The scrim backdrop: a click on the dimmed area (outside the centred plugin
// panel, whose subviews get their own clicks first) dismisses the popup, like a
// modal barrier. The plugin panel + close button are subviews, so clicks on
// them never reach this.
@interface LpwScrimView : NSView {
 @public
  // Not owned by the scrim (the handle owns the target); no retain cycle since
  // the target never points back at the scrim. Plain pointer so the file still
  // compiles under manual reference counting (the native test harness).
  LpwCloseTarget* closeTarget;
}
@end

@implementation LpwScrimView
- (void)mouseDown:(NSEvent*)event {
  (void)event;
  if (closeTarget) [closeTarget onClose:nil];
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
  // Default: embed the editor INSIDE the Loopy window. LOOPY_EDITOR_EMBED=0
  // forces the old top-level window (fallback / debugging).
  const char* embedEnv = std::getenv("LOOPY_EDITOR_EMBED");
  const bool embed = !(embedEnv && embedEnv[0] == '0');
  NSWindow* host = [NSApp mainWindow] ?: [NSApp keyWindow];
  if (embed && host) {
    NSView* root = [host contentView];
    const NSRect rb = [root bounds];

    LpwCloseTarget* target = [[LpwCloseTarget alloc] init];
    target->cb = on_close;
    target->ctx = ctx;
    target->suppress = false;

    // Full-window scrim so the embedded editor reads as a modal popup and eats
    // clicks to the app behind it; a click on the scrim dismisses it.
    LpwScrimView* backdrop = [[LpwScrimView alloc] initWithFrame:rb];
    backdrop->closeTarget = target;
    [backdrop setWantsLayer:YES];
    backdrop.layer.backgroundColor =
        [[NSColor colorWithCalibratedWhite:0 alpha:0.5] CGColor];
    [backdrop setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    // The plugin's attach parent — a centred, rounded panel. Tagged so the
    // accessors below can find it under the backdrop.
    NSView* container =
        [[NSView alloc] initWithFrame:lpw_center_in(root, width, height)];
    [container setWantsLayer:YES];
    container.layer.backgroundColor =
        [[NSColor colorWithCalibratedWhite:0.09 alpha:1] CGColor];
    container.layer.cornerRadius = 6;
    container.layer.masksToBounds = YES;
    [container setAutoresizingMask:NSViewMinXMargin | NSViewMaxXMargin |
                                   NSViewMinYMargin | NSViewMaxYMargin];
    [backdrop addSubview:container];

    // A close button pinned to the scrim's top-right (kept out of the plugin's
    // own rect so it never overlaps a plugin control).
    NSButton* close = [NSButton buttonWithTitle:@"✕"
                                         target:target
                                         action:@selector(onClose:)];
    [close setBezelStyle:NSBezelStyleCircular];
    [close setFrame:NSMakeRect(rb.size.width - 40, rb.size.height - 40, 28, 28)];
    [close setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [backdrop addSubview:close];

    [root addSubview:backdrop];

    lpw_window* h = static_cast<lpw_window*>(std::calloc(1, sizeof(lpw_window)));
    if (!h) return nullptr;
    h->embedded = CFBridgingRetain(backdrop);   // handle owns +1
    h->container = CFBridgingRetain(container);  // handle owns +1
    h->delegate = CFBridgingRetain(target);     // handle owns +1
    target->handle = h;                          // for the deferred free

    // Escape dismisses the popup, whatever has focus (the plugin's own view
    // may be first responder). A local monitor intercepts the key before it
    // reaches the focused view, for as long as the popup is open.
    id keyMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                     handler:^NSEvent*(NSEvent* e) {
                                       if ([e keyCode] == 53) {  // Escape
                                         [target onClose:nil];
                                         return nil;  // consume it
                                       }
                                       return e;
                                     }];
    h->keyMonitor = CFBridgingRetain(keyMonitor);
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
  if (window->container) {
    // The plugin attaches to the centred container, not the scrim backdrop.
    NSView* container = (__bridge NSView*)window->container;
    return (__bridge void*)container;
  }
  if (!window->window) return nullptr;
  NSWindow* w = (__bridge NSWindow*)window->window;
  return (__bridge void*)[w contentView];
}

void lpw_window_resize(lpw_window* window, int32_t width, int32_t height) {
  if (!window || width <= 0 || height <= 0) return;
  if (window->container) {
    // Grow the centred container (the scrim backdrop stays full-window).
    NSView* container = (__bridge NSView*)window->container;
    NSView* backdrop = [container superview];
    if (backdrop) [container setFrame:lpw_center_in(backdrop, width, height)];
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
    // Suppress a re-entrant close-button action while we tear down.
    if (window->delegate) {
      LpwCloseTarget* t = (__bridge LpwCloseTarget*)window->delegate;
      t->suppress = true;
    }
    if (window->keyMonitor) {
      id m = (__bridge id)window->keyMonitor;
      [NSEvent removeMonitor:m];
      CFBridgingRelease(window->keyMonitor);
      window->keyMonitor = nullptr;
    }
    NSView* backdrop = (__bridge NSView*)window->embedded;
    [backdrop removeFromSuperview];  // drops the container + close button too
    CFBridgingRelease(window->embedded);  // drops the handle's +1
    window->embedded = nullptr;
    if (window->container) {
      CFBridgingRelease(window->container);  // drops the handle's +1
      window->container = nullptr;
    }
    if (window->delegate) {
      CFBridgingRelease(window->delegate);  // drops the handle's +1
      window->delegate = nullptr;
    }
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
