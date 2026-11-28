// SXApp.mm
// Browser-process CefApp implementation with strict anti-guardrail compliance
// and native AppKit message-pump integration.

#import "SXApp.h"
#import "SXExtensionManager.h"
#import "SXInternal.h"
#import "SXMediaTranscodeServer.h"
#import "SXPrivacyEngine.h"

#include <unordered_map>

#include "include/base/cef_callback.h"
#include "include/cef_client.h"
#include "include/cef_display_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_helpers.h"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <atomic>
#include <mutex>
#include <unordered_set>

static const void *kSXStealthHiddenWindowKey = &kSXStealthHiddenWindowKey;
static const void *kSXNativeDialogProbingKey = &kSXNativeDialogProbingKey;
static const void *kSXNativeDialogReplacedKey = &kSXNativeDialogReplacedKey;
static std::atomic<int> gSXHiddenChromeWindowCreationDepth{0};

static BOOL SXIsWindowNativeDialogReplaced(NSWindow * _Nullable w) {
  if (!w) return NO;
  return [objc_getAssociatedObject(w, kSXNativeDialogReplacedKey) boolValue];
}

static BOOL SXIsWindowNativeDialogProbing(NSWindow * _Nullable w) {
  if (!w) return NO;
  return [objc_getAssociatedObject(w, kSXNativeDialogProbingKey) boolValue];
}

static BOOL SXIsChromiumNativeWindow(NSWindow * _Nullable w) {
  if (!w) return NO;
  NSString *cls = NSStringFromClass([w class]);
  return [cls containsString:@"NativeWidgetMacNSWindow"] ||
         [cls containsString:@"BrowserNativeWidget"] ||
         [cls containsString:@"ChromeBrowser"];
}

static BOOL SXIsDevToolsChromeWindow(NSWindow * _Nullable w) {
  if (!w) return NO;
  NSString *title = w.title ?: @"";
  return [title rangeOfString:@"DevTools" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL SXIsWindowStealthLocked(NSWindow * _Nullable w) {
  if (!w) return NO;
  return [objc_getAssociatedObject(w, kSXStealthHiddenWindowKey) boolValue];
}

static BOOL SXShouldStealthBlockWindow(NSWindow * _Nullable w) {
  if (!w) return NO;
  if (SXIsWindowStealthLocked(w)) return YES;
  if (!SXIsChromiumNativeWindow(w) || SXIsDevToolsChromeWindow(w)) return NO;

  if (gSXHiddenChromeWindowCreationDepth.load(std::memory_order_acquire) > 0) {
    SXLockWindowPermanentlyHidden(w);
    return YES;
  }
  NSString *title = w.title ?: @"";
  if ([title rangeOfString:@"Extensions" options:NSCaseInsensitiveSearch].location != NSNotFound ||
      [title rangeOfString:@"Chromium" options:NSCaseInsensitiveSearch].location != NSNotFound) {
    SXLockWindowPermanentlyHidden(w);
    return YES;
  }
  return NO;
}

@interface NSWindow (SXStealthBlocker)
- (void)sx_orderWindow:(NSWindowOrderingMode)place relativeTo:(NSInteger)otherWin;
- (void)sx_makeKeyAndOrderFront:(nullable id)sender;
- (void)sx_orderFront:(nullable id)sender;
- (void)sx_orderFrontRegardless;
- (void)sx_deminiaturize:(nullable id)sender;
- (void)sx_setAlphaValue:(CGFloat)alphaValue;
- (NSRect)sx_constrainFrameRect:(NSRect)frameRect toScreen:(nullable NSScreen *)screen;
- (BOOL)sx_canBecomeKeyWindow;
- (BOOL)sx_canBecomeMainWindow;
- (BOOL)sx_isExcludedFromWindowsMenu;
@end

static NSString * _Nullable SXAXStringAttribute(id el, SEL sel) {
  if (!el || ![el respondsToSelector:sel]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  id val = [el performSelector:sel];
#pragma clang diagnostic pop
  if ([val isKindOfClass:[NSString class]]) {
    NSString *trimmed = [(NSString *)val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? trimmed : nil;
  }
  return nil;
}

static void SXCollectChromiumDialogAX(id _Nullable el,
                                      int depth,
                                      NSHashTable *visited,
                                      NSMutableArray<NSString *> *texts,
                                      NSMutableSet<NSString *> *seenTexts,
                                      NSMutableArray<NSDictionary *> *buttons) {
  if (!el || depth > 14 || [visited containsObject:el]) return;
  [visited addObject:el];

  NSString *role = SXAXStringAttribute(el, @selector(accessibilityRole));
  if ([role isEqualToString:NSAccessibilityStaticTextRole] ||
      [role isEqualToString:@"AXHeading"]) {
    NSString *txt = SXAXStringAttribute(el, @selector(accessibilityValue))
                 ?: SXAXStringAttribute(el, @selector(accessibilityTitle))
                 ?: SXAXStringAttribute(el, @selector(accessibilityLabel));
    if (txt.length > 0 && ![seenTexts containsObject:txt]) {
      [seenTexts addObject:txt];
      [texts addObject:txt];
    }
  } else if ([role isEqualToString:NSAccessibilityButtonRole]) {
    NSString *title = SXAXStringAttribute(el, @selector(accessibilityTitle))
                   ?: SXAXStringAttribute(el, @selector(accessibilityLabel));
    if (title.length > 0) {
      [buttons addObject:@{@"title": title, @"element": el}];
    }
  }

  if ([el respondsToSelector:@selector(accessibilityChildren)]) {
    NSArray *children = [el accessibilityChildren];
    if ([children isKindOfClass:[NSArray class]]) {
      for (id child in children) {
        SXCollectChromiumDialogAX(child, depth + 1, visited, texts, seenTexts, buttons);
      }
    }
  }
}

static BOOL SXIsCancelLikeButtonTitle(NSString *title) {
  NSString *low = title.lowercaseString;
  return [low isEqualToString:@"deny"] ||
         [low isEqualToString:@"cancel"] ||
         [low isEqualToString:@"don't allow"] ||
         [low isEqualToString:@"do not allow"] ||
         [low isEqualToString:@"block"] ||
         [low isEqualToString:@"close"] ||
         [low isEqualToString:@"no"];
}

static NSImage * _Nullable SXLoadHighResManifestIcon(NSString * _Nullable installPath) {
  if (installPath.length == 0) return nil;
  NSString *manifestPath = [installPath stringByAppendingPathComponent:@"manifest.json"];
  NSData *data = [NSData dataWithContentsOfFile:manifestPath];
  if (!data) return nil;
  NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![manifest isKindOfClass:[NSDictionary class]]) return nil;
  id iconsObj = manifest[@"icons"];
  NSString *bestRel = nil;
  if ([iconsObj isKindOfClass:[NSString class]]) {
    bestRel = iconsObj;
  } else if ([iconsObj isKindOfClass:[NSDictionary class]]) {
    NSDictionary *icons = (NSDictionary *)iconsObj;
    // Prefer high-resolution icons for 64pt (128px @2x) NSAlert display.
    for (NSString *sizeKey in @[ @"256", @"128", @"96", @"64", @"48" ]) {
      NSString *cand = icons[sizeKey];
      if ([cand isKindOfClass:[NSString class]] && cand.length > 0) {
        bestRel = cand;
        break;
      }
    }
    if (!bestRel) {
      NSInteger maxSz = -1;
      for (id k in icons) {
        NSString *cand = icons[k];
        if (![cand isKindOfClass:[NSString class]] || cand.length == 0) continue;
        NSInteger sz = [k respondsToSelector:@selector(integerValue)] ? [k integerValue] : 0;
        if (sz > maxSz) {
          maxSz = sz;
          bestRel = cand;
        }
      }
    }
  }
  if (bestRel.length == 0) return nil;
  NSString *cleanRel = [bestRel stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
  NSString *fullPath = [installPath stringByAppendingPathComponent:cleanRel];
  NSImage *img = [[NSImage alloc] initWithContentsOfFile:fullPath];
  if (img) {
    img.size = NSMakeSize(64, 64);
  }
  return img;
}

static NSImage * _Nullable SXLookupExtensionIconForMessage(NSString *message) {
  if (message.length == 0) return nil;
  NSArray<SXExtensionItem *> *items = [[SXExtensionManager sharedManager] installedExtensions];
  for (SXExtensionItem *item in items) {
    if (item.name.length > 0 &&
        [message rangeOfString:item.name options:NSCaseInsensitiveSearch].location != NSNotFound) {
      NSImage *hiRes = SXLoadHighResManifestIcon(item.installPath);
      if (hiRes) return hiRes;
      if (item.icon) return item.icon;
    }
  }
  return nil;
}

static BOOL SXIsCandidateChromiumModalDialog(NSWindow * _Nullable w) {
  if (!w) return NO;
  if (!SXIsChromiumNativeWindow(w) || SXIsDevToolsChromeWindow(w)) return NO;
  if (SXIsWindowStealthLocked(w) || SXIsWindowNativeDialogReplaced(w) || SXIsWindowNativeDialogProbing(w)) return NO;
  NSSize sz = w.frame.size;
  BOOL dialogSized = (sz.width >= 160 && sz.width <= 720 && sz.height >= 90 && sz.height <= 640);
  BOOL attached = (w.parentWindow != nil || w.sheetParent != nil);
  return attached || dialogSized;
}

static void SXTryReplaceChromiumDialogWithNativeAlert(NSWindow *chromeWin, int attempt) {
  if (!chromeWin || !chromeWin.isVisible) {
    objc_setAssociatedObject(chromeWin, kSXNativeDialogProbingKey, nil, OBJC_ASSOCIATION_ASSIGN);
    return;
  }

  NSMutableArray<NSString *> *texts = [NSMutableArray array];
  NSMutableSet<NSString *> *seenTexts = [NSMutableSet set];
  NSMutableArray<NSDictionary *> *rawButtons = [NSMutableArray array];
  NSHashTable *visited = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
  SXCollectChromiumDialogAX(chromeWin, 0, visited, texts, seenTexts, rawButtons);

  // Filter out window chrome "Close" buttons when real dialog action buttons exist.
  NSMutableArray<NSDictionary *> *actionButtons = [NSMutableArray array];
  for (NSDictionary *b in rawButtons) {
    NSString *t = b[@"title"];
    if (![t.lowercaseString isEqualToString:@"close"]) {
      [actionButtons addObject:b];
    }
  }
  if (actionButtons.count == 0) {
    actionButtons = rawButtons;
  }

  if ((texts.count == 0 || actionButtons.count == 0) && attempt < 4) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
      SXTryReplaceChromiumDialogWithNativeAlert(chromeWin, attempt + 1);
    });
    return;
  }

  objc_setAssociatedObject(chromeWin, kSXNativeDialogProbingKey, nil, OBJC_ASSOCIATION_ASSIGN);

  if (texts.count == 0 || actionButtons.count == 0) {
    // Not a standard button dialog — restore visibility cleanly.
    [chromeWin sx_setAlphaValue:1.0];
    [chromeWin setIgnoresMouseEvents:NO];
    return;
  }

  // Order the ugly clipped Chromium dialog completely out of WindowServer and park it
  // offscreen (unconstrained) so zero pixels can ever appear at the bottom-left screen edge,
  // while keeping its widget alive until our native NSAlert button invokes Chromium's callback.
  objc_setAssociatedObject(chromeWin, kSXNativeDialogReplacedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [chromeWin sx_setAlphaValue:0.0];
  [chromeWin setIgnoresMouseEvents:YES];
  [chromeWin setExcludedFromWindowsMenu:YES];
  [chromeWin setCollectionBehavior:NSWindowCollectionBehaviorTransient |
                                   NSWindowCollectionBehaviorIgnoresCycle |
                                   NSWindowCollectionBehaviorStationary];
  [chromeWin setSharingType:NSWindowSharingNone];
  [chromeWin setFrame:NSMakeRect(-30000, -30000, 1, 1) display:NO];
  [chromeWin sx_orderWindow:NSWindowOut relativeTo:0];
  [NSApp removeWindowsItem:chromeWin];

  NSString *headline = texts[0];
  NSMutableArray<NSString *> *bodyLines = [NSMutableArray array];
  BOOL inBulletList = NO;
  for (NSUInteger i = 1; i < texts.count; ++i) {
    NSString *line = texts[i];
    if ([line hasSuffix:@":"]) {
      inBulletList = YES;
      [bodyLines addObject:line];
    } else if (inBulletList) {
      [bodyLines addObject:[NSString stringWithFormat:@"• %@", line]];
    } else {
      [bodyLines addObject:line];
    }
  }

  // Put positive/primary action first (accented Liquid Glass default button on right in NSAlert),
  // and Deny/Cancel second (Escape key).
  NSMutableArray<NSDictionary *> *primaryBtns = [NSMutableArray array];
  NSMutableArray<NSDictionary *> *cancelBtns = [NSMutableArray array];
  for (NSDictionary *b in actionButtons) {
    if (SXIsCancelLikeButtonTitle(b[@"title"])) {
      [cancelBtns addObject:b];
    } else {
      [primaryBtns addObject:b];
    }
  }
  NSMutableArray<NSDictionary *> *orderedButtons = [NSMutableArray arrayWithArray:primaryBtns];
  [orderedButtons addObjectsFromArray:cancelBtns];

  NSAlert *alert = [[NSAlert alloc] init];
  alert.alertStyle = NSAlertStyleInformational;
  alert.messageText = headline;
  alert.informativeText = [bodyLines componentsJoinedByString:@"\n"];
  NSImage *extIcon = SXLookupExtensionIconForMessage(headline);
  if (extIcon) {
    alert.icon = extIcon;
  }
  for (NSDictionary *b in orderedButtons) {
    NSButton *nsBtn = [alert addButtonWithTitle:b[@"title"]];
    if (SXIsCancelLikeButtonTitle(b[@"title"])) {
      nsBtn.keyEquivalent = @"\033";
    }
  }

  NSWindow *hostWindow = chromeWin.parentWindow ?: chromeWin.sheetParent;
  if (!hostWindow || SXIsChromiumNativeWindow(hostWindow)) {
    hostWindow = NSApp.mainWindow ?: NSApp.keyWindow;
    if (SXIsChromiumNativeWindow(hostWindow)) {
      hostWindow = nil;
      for (NSWindow *cand in NSApp.windows) {
        if (cand.isVisible && !SXIsChromiumNativeWindow(cand)) {
          hostWindow = cand;
          break;
        }
      }
    }
  }

  void (^handleResponse)(NSModalResponse) = ^(NSModalResponse response) {
    NSInteger idx = (NSInteger)(response - NSAlertFirstButtonReturn);
    id axBtn = (idx >= 0 && idx < (NSInteger)orderedButtons.count) ? orderedButtons[idx][@"element"] : nil;
    if (axBtn && [axBtn respondsToSelector:@selector(accessibilityPerformPress)]) {
      [axBtn accessibilityPerformPress];
    } else if (chromeWin.isVisible) {
      [chromeWin close];
    }
  };

  if (getenv("SAFARIUM_CEF_DEBUG")) {
    fprintf(stderr, "[NativeDialog] Intercepted Chromium dialog: headline='%s' bodyLines=%lu buttons=%lu sheetParent=%p parent=%p\n",
            headline.UTF8String, (unsigned long)bodyLines.count, (unsigned long)orderedButtons.count,
            (__bridge void *)chromeWin.sheetParent, (__bridge void *)chromeWin.parentWindow);
    fflush(stderr);
  }

  if (hostWindow && hostWindow.attachedSheet == nil) {
    [alert beginSheetModalForWindow:hostWindow completionHandler:handleResponse];
  } else {
    handleResponse([alert runModal]);
  }
}

@implementation NSWindow (SXStealthBlocker)

- (void)sx_orderWindow:(NSWindowOrderingMode)place relativeTo:(NSInteger)otherWin {
  if (place != NSWindowOut && SXShouldStealthBlockWindow(self)) {
    [self sx_setAlphaValue:0.0];
    [self sx_orderWindow:NSWindowOut relativeTo:0];
    return;
  }
  if (place != NSWindowOut && SXIsWindowNativeDialogReplaced(self)) {
    [self sx_setAlphaValue:0.0];
    return;
  }
  if (place != NSWindowOut && SXIsCandidateChromiumModalDialog(self)) {
    objc_setAssociatedObject(self, kSXNativeDialogProbingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self sx_setAlphaValue:0.0];
    [self setIgnoresMouseEvents:YES];
    [self sx_orderWindow:place relativeTo:otherWin];
    dispatch_async(dispatch_get_main_queue(), ^{
      SXTryReplaceChromiumDialogWithNativeAlert(self, 0);
    });
    return;
  }
  [self sx_orderWindow:place relativeTo:otherWin];
}

- (void)sx_makeKeyAndOrderFront:(nullable id)sender {
  if (SXShouldStealthBlockWindow(self)) {
    [self sx_orderWindow:NSWindowOut relativeTo:0];
    return;
  }
  [self sx_makeKeyAndOrderFront:sender];
}

- (void)sx_orderFront:(nullable id)sender {
  if (SXShouldStealthBlockWindow(self)) {
    [self sx_orderWindow:NSWindowOut relativeTo:0];
    return;
  }
  [self sx_orderFront:sender];
}

- (void)sx_orderFrontRegardless {
  if (SXShouldStealthBlockWindow(self)) {
    [self sx_orderWindow:NSWindowOut relativeTo:0];
    return;
  }
  [self sx_orderFrontRegardless];
}

- (void)sx_deminiaturize:(nullable id)sender {
  if (SXShouldStealthBlockWindow(self)) {
    return;
  }
  [self sx_deminiaturize:sender];
}

- (void)sx_setAlphaValue:(CGFloat)alphaValue {
  if (SXShouldStealthBlockWindow(self) || SXIsWindowNativeDialogReplaced(self) || SXIsWindowNativeDialogProbing(self)) {
    [self sx_setAlphaValue:0.0];
    return;
  }
  [self sx_setAlphaValue:alphaValue];
}

- (NSRect)sx_constrainFrameRect:(NSRect)frameRect toScreen:(nullable NSScreen *)screen {
  if (SXShouldStealthBlockWindow(self) || SXIsWindowNativeDialogReplaced(self)) {
    return frameRect;
  }
  return [self sx_constrainFrameRect:frameRect toScreen:screen];
}

- (BOOL)sx_canBecomeKeyWindow {
  if (SXShouldStealthBlockWindow(self) || SXIsWindowNativeDialogReplaced(self)) return NO;
  return [self sx_canBecomeKeyWindow];
}

- (BOOL)sx_canBecomeMainWindow {
  if (SXShouldStealthBlockWindow(self) || SXIsWindowNativeDialogReplaced(self)) return NO;
  return [self sx_canBecomeMainWindow];
}

- (BOOL)sx_isExcludedFromWindowsMenu {
  if (SXShouldStealthBlockWindow(self) || SXIsWindowNativeDialogReplaced(self)) return YES;
  return [self sx_isExcludedFromWindowsMenu];
}

@end

static void SXSwizzleNSWindowMethod(SEL origSel, SEL swizzledSel) {
  Class cls = [NSWindow class];
  Method orig = class_getInstanceMethod(cls, origSel);
  Method swizzled = class_getInstanceMethod(cls, swizzledSel);
  if (orig && swizzled) {
    method_exchangeImplementations(orig, swizzled);
  }
}

void SXInstallStealthWindowBlocker(void) {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    SXSwizzleNSWindowMethod(@selector(orderWindow:relativeTo:), @selector(sx_orderWindow:relativeTo:));
    SXSwizzleNSWindowMethod(@selector(makeKeyAndOrderFront:), @selector(sx_makeKeyAndOrderFront:));
    SXSwizzleNSWindowMethod(@selector(orderFront:), @selector(sx_orderFront:));
    SXSwizzleNSWindowMethod(@selector(orderFrontRegardless), @selector(sx_orderFrontRegardless));
    SXSwizzleNSWindowMethod(@selector(deminiaturize:), @selector(sx_deminiaturize:));
    SXSwizzleNSWindowMethod(@selector(setAlphaValue:), @selector(sx_setAlphaValue:));
    SXSwizzleNSWindowMethod(@selector(constrainFrameRect:toScreen:), @selector(sx_constrainFrameRect:toScreen:));
    SXSwizzleNSWindowMethod(@selector(canBecomeKeyWindow), @selector(sx_canBecomeKeyWindow));
    SXSwizzleNSWindowMethod(@selector(canBecomeMainWindow), @selector(sx_canBecomeMainWindow));
    SXSwizzleNSWindowMethod(@selector(isExcludedFromWindowsMenu), @selector(sx_isExcludedFromWindowsMenu));
  });
}

void SXLockWindowPermanentlyHidden(NSWindow * _Nullable window) {
  if (!window) return;
  SXInstallStealthWindowBlocker();
  BOOL alreadyLocked = SXIsWindowStealthLocked(window);
  objc_setAssociatedObject(window, kSXStealthHiddenWindowKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (alreadyLocked) {
    [window sx_setAlphaValue:0.0];
    [window sx_orderWindow:NSWindowOut relativeTo:0];
    return;
  }
  [window setExcludedFromWindowsMenu:YES];
  [window setCollectionBehavior:NSWindowCollectionBehaviorTransient |
                                NSWindowCollectionBehaviorIgnoresCycle |
                                NSWindowCollectionBehaviorStationary];
  [window setSharingType:NSWindowSharingNone];
  [window setIgnoresMouseEvents:YES];
  [window setCanHide:NO];
  [window setHidesOnDeactivate:NO];
  if ([window respondsToSelector:@selector(setAccessibilityElement:)]) {
    [window setAccessibilityElement:NO];
  }
  [window setFrame:NSMakeRect(-30000, -30000, 100, 100) display:NO];
  [window sx_setAlphaValue:0.0];
  [window sx_orderWindow:NSWindowOut relativeTo:0];
  [NSApp removeWindowsItem:window];
}

void SXBeginHiddenChromeWindowCreation(void) {
  SXInstallStealthWindowBlocker();
  gSXHiddenChromeWindowCreationDepth.fetch_add(1, std::memory_order_acq_rel);
}

void SXEndHiddenChromeWindowCreation(void) {
  int prev = gSXHiddenChromeWindowCreationDepth.fetch_sub(1, std::memory_order_acq_rel);
  if (prev <= 0) {
    gSXHiddenChromeWindowCreationDepth.store(0, std::memory_order_release);
  }
}

namespace {

static void SXHideRogueWindow(CefRefPtr<CefBrowser> browser) {
  if (!browser || !browser->GetHost()) return;
  NSView *v = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
  if (v && v.window) {
    NSWindow *w = v.window;
    SXLockWindowPermanentlyHidden(w);
    dispatch_async(dispatch_get_main_queue(), ^{
      SXLockWindowPermanentlyHidden(w);
    });
  }
}

/// Traps ANY unexpected Chrome-style top-level browser window (for example from
/// `chrome.runtime.openOptionsPage()`, extension service worker `chrome.tabs.create()`,
/// or Chrome UI popups), immediately hides & closes the rogue Chrome window, and
/// routes the target URL into a native Safarium tab via `SXEngineRuntimeRequestNewTabNotification`.
class SXRogueChromeWindowTrapClient : public CefClient,
                                      public CefLifeSpanHandler,
                                      public CefDisplayHandler,
                                      public CefRequestHandler {
 public:
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  void HideAndCloseRogueBrowser(CefRefPtr<CefBrowser> browser, const std::string& urlStr) {
    CEF_REQUIRE_UI_THREAD();
    if (!browser) return;
    if (urlStr.rfind("devtools://", 0) == 0) {
      return;
    }
    int bid = browser->GetIdentifier();
    if (getenv("SAFARIUM_CEF_DEBUG")) {
      fprintf(stderr, "[RogueChromeTrap] bid=%d url=%s\n", bid, urlStr.c_str());
      fflush(stderr);
    }

    // Remember the size Chrome gave the window (chrome.windows.create width/height) before hiding moves it
    // offscreen at 100x100: an extension popout is re-created at that size.
    {
      std::lock_guard<std::mutex> lock(mu_);
      if (!window_sizes_.count(bid) && browser->GetHost()) {
        NSView *v = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
        NSSize size = v.window ? [v.window contentRectForFrameRect:v.window.frame].size : NSZeroSize;
        if (size.width > 120 && size.height > 120) window_sizes_[bid] = size;
      }
    }

    // Hide the rogue NSWindow immediately so zero raw Chrome frames ever flash on screen.
    SXHideRogueWindow(browser);

    bool shouldForward = false;
    if (!urlStr.empty() && urlStr != "about:blank") {
      std::lock_guard<std::mutex> lock(mu_);
      if (forwarded_ids_.insert(bid).second) {
        shouldForward = true;
      }
    }

    if (shouldForward) {
      NSString *nsStr = [NSString stringWithUTF8String:urlStr.c_str()];
      NSURL *url = nsStr.length > 0 ? [NSURL URLWithString:nsStr] : nil;
      // An extension's own page in a small window is `chrome.windows.create({type: 'popup'})` (Bitwarden's item
      // pop-out, password generator, ...): open it as Safarium's native extension popout window. It used to be
      // forwarded as a tab request, which never showed up, so the extension's pop-out buttons did nothing.
      NSSize size = NSZeroSize;
      {
        std::lock_guard<std::mutex> lock(mu_);
        auto it = window_sizes_.find(bid);
        if (it != window_sizes_.end()) size = it->second;
      }
      bool isExtensionPage = [url.scheme isEqualToString:@"chrome-extension"] && url.host.length > 0;
      bool looksLikePopout = size.width > 0 && size.width <= 900;
      if (getenv("SAFARIUM_CEF_DEBUG")) {
        fprintf(stderr, "[RogueChromeTrap] forward bid=%d ext=%d size=%.0fx%.0f\n", bid, isExtensionPage ? 1 : 0,
                size.width, size.height);
        fflush(stderr);
      }
      if (url && isExtensionPage && looksLikePopout) {
        NSString *extId = url.host;
        CGFloat w = size.width, h = size.height;
        dispatch_async(dispatch_get_main_queue(), ^{
          [[SXExtensionManager sharedManager] openPopoutWindowForExtensionID:extId
                                                                         url:url
                                                                       width:w
                                                                      height:h
                                                                        left:-1
                                                                         top:-1];
        });
      } else if (url) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [[SXEngineRuntime sharedRuntime] postNewTabRequestForURL:url];
        });
      }
      if (browser->GetHost()) {
        browser->GetHost()->CloseBrowser(true);
      }
    }
  }

  void ForceCloseIfStillAlive(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    if (!browser || !browser->GetHost()) return;
    SXHideRogueWindow(browser);
    browser->GetHost()->CloseBrowser(true);
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    [[SXEngineRuntime sharedRuntime] noteBrowserCreated];
    if (!browser) return;
    std::string urlStr;
    if (browser->GetMainFrame()) {
      urlStr = browser->GetMainFrame()->GetURL().ToString();
    }
    HideAndCloseRogueBrowser(browser, urlStr);
    // Safety net: if a rogue Chrome browser stays at about:blank and never triggers
    // OnBeforeBrowse/OnAddressChange, close it automatically within 800ms.
    if (urlStr.empty() || urlStr == "about:blank") {
      CefRefPtr<SXRogueChromeWindowTrapClient> selfRef(this);
      CefPostDelayedTask(
          TID_UI,
          CefCreateClosureTask(base::BindOnce(
              &SXRogueChromeWindowTrapClient::ForceCloseIfStillAlive, selfRef,
              browser)),
          800);
    }
  }

  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override {
    CEF_REQUIRE_UI_THREAD();
    if (!frame || !frame->IsMain() || !request) return false;
    std::string urlStr = request->GetURL().ToString();
    if (!urlStr.empty() && urlStr != "about:blank") {
      HideAndCloseRogueBrowser(browser, urlStr);
      return true;  // Cancel load in rogue Chrome window.
    }
    return false;
  }

  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        const CefString& target_url,
                        WindowOpenDisposition target_disposition,
                        bool user_gesture) override {
    CEF_REQUIRE_UI_THREAD();
    std::string urlStr = target_url.ToString();
    if (!urlStr.empty() && urlStr != "about:blank") {
      HideAndCloseRogueBrowser(browser, urlStr);
      return true;
    }
    return false;
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    CEF_REQUIRE_UI_THREAD();
    if (!frame || !frame->IsMain()) return;
    HideAndCloseRogueBrowser(browser, url.ToString());
  }

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString& target_url,
                     const CefString& target_frame_name,
                     WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures& popupFeatures,
                     CefWindowInfo& windowInfo,
                     CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override {
    CEF_REQUIRE_UI_THREAD();
    std::string urlStr = target_url.ToString();
    if (!urlStr.empty()) {
      NSString *nsStr = [NSString stringWithUTF8String:urlStr.c_str()];
      NSURL *url = nsStr.length > 0 ? [NSURL URLWithString:nsStr] : nil;
      if (url) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [[SXEngineRuntime sharedRuntime] postNewTabRequestForURL:url];
        });
      }
    }
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    [[SXEngineRuntime sharedRuntime] noteBrowserClosed];
    if (!browser) return;
    std::lock_guard<std::mutex> lock(mu_);
    forwarded_ids_.erase(browser->GetIdentifier());
    window_sizes_.erase(browser->GetIdentifier());
  }

 private:
  std::mutex mu_;
  std::unordered_set<int> forwarded_ids_;
  std::unordered_map<int, NSSize> window_sizes_;
  IMPLEMENT_REFCOUNTING(SXRogueChromeWindowTrapClient);
};

}  // namespace

void SXBrowserApp::OnBeforeCommandLineProcessing(
    const CefString& process_type,
    CefRefPtr<CefCommandLine> command_line) {
  // Only adjust switches for the main browser process.
  if (!process_type.empty()) {
    return;
  }

  // STRICT ANTI-GUARDRAIL & REAL-BROWSER COMPLIANCE:
  // - Never add --enable-automation, --headless, or --remote-debugging-port.
  // - Preserve Chromium's genuine User-Agent, Sec-CH-UA Client Hints, and TLS/HTTP2 stack.
  // - Avoid macOS Keychain modal password prompt during local ad-hoc signed runs
  //   unless SAFARIUM_USE_SYSTEM_KEYCHAIN=1 is explicitly set.
  const char* useSystemKeychain = getenv("SAFARIUM_USE_SYSTEM_KEYCHAIN");
  if (!useSystemKeychain || strcmp(useSystemKeychain, "1") != 0) {
    command_line->AppendSwitch("use-mock-keychain");
  }

  // Ensure smooth scrolling & hardware acceleration are active on Apple Silicon.
  command_line->AppendSwitch("enable-smooth-scrolling");
  if (getenv("SAFARIUM_SCROLL_DEBUG")) {
    command_line->AppendSwitch("disable-backgrounding-occluded-windows");
    command_line->AppendSwitch("disable-renderer-backgrounding");
  }
  // Allow native AppKit NSGlassEffectView video HUD buttons to call HTMLMediaElement.play() reliably.
  command_line->AppendSwitchWithValue("autoplay-policy", "no-user-gesture-required");

  // Enforce Safari-grade process-per-tab / strict site & origin isolation so each website
  // (e.g. reddit.com, google.com) runs in its own dedicated OS renderer process in Activity Monitor.
  command_line->AppendSwitch("site-per-process");
  command_line->AppendSwitch("origin-keyed-processes-by-default");

  // Keep Chromium BackForwardCache + PaintHolding (same-origin AND cross-origin) + Prerender2 active
  // for zero-flash Back/Forward, Speculation Rules prerender/prefetch, and link navigations,
  // and enable ThirdPartyStoragePartitioning + PartitionedCookies.
  command_line->AppendSwitchWithValue("enable-features", "BackForwardCache:enable_same_site/true/all_extensions_allowed/true/TimeToLiveInBackForwardCacheInSeconds/600,BackForwardCacheMemoryControls,AllowPageWithIDBConnectionInBFCache,PaintHolding,PaintHoldingCrossOrigin,Prerender2,WebAuthenticationPasskeys,WebAuthenticationMacPlatformAuthenticator,ThirdPartyStoragePartitioning,PartitionedCookies,OverscrollEffectOnNonRootScrollers,ElasticOverscrollBackgroundPaintLocationFix,ElasticOverscrollUseEventDeltaForAxisSelection");

  // Disable Privacy Sandbox / Topics / FLEDGE / Attribution Reporting telemetry while keeping
  // standard NetworkPrediction available for non-private browsing profiles.
  command_line->AppendSwitchWithValue("disable-features", "PrivacySandboxAdsAPIsOverride,BrowsingTopics,InterestGroupStorage,Fledge,AttributionReportingCrossAppWeb,TrustTokens,ConversionMeasurement,OptimizationHints,InterestFeedContentSuggestions");

  // Disable Chromium's built-in macOS HistorySwiper / HistoryOverlayView (circular Back/Forward arrows);
  // Safarium's native AppKit SwipeNavigationController handles 120Hz Safari page-slide gestures exclusively.
  command_line->AppendSwitchWithValue("overscroll-history-navigation", "0");

  // Disable Chrome's first-run / welcome promos while keeping genuine chrome/ runtime intact.
  command_line->AppendSwitch("no-first-run");
  command_line->AppendSwitch("no-default-browser-check");

  // Load persisted MV3 extensions from ~/Library/Application Support/Safarium/Profile/SafariumExtensions/
  NSArray<NSString *> *extDirs = [[SXEngineRuntime sharedRuntime] startupExtensionDirectories];
  if (extDirs.count > 0) {
    NSString *joined = [extDirs componentsJoinedByString:@","];
    command_line->AppendSwitchWithValue("load-extension", CefString(joined.UTF8String));
  }
}

void SXBrowserApp::OnContextInitialized() {
  SXInstallStealthWindowBlocker();
  SXMediaTranscodeServer::Shared().Start();
  if (NSThread.isMainThread) {
    [[SXEngineRuntime sharedRuntime] markContextInitialized];
  } else {
    dispatch_async(dispatch_get_main_queue(), ^{
      [[SXEngineRuntime sharedRuntime] markContextInitialized];
    });
  }
}

void SXBrowserApp::OnBeforeChildProcessLaunch(
    CefRefPtr<CefCommandLine> command_line) {
  auto& srv = SXMediaTranscodeServer::Shared();
  if (!srv.IsRunning()) {
    srv.Start();
  }
  if (srv.IsRunning() && srv.Port() > 0) {
    command_line->AppendSwitchWithValue("sx-media-proxy-port", std::to_string(srv.Port()));
    command_line->AppendSwitchWithValue("sx-media-proxy-token", srv.Token());
  }

  // Deliver the live privacy policy synchronously to every newly spawned renderer subprocess
  // so document-start anti-fingerprinting never races async IPC on cross-origin process swaps.
  if (command_line && command_line->GetSwitchValue("type").ToString() == "renderer") {
    auto snap = sx::privacy::SXPrivacyEngine::Shared().Snapshot();
    if (snap) {
      command_line->AppendSwitchWithValue("sx-privacy-fp", snap->advanced_fingerprint ? "1" : "0");
      command_line->AppendSwitchWithValue("sx-privacy-scope", std::to_string(snap->advanced_fingerprint_scope));
      command_line->AppendSwitchWithValue("sx-privacy-gpc", snap->global_privacy_control ? "1" : "0");
      command_line->AppendSwitchWithValue("sx-privacy-level", std::to_string(snap->protection_level));
      command_line->AppendSwitchWithValue("sx-privacy-cb-default", std::to_string(snap->content_blockers_default));
      command_line->AppendSwitchWithValue("sx-privacy-mic-default", std::to_string(snap->microphone_default));
      command_line->AppendSwitchWithValue("sx-privacy-cam-default", std::to_string(snap->camera_default));
      command_line->AppendSwitchWithValue("sx-privacy-salt",
                                          sx::privacy::SXPrivacyEngine::Shared().NormalSessionSalt());
      auto appendHostSet = [&](const char* sw, const std::unordered_set<std::string>& hosts) {
        if (hosts.empty()) return;
        std::string joined;
        for (const auto& h : hosts) {
          if (joined.size() + h.size() + 1 > 4096) break;
          if (!joined.empty()) joined.push_back(',');
          joined += h;
        }
        if (!joined.empty()) {
          command_line->AppendSwitchWithValue(sw, joined);
        }
      };
      appendHostSet("sx-privacy-disabled-hosts", snap->content_blockers_disabled_hosts);
      appendHostSet("sx-privacy-enabled-hosts", snap->content_blockers_enabled_hosts);
      appendHostSet("sx-privacy-mic-allowed-hosts", snap->microphone_allowed_hosts);
      appendHostSet("sx-privacy-cam-allowed-hosts", snap->camera_allowed_hosts);
    }
  }
}

void SXBrowserApp::OnScheduleMessagePumpWork(int64_t delay_ms) {
  [[SXEngineRuntime sharedRuntime] scheduleMessagePumpWorkWithDelayMs:delay_ms];
}

bool SXBrowserApp::OnAlreadyRunningAppRelaunch(
    CefRefPtr<CefCommandLine> command_line,
    const CefString& current_directory) {
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSApp activateIgnoringOtherApps:YES];
  });
  return true;
}

CefRefPtr<CefClient> SXBrowserApp::GetDefaultClient() {
  if (getenv("SAFARIUM_CEF_DEBUG")) {
    fprintf(stderr, "[SXApp] GetDefaultClient() invoked\n");
    fflush(stderr);
  }
  if (!default_client_) {
    default_client_ = new SXRogueChromeWindowTrapClient();
  }
  return default_client_;
}
