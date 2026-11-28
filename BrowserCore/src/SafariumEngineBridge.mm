// SafariumEngineBridge.mm
// Objective-C++ implementation of the BrowserCore <-> SafariShell engine bridge.

#import "SafariumEngineBridge.h"
#import "SXApp.h"
#import "SXBrowserClient.h"
#import "SXExtensionManager.h"
#import "SXInternal.h"
#import "SXPrivacyEngine.h"
#import "SXTopEdgeColorSampler.h"

#include "include/base/cef_callback.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_cookie.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_string_visitor.h"
#include "include/cef_task.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_library_loader.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <IOSurface/IOSurface.h>

#include <atomic>
#include <cmath>
#include <dlfcn.h>
#include <mutex>
#include <unordered_map>
#include <unordered_set>

NSNotificationName const SXEngineRuntimeRequestNewTabNotification =
    @"SXEngineRuntimeRequestNewTabNotification";
NSNotificationName const SXEngineRuntimeRequestNewWindowNotification =
    @"SXEngineRuntimeRequestNewWindowNotification";
NSNotificationName const SXEngineRuntimeDidRecordPrivacyEventNotification =
    @"SXEngineRuntimeDidRecordPrivacyEventNotification";

#pragma mark - AppKit CrAppProtocol Runtime Hook

static BOOL gHandlingSendEvent = NO;
static IMP gOriginalSendEventIMP = NULL;

static BOOL SXIsHandlingSendEvent(id self, SEL _cmd) {
  return gHandlingSendEvent;
}

static void SXSetHandlingSendEvent(id self, SEL _cmd, BOOL handling) {
  gHandlingSendEvent = handling;
}

static void SXSwizzledSendEvent(id self, SEL _cmd, NSEvent *event) {
  BOOL previous = gHandlingSendEvent;
  gHandlingSendEvent = YES;
  ((void (*)(id, SEL, NSEvent *))gOriginalSendEventIMP)(self, _cmd, event);
  gHandlingSendEvent = previous;
}


/// Removes persistent site storage (Local/Session Storage, IndexedDB, File System, WebSQL, service workers) when a
/// previous "Clear Website Data" left a marker. Must run before CefInitialize, while no Chromium process owns the files.
static void SXApplyPendingSiteStorageClear(NSString *profileDir) {
  if (profileDir.length == 0) return;
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *marker = [profileDir stringByAppendingPathComponent:@"ClearSiteStorageOnLaunch"];
  if (![fm fileExistsAtPath:marker]) return;
  NSArray<NSString *> *subPaths = @[ @"Local Storage", @"IndexedDB", @"Session Storage", @"File System", @"databases",
                                     @"Service Worker", @"Storage", @"shared_proto_db", @"Shared Dictionary" ];
  for (NSString *base in @[ @"Default", @"" ]) {
    for (NSString *rel in subPaths) {
      NSString *full = [[profileDir stringByAppendingPathComponent:base] stringByAppendingPathComponent:rel];
      if ([fm fileExistsAtPath:full]) [fm removeItemAtPath:full error:nil];
    }
  }
  [fm removeItemAtPath:marker error:nil];
}

#pragma mark - SXEngineConfiguration

@implementation SXEngineConfiguration

+ (instancetype)defaultConfiguration {
  SXEngineConfiguration *config = [[SXEngineConfiguration alloc] init];
  NSString *appSupport =
      [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                           NSUserDomainMask, YES) firstObject];
  if (!appSupport) {
    appSupport = [NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Application Support"];
  }
  config.userDataDir =
      [appSupport stringByAppendingPathComponent:@"Safarium/Profile"];
  config.defaultNewTabURL = [NSURL URLWithString:@"about:blank"];
  return config;
}

@end

#pragma mark - SXDownloadItem

@implementation SXDownloadItem

- (instancetype)initWithDownloadID:(uint32_t)downloadID
                 suggestedFileName:(NSString *)suggestedFileName
                          fullPath:(nullable NSString *)fullPath
                               url:(nullable NSURL *)url
                        totalBytes:(int64_t)totalBytes
                     receivedBytes:(int64_t)receivedBytes
                   percentComplete:(int32_t)percentComplete
                        inProgress:(BOOL)inProgress
                          complete:(BOOL)complete
                          canceled:(BOOL)canceled
                            paused:(BOOL)paused {
  self = [super init];
  if (self) {
    _downloadID = downloadID;
    _suggestedFileName = [suggestedFileName copy] ?: @"";
    _fullPath = [fullPath copy];
    _url = url;
    _totalBytes = totalBytes;
    _receivedBytes = receivedBytes;
    _percentComplete = percentComplete;
    _inProgress = inProgress;
    _complete = complete;
    _canceled = canceled;
    _paused = paused;
  }
  return self;
}

@end

#pragma mark - SXPrivacyEvent & SXWebsiteDataRecord

@implementation SXPrivacyEvent

- (instancetype)initWithEventType:(NSString *)eventType
                         pageHost:(NSString *)pageHost
                      trackerHost:(NSString *)trackerHost
                     entityDomain:(NSString *)entityDomain
                        ownerName:(NSString *)ownerName
                         category:(NSString *)category
                           detail:(NSString *)detail
                            count:(NSInteger)count
                        isPrivate:(BOOL)isPrivate
                        timestamp:(NSTimeInterval)timestamp {
  self = [super init];
  if (self) {
    _eventType = [eventType copy] ?: @"";
    _pageHost = [pageHost copy] ?: @"";
    _trackerHost = [trackerHost copy] ?: @"";
    _entityDomain = [entityDomain copy] ?: @"";
    _ownerName = [ownerName copy] ?: @"";
    _category = [category copy] ?: @"other";
    _detail = [detail copy] ?: @"";
    _count = count;
    _isPrivate = isPrivate;
    _timestamp = timestamp;
  }
  return self;
}

@end

@implementation SXWebsiteDataRecord

- (instancetype)initWithDomain:(NSString *)domain
                   cookieCount:(NSInteger)cookieCount
                    hasCookies:(BOOL)hasCookies
                      hasCache:(BOOL)hasCache {
  self = [super init];
  if (self) {
    _domain = [domain copy] ?: @"";
    _cookieCount = cookieCount;
    _hasCookies = hasCookies;
    _hasCache = hasCache;
  }
  return self;
}

@end

#pragma mark - SXBrowserHostView

static NSView * _Nullable SXFindFocusableWebView(NSView *root, NSView * _Nullable excludeSubtree = nil) {
  if (!root) {
    return nil;
  }
  // Walk depth-first looking for the visible RenderWidgetHostViewCocoa of the active page, skipping hidden outgoing
  // views and any docked DevTools container so keyboard focus never lands on an offscreen RWHV or Web Inspector.
  for (NSView *sub in root.subviews) {
    if (sub == excludeSubtree || sub.isHidden || sub.alphaValue < 0.01) {
      continue;
    }
    NSString *clsName = NSStringFromClass([sub class]);
    if ([clsName containsString:@"RenderWidgetHostView"]) {
      return sub;
    }
    NSView *nested = SXFindFocusableWebView(sub, excludeSubtree);
    if (nested) {
      return nested;
    }
  }
  for (NSView *sub in root.subviews) {
    if (sub != excludeSubtree && !sub.isHidden && sub.alphaValue >= 0.01) {
      return sub;
    }
  }
  return nil;
}

static void SXSyncSubviewHierarchy(NSView *view, NSRect bounds, BOOL hidden) {
  for (NSView *sub in view.subviews) {
    BOOL wasHidden = sub.isHidden;
    if (sub.hidden != hidden) {
      sub.hidden = hidden;
    }
    CGFloat targetAlpha = hidden ? 0.0 : 1.0;
    if (sub.alphaValue != targetAlpha) {
      sub.alphaValue = targetAlpha;
    }
    if (sub.layer && sub.layer.hidden != hidden) {
      sub.layer.hidden = hidden;
    }
    if (!NSEqualRects(sub.frame, bounds)) {
      sub.frame = bounds;
    }
    sub.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    if (!hidden && wasHidden) {
      sub.needsLayout = YES;
    }
  }
}

@class SXBrowserHostView;

@interface SXDevToolsBarButton : NSButton
@property (nonatomic, assign) BOOL activeSelection;
@property (nonatomic, assign) BOOL isHovered;
@end

@implementation SXDevToolsBarButton {
  NSTrackingArea *_trackArea;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  (void)event;
  return YES;
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_trackArea) {
    [self removeTrackingArea:_trackArea];
  }
  _trackArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect)
             owner:self
          userInfo:nil];
  [self addTrackingArea:_trackArea];
}

- (void)mouseEntered:(NSEvent *)event {
  (void)event;
  self.isHovered = YES;
  [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)event {
  (void)event;
  self.isHovered = NO;
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  NSRect b = self.bounds;
  BOOL isDark = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameDarkAqua, NSAppearanceNameAqua]]
                 isEqualToString:NSAppearanceNameDarkAqua];
  if (self.activeSelection) {
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 1.0, 1.0) xRadius:5.0 yRadius:5.0];
    [[NSColor.controlAccentColor colorWithAlphaComponent:(isDark ? 0.24 : 0.16)] setFill];
    [bg fill];
  } else if (self.isHovered) {
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 1.0, 1.0) xRadius:5.0 yRadius:5.0];
    [(isDark ? [NSColor colorWithWhite:1.0 alpha:0.12] : [NSColor colorWithWhite:0.0 alpha:0.08]) setFill];
    [bg fill];
  }
  [super drawRect:dirtyRect];
}

@end

@interface SXDevToolsControlBarView : NSView
@property (nonatomic, weak, nullable) SXBrowserTab *ownerTab;
@property (nonatomic, assign) SXDevToolsDockMode dockMode;
@property (nonatomic, assign) BOOL showCloseButton;
@property (nonatomic, copy, nullable) NSString *inspectorTitle;
- (void)updateActiveMode:(SXDevToolsDockMode)mode;
@end

@implementation SXDevToolsControlBarView {
  SXDevToolsBarButton *_closeBtn;
  SXDevToolsBarButton *_leftBtn;
  SXDevToolsBarButton *_bottomBtn;
  SXDevToolsBarButton *_rightBtn;
  SXDevToolsBarButton *_separateBtn;
  NSTextField *_titleLabel;
}

- (instancetype)initWithFrame:(NSRect)frameRect showCloseButton:(BOOL)showClose {
  self = [super initWithFrame:frameRect];
  if (self) {
    _showCloseButton = showClose;
    self.wantsLayer = YES;

    auto makeBtn = ^SXDevToolsBarButton *(NSString *symbol, NSString *tooltip, SEL action) {
      SXDevToolsBarButton *btn = [[SXDevToolsBarButton alloc] initWithFrame:NSMakeRect(0, 0, 24, 22)];
      btn.bordered = NO;
      btn.buttonType = NSButtonTypeMomentaryChange;
      btn.imagePosition = NSImageOnly;
      btn.toolTip = tooltip;
      btn.target = self;
      btn.action = action;
      if (@available(macOS 11.0, *)) {
        NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:12.0 weight:NSFontWeightMedium];
        btn.image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tooltip] imageWithSymbolConfiguration:cfg];
      }
      btn.contentTintColor = [NSColor secondaryLabelColor];
      [self addSubview:btn];
      return btn;
    };

    if (showClose) {
      _closeBtn = makeBtn(@"xmark", @"Close Web Inspector", @selector(closeClicked:));
    }
    _leftBtn = makeBtn(@"rectangle.lefthalf.inset.filled", @"Dock to Left of Window", @selector(dockLeftClicked:));
    _bottomBtn = makeBtn(@"rectangle.bottomhalf.inset.filled", @"Dock to Bottom of Window", @selector(dockBottomClicked:));
    _rightBtn = makeBtn(@"rectangle.righthalf.inset.filled", @"Dock to Right of Window", @selector(dockRightClicked:));
    _separateBtn = makeBtn(@"macwindow.on.rectangle", @"Detach into Separate Window", @selector(detachWindowClicked:));

    if (showClose) {
      _titleLabel = [NSTextField labelWithString:@"Web Inspector"];
      _titleLabel.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
      _titleLabel.textColor = [NSColor secondaryLabelColor];
      _titleLabel.alignment = NSTextAlignmentCenter;
      _titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
      [self addSubview:_titleLabel];
    }
  }
  return self;
}

- (BOOL)isFlipped { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }

- (void)setInspectorTitle:(NSString *)inspectorTitle {
  _inspectorTitle = [inspectorTitle copy];
  if (_titleLabel) {
    _titleLabel.stringValue = inspectorTitle.length > 0 ? inspectorTitle : @"Web Inspector";
  }
}

- (void)updateActiveMode:(SXDevToolsDockMode)mode {
  _dockMode = mode;
  auto styleBtn = ^(SXDevToolsBarButton *b, BOOL active) {
    if (!b) return;
    b.activeSelection = active;
    b.contentTintColor = active ? [NSColor controlAccentColor] : [NSColor secondaryLabelColor];
    [b setNeedsDisplay:YES];
  };
  styleBtn(_leftBtn, mode == SXDevToolsDockLeft);
  styleBtn(_bottomBtn, mode == SXDevToolsDockBottom);
  styleBtn(_rightBtn, mode == SXDevToolsDockRight);
  styleBtn(_separateBtn, mode == SXDevToolsDockSeparate);
}

- (void)layout {
  [super layout];
  NSRect b = self.bounds;
  CGFloat btnW = 24.0;
  CGFloat btnH = 22.0;
  CGFloat y = floor((b.size.height - btnH) * 0.5);
  CGFloat x = 8.0;

  if (_closeBtn) {
    _closeBtn.frame = NSMakeRect(x, y, btnW, btnH);
    x += btnW + 8.0;
  }
  _leftBtn.frame = NSMakeRect(x, y, btnW, btnH);
  x += btnW + 3.0;
  _bottomBtn.frame = NSMakeRect(x, y, btnW, btnH);
  x += btnW + 3.0;
  _rightBtn.frame = NSMakeRect(x, y, btnW, btnH);
  x += btnW + 3.0;
  _separateBtn.frame = NSMakeRect(x, y, btnW, btnH);
  x += btnW + 8.0;

  if (_titleLabel) {
    CGFloat titleW = fmax(0.0, b.size.width - x * 2.0);
    _titleLabel.hidden = (titleW < 70.0);
    _titleLabel.frame = NSMakeRect(x, floor((b.size.height - 15.0) * 0.5), titleW, 15.0);
  }
}

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  if (!_showCloseButton) return; // Transparent inside native titlebar accessory
  NSRect b = self.bounds;
  BOOL isDark = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameDarkAqua, NSAppearanceNameAqua]]
                 isEqualToString:NSAppearanceNameDarkAqua];
  [(isDark ? [NSColor colorWithSRGBRed:0.15 green:0.15 blue:0.16 alpha:1.0]
           : [NSColor colorWithSRGBRed:0.95 green:0.95 blue:0.96 alpha:1.0]) setFill];
  NSRectFill(b);

  // Subtle bottom hairline separating control bar from DevTools webview
  [[NSColor separatorColor] setFill];
  NSRectFill(NSMakeRect(0, 0, b.size.width, 1.0));
}

- (void)closeClicked:(id)sender { (void)sender; [self.ownerTab closeDevTools]; }
- (void)dockLeftClicked:(id)sender { (void)sender; [self.ownerTab setDevToolsDockMode:SXDevToolsDockLeft]; }
- (void)dockBottomClicked:(id)sender { (void)sender; [self.ownerTab setDevToolsDockMode:SXDevToolsDockBottom]; }
- (void)dockRightClicked:(id)sender { (void)sender; [self.ownerTab setDevToolsDockMode:SXDevToolsDockRight]; }
- (void)detachWindowClicked:(id)sender { (void)sender; [self.ownerTab setDevToolsDockMode:SXDevToolsDockSeparate]; }

@end

@interface SXDevToolsSplitterView : NSView
@property (nonatomic, weak, nullable) SXBrowserHostView *hostView;
@end

@interface SXBrowserHostView : NSView
@property (nonatomic, weak, nullable) SXBrowserTab *ownerTab;
@property (nonatomic, strong, nullable) NSView *devToolsContainer;
@property (nonatomic, strong, nullable) SXDevToolsControlBarView *devToolsControlBar;
@property (nonatomic, strong, nullable) SXDevToolsSplitterView *devToolsSplitter;
@property (nonatomic, assign) CGFloat devToolsHeight;
@property (nonatomic, assign) CGFloat devToolsWidth;
@property (nonatomic, assign) SXDevToolsDockMode devToolsDockMode;
@property (nonatomic, assign) BOOL devToolsDocked;
- (void)syncLayoutAndVisibility;
- (NSRect)webContentRectForBounds:(NSRect)bounds;
@end

@implementation SXDevToolsSplitterView {
  BOOL _dragging;
  NSPoint _dragStartScreen;
  CGFloat _dragStartW;
  CGFloat _dragStartH;
  SXDevToolsDockMode _dragMode;
}

- (BOOL)isFlipped { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }

- (BOOL)isVerticalSplitter {
  SXBrowserHostView *host = self.hostView;
  return host && (host.devToolsDockMode == SXDevToolsDockLeft || host.devToolsDockMode == SXDevToolsDockRight);
}

- (void)resetCursorRects {
  NSCursor *cur = self.isVerticalSplitter ? [NSCursor resizeLeftRightCursor] : [NSCursor resizeUpDownCursor];
  [self addCursorRect:self.bounds cursor:cur];
}

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSRect b = self.bounds;
  BOOL isDark = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameDarkAqua, NSAppearanceNameAqua]]
                 isEqualToString:NSAppearanceNameDarkAqua];
  [(isDark ? [NSColor colorWithSRGBRed:0.14 green:0.14 blue:0.15 alpha:1.0]
           : [NSColor colorWithSRGBRed:0.92 green:0.92 blue:0.93 alpha:1.0]) setFill];
  NSRectFill(b);

  [[NSColor separatorColor] setFill];
  if (self.isVerticalSplitter) {
    NSRectFill(NSMakeRect(0, 0, 1.0, b.size.height));
    NSRectFill(NSMakeRect(b.size.width - 1.0, 0, 1.0, b.size.height));
    CGFloat pillW = 2.5, pillH = 36.0;
    NSRect pillRect = NSMakeRect((b.size.width - pillW) * 0.5, (b.size.height - pillH) * 0.5, pillW, pillH);
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:pillRect xRadius:1.25 yRadius:1.25];
    [(isDark ? [NSColor colorWithWhite:1.0 alpha:0.28] : [NSColor colorWithWhite:0.0 alpha:0.22]) setFill];
    [pill fill];
  } else {
    NSRectFill(NSMakeRect(0, b.size.height - 1.0, b.size.width, 1.0));
    CGFloat pillW = 36.0, pillH = 2.5;
    NSRect pillRect = NSMakeRect((b.size.width - pillW) * 0.5, (b.size.height - pillH) * 0.5, pillW, pillH);
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:pillRect xRadius:1.25 yRadius:1.25];
    [(isDark ? [NSColor colorWithWhite:1.0 alpha:0.28] : [NSColor colorWithWhite:0.0 alpha:0.22]) setFill];
    [pill fill];
  }
}

- (void)mouseDown:(NSEvent *)event {
  SXBrowserHostView *host = self.hostView;
  if (!host || !host.window) return;
  _dragging = YES;
  _dragStartScreen = [NSEvent mouseLocation];
  _dragStartW = host.devToolsWidth;
  _dragStartH = host.devToolsHeight;
  _dragMode = host.devToolsDockMode;
  (void)event;
}

- (void)mouseDragged:(NSEvent *)event {
  (void)event;
  if (!_dragging) return;
  SXBrowserHostView *host = self.hostView;
  if (!host || !host.window) return;
  NSPoint curScreen = [NSEvent mouseLocation];
  if (_dragMode == SXDevToolsDockLeft) {
    CGFloat dx = curScreen.x - _dragStartScreen.x;
    CGFloat maxW = fmax(280.0, host.bounds.size.width - 240.0);
    host.devToolsWidth = fmax(280.0, fmin(maxW, _dragStartW + dx));
  } else if (_dragMode == SXDevToolsDockRight) {
    CGFloat dx = curScreen.x - _dragStartScreen.x;
    CGFloat maxW = fmax(280.0, host.bounds.size.width - 240.0);
    host.devToolsWidth = fmax(280.0, fmin(maxW, _dragStartW - dx));
  } else {
    CGFloat dy = curScreen.y - _dragStartScreen.y;
    CGFloat maxH = fmax(180.0, host.bounds.size.height - 140.0);
    host.devToolsHeight = fmax(180.0, fmin(maxH, _dragStartH + dy));
  }
  [host syncLayoutAndVisibility];
  [host.ownerTab handleHostViewFrameChanged];
}

- (void)mouseUp:(NSEvent *)event {
  (void)event;
  if (!_dragging) return;
  _dragging = NO;
  SXBrowserHostView *host = self.hostView;
  if (host) {
    [host syncLayoutAndVisibility];
    [host.ownerTab handleHostViewFrameChanged];
  }
}

@end

@interface SXBrowserTab (SXHostCanvasInternal)
- (void)handleHostEffectiveAppearanceChanged;
@end

@implementation SXBrowserHostView

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _devToolsHeight = 320.0;
    _devToolsWidth = 420.0;
    _devToolsDockMode = SXDevToolsDockBottom;
  }
  return self;
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  [self.ownerTab handleHostEffectiveAppearanceChanged];
}

- (BOOL)isFlipped {
  return NO;
}

- (NSRect)webContentRectForBounds:(NSRect)bounds {
  if (!self.devToolsDocked || !self.devToolsContainer || !self.devToolsSplitter) {
    return bounds;
  }
  CGFloat splitThick = 6.0;
  if (self.devToolsDockMode == SXDevToolsDockLeft) {
    CGFloat maxW = fmax(280.0, bounds.size.width - 240.0);
    CGFloat devW = fmax(280.0, fmin(maxW, self.devToolsWidth));
    CGFloat webX = devW + splitThick;
    return NSMakeRect(webX, 0, fmax(1.0, bounds.size.width - webX), bounds.size.height);
  } else if (self.devToolsDockMode == SXDevToolsDockRight) {
    CGFloat maxW = fmax(280.0, bounds.size.width - 240.0);
    CGFloat devW = fmax(280.0, fmin(maxW, self.devToolsWidth));
    return NSMakeRect(0, 0, fmax(1.0, bounds.size.width - devW - splitThick), bounds.size.height);
  } else {
    CGFloat maxH = fmax(180.0, bounds.size.height - 140.0);
    CGFloat devH = fmax(180.0, fmin(maxH, self.devToolsHeight));
    CGFloat webY = devH + splitThick;
    return NSMakeRect(0, webY, bounds.size.width, fmax(1.0, bounds.size.height - webY));
  }
}

- (void)syncLayoutAndVisibility {
  NSRect bounds = self.bounds;
  BOOL hidden = self.isHidden;
  BOOL docked = self.devToolsDocked && self.devToolsContainer && self.devToolsSplitter && self.devToolsControlBar;
  CGFloat splitThick = 6.0;
  CGFloat barH = 28.0;
  NSRect webRect = bounds;

  if (docked) {
    NSRect paneRect = NSZeroRect;
    NSRect splitRect = NSZeroRect;

    if (self.devToolsDockMode == SXDevToolsDockLeft) {
      CGFloat maxW = fmax(280.0, bounds.size.width - 240.0);
      CGFloat devW = fmax(280.0, fmin(maxW, self.devToolsWidth));
      paneRect = NSMakeRect(0, 0, devW, bounds.size.height);
      splitRect = NSMakeRect(devW, 0, splitThick, bounds.size.height);
      webRect = NSMakeRect(devW + splitThick, 0, fmax(1.0, bounds.size.width - devW - splitThick), bounds.size.height);
    } else if (self.devToolsDockMode == SXDevToolsDockRight) {
      CGFloat maxW = fmax(280.0, bounds.size.width - 240.0);
      CGFloat devW = fmax(280.0, fmin(maxW, self.devToolsWidth));
      CGFloat webW = fmax(1.0, bounds.size.width - devW - splitThick);
      webRect = NSMakeRect(0, 0, webW, bounds.size.height);
      splitRect = NSMakeRect(webW, 0, splitThick, bounds.size.height);
      paneRect = NSMakeRect(webW + splitThick, 0, devW, bounds.size.height);
    } else {
      CGFloat maxH = fmax(180.0, bounds.size.height - 140.0);
      CGFloat devH = fmax(180.0, fmin(maxH, self.devToolsHeight));
      paneRect = NSMakeRect(0, 0, bounds.size.width, devH);
      splitRect = NSMakeRect(0, devH, bounds.size.width, splitThick);
      webRect = NSMakeRect(0, devH + splitThick, bounds.size.width, fmax(1.0, bounds.size.height - devH - splitThick));
    }

    NSRect barRect = NSMakeRect(paneRect.origin.x, NSMaxY(paneRect) - barH, paneRect.size.width, barH);
    NSRect devRect = NSMakeRect(paneRect.origin.x, paneRect.origin.y, paneRect.size.width, fmax(1.0, paneRect.size.height - barH));

    self.devToolsControlBar.hidden = hidden;
    self.devToolsControlBar.alphaValue = hidden ? 0.0 : 1.0;
    if (!NSEqualRects(self.devToolsControlBar.frame, barRect)) {
      self.devToolsControlBar.frame = barRect;
    }

    self.devToolsContainer.hidden = hidden;
    self.devToolsContainer.alphaValue = hidden ? 0.0 : 1.0;
    if (self.devToolsContainer.layer) self.devToolsContainer.layer.hidden = hidden;
    if (!NSEqualRects(self.devToolsContainer.frame, devRect)) {
      self.devToolsContainer.frame = devRect;
    }
    SXSyncSubviewHierarchy(self.devToolsContainer, self.devToolsContainer.bounds, hidden);

    self.devToolsSplitter.hidden = hidden;
    self.devToolsSplitter.alphaValue = hidden ? 0.0 : 1.0;
    if (!NSEqualRects(self.devToolsSplitter.frame, splitRect)) {
      self.devToolsSplitter.frame = splitRect;
      [self.devToolsSplitter setNeedsDisplay:YES];
      if (self.window) {
        [self.window invalidateCursorRectsForView:self.devToolsSplitter];
      }
    }
  }

  for (NSView *sub in self.subviews) {
    if (sub == self.devToolsContainer || sub == self.devToolsSplitter || sub == self.devToolsControlBar) {
      continue;
    }
    BOOL wasHidden = sub.isHidden;
    if (sub.hidden != hidden) sub.hidden = hidden;
    CGFloat targetAlpha = hidden ? 0.0 : 1.0;
    if (sub.alphaValue != targetAlpha) sub.alphaValue = targetAlpha;
    if (sub.layer && sub.layer.hidden != hidden) sub.layer.hidden = hidden;
    if (!NSEqualRects(sub.frame, webRect)) sub.frame = webRect;
    sub.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    if (!hidden && wasHidden) sub.needsLayout = YES;
  }
  [self.ownerTab syncDockedDevToolsWindowFrame];
}

- (void)layout {
  [super layout];
  [self syncLayoutAndVisibility];
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  if (self.isHidden) {
    // Keep the AppKit frame updated, but defer Blink/GPU surface resize and sampler timer work until unhidden.
    return;
  }
  [self syncLayoutAndVisibility];
  [self.ownerTab handleHostViewFrameChanged];
}

- (void)setHidden:(BOOL)hidden {
  BOOL changed = (self.isHidden != hidden);
  [super setHidden:hidden];
  [self syncLayoutAndVisibility];
  if (changed) {
    [self.ownerTab handleHostViewVisibilityChanged:hidden];
    if (!hidden) {
      [self.ownerTab handleHostViewFrameChanged];
    }
  }
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window) {
    [self syncLayoutAndVisibility];
    [self.ownerTab handleHostViewFrameChanged];
  }
}

// Trackpad pinch-to-zoom is handled directly by Chromium's native 120fps GPU compositor
// (RenderWidgetHostViewCocoa) with zero CDP interception. Do NOT override magnifyWithEvent:
// here so native pinch gestures retain full 120fps smoothness and cursor anchor fidelity.

@end

#pragma mark - Navigation freeze frame view

// Freeze frames are kept as IOSurfaces: as layer contents they are shared with the window server instead of copied,
// so the overlay shows the picture in the very frame it is added (a 13 MB CGImage took 1-2 frames to arrive, which
// let one blank frame through at the view swap).
static id _Nullable SXCopyImageToIOSurface(CGImageRef image) {
  if (!image) return nil;
  size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
  if (w == 0 || h == 0) return nil;
  NSDictionary *props = @{ (id)kIOSurfaceWidth : @(w), (id)kIOSurfaceHeight : @(h), (id)kIOSurfaceBytesPerElement : @4,
                           (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA') };
  IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
  if (!surface) return nil;
  IOSurfaceLock(surface, 0, NULL);
  CGColorSpaceRef cs = CGImageGetColorSpace(image);
  CGColorSpaceRef space = cs ? (CGColorSpaceRef)CFRetain(cs) : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(IOSurfaceGetBaseAddress(surface), w, h, 8, IOSurfaceGetBytesPerRow(surface),
                                           space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  if (!ctx && space) {
    CGColorSpaceRelease(space);
    space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    ctx = CGBitmapContextCreate(IOSurfaceGetBaseAddress(surface), w, h, 8, IOSurfaceGetBytesPerRow(surface),
                                space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  }
  if (ctx && space) {
    CFPropertyListRef plist = CGColorSpaceCopyPropertyList(space);
    if (plist) {
      IOSurfaceSetValue(surface, kIOSurfaceColorSpace, plist);
      CFRelease(plist);
    }
  }
  if (ctx) {
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
    CGContextRelease(ctx);
  }
  if (space) CGColorSpaceRelease(space);
  IOSurfaceUnlock(surface, 0, NULL);
  if (!ctx) { CFRelease(surface); return nil; }
  return CFBridgingRelease(surface);
}

static size_t SXFreezeImageWidth(id image) { return image ? IOSurfaceGetWidth((__bridge IOSurfaceRef)image) : 0; }
static size_t SXFreezeImageHeight(id image) { return image ? IOSurfaceGetHeight((__bridge IOSurfaceRef)image) : 0; }

// SAFARIUM_FREEZE_DEBUG=1: append every freeze-frame step to /tmp/safarium-freeze.log (the app's os_log output
// is not visible in `log show`).
static FILE *SXFreezeDebugFile(void) {
  static FILE *f;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ if (getenv("SAFARIUM_FREEZE_DEBUG")) f = fopen("/tmp/safarium-freeze.log", "a"); });
  return f;
}
#define SXFreezeLog(fmt, ...) do { FILE *sxf = SXFreezeDebugFile(); if (sxf) { \
    fprintf(sxf, "[freeze] %.3f %s\n", CACurrentMediaTime(), [[NSString stringWithFormat:fmt, ##__VA_ARGS__] UTF8String]); \
    fflush(sxf); } } while (0)

/// Shows a still copy of the page over the web view while Chromium swaps in the next document's view.
/// Purely visual: never takes clicks, scrolls or keyboard focus away from the live page underneath.
@interface SXFreezeFrameView : NSView
@end

@implementation SXFreezeFrameView
- (instancetype)initWithFrame:(NSRect)frameRect {
  if ((self = [super initWithFrame:frameRect])) {
    // Layer-hosting (layer set before wantsLayer): AppKit never redraws or clears the contents. A layer-backed view
    // lost its contents when its host view was unhidden (tab switch), showing a blank frame.
    CALayer *layer = [CALayer layer];
    self.layer = layer;
    self.wantsLayer = YES;
    self.layer.contentsGravity = kCAGravityResize;
    self.layer.actions = @{ @"contents": [NSNull null], @"bounds": [NSNull null], @"position": [NSNull null],
                            @"hidden": [NSNull null], @"opacity": [NSNull null] };
    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  }
  return self;
}
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)isOpaque { return YES; }
@end

@interface SXBrowserTab (SXFreezeFrameSwap)
- (void)handleRenderWidgetVisibilityChanged;
@end

// Chromium shows/hides its RenderWidgetHostViewCocoa with -setHidden: when it swaps views at a navigation commit.
// That happens on the main thread inside the commit task, ~100 ms before CEF's OnLoadStart reaches us, and the
// empty new view is on screen from the next frame. Watching -setHidden: lets the freeze frame go up in that same
// AppKit transaction, so no blank frame is ever presented.
static void (*gSXOrigRWHVSetHidden)(id, SEL, BOOL) = NULL;
static void (*gSXOrigRWHVRemoveFromSuperview)(id, SEL) = NULL;

static void SXNotifyHostTabRenderWidgetSwap(NSView *view) {
  for (NSView *v = view.superview; v; v = v.superview) {
    if ([v isKindOfClass:[SXBrowserHostView class]]) {
      SXBrowserHostView *host = (SXBrowserHostView *)v;
      if (host.devToolsContainer && [view isDescendantOf:host.devToolsContainer]) break;  // docked DevTools
      [host.ownerTab handleRenderWidgetVisibilityChanged];
      break;
    }
  }
}

static void SXRWHVSetHidden(id self, SEL _cmd, BOOL hidden) {
  NSView *view = (NSView *)self;
  BOOL changed = (view.isHidden != hidden);
  if (changed) {
    // Pin the freeze overlay BEFORE Chromium hides/shows the view so the cover lands in the same
    // AppKit transaction while the view hierarchy is still intact.
    SXNotifyHostTabRenderWidgetSwap(view);
  }
  if (gSXOrigRWHVSetHidden) gSXOrigRWHVSetHidden(self, _cmd, hidden);
}

static void SXRWHVRemoveFromSuperview(id self, SEL _cmd) {
  NSView *view = (NSView *)self;
  if (!view.isHidden && view.superview) {
    SXNotifyHostTabRenderWidgetSwap(view);
  }
  if (gSXOrigRWHVRemoveFromSuperview) gSXOrigRWHVRemoveFromSuperview(self, _cmd);
}

static void SXInstallRenderWidgetVisibilityHook(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Class cls = NSClassFromString(@"RenderWidgetHostViewCocoa");
    if (!cls) return;
    // Override on RenderWidgetHostViewCocoa only (never swap NSView's own implementation).
    {
      SEL sel = @selector(setHidden:);
      Method m = class_getInstanceMethod(cls, sel);
      if (m) {
        IMP hook = (IMP)SXRWHVSetHidden;
        IMP inherited = method_getImplementation(m);
        if (class_addMethod(cls, sel, hook, method_getTypeEncoding(m))) {
          gSXOrigRWHVSetHidden = (void (*)(id, SEL, BOOL))inherited;
        } else {
          gSXOrigRWHVSetHidden = (void (*)(id, SEL, BOOL))method_setImplementation(m, hook);
        }
      }
    }
    {
      SEL sel = @selector(removeFromSuperview);
      Method m = class_getInstanceMethod(cls, sel);
      if (m) {
        IMP hook = (IMP)SXRWHVRemoveFromSuperview;
        IMP inherited = method_getImplementation(m);
        if (class_addMethod(cls, sel, hook, method_getTypeEncoding(m))) {
          gSXOrigRWHVRemoveFromSuperview = (void (*)(id, SEL))inherited;
        } else {
          gSXOrigRWHVRemoveFromSuperview = (void (*)(id, SEL))method_setImplementation(m, hook);
        }
      }
    }
  });
}

#pragma mark - SXBrowserTab

static dispatch_queue_t SXPreviewSnapshotDecodeQueue(void) {
  static dispatch_queue_t queue = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
    queue = dispatch_queue_create("com.safarium.previewSnapshotDecode", attr);
  });
  return queue;
}

static NSImage * _Nullable SXDecodeDownscaledPreviewImage(NSData *jpegData,
                                                          NSSize logicalSize) {
  if (!jpegData || jpegData.length == 0) {
    return nil;
  }
  CGImageSourceRef source =
      CGImageSourceCreateWithData((__bridge CFDataRef)jpegData, NULL);
  if (!source) {
    return nil;
  }
  // Downscale to <=1280px max dimension and force eager off-main-thread decompression
  // so Tab Overview frame 0 has zero JPEG decode stall and uses ~4-6x less RAM/VRAM.
  NSDictionary *thumbOpts = @{
    (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
    (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize : @(1280),
    (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform : @YES,
    (__bridge NSString *)kCGImageSourceShouldCacheImmediately : @YES,
  };
  CGImageRef cgImg = CGImageSourceCreateThumbnailAtIndex(
      source, 0, (__bridge CFDictionaryRef)thumbOpts);
  CFRelease(source);
  if (!cgImg) {
    return nil;
  }
  NSSize pointSize = logicalSize;
  if (pointSize.width < 2.0 || pointSize.height < 2.0) {
    pointSize = NSMakeSize(CGImageGetWidth(cgImg), CGImageGetHeight(cgImg));
  }
  NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImg];
  CGImageRelease(cgImg);
  if (!rep) {
    return nil;
  }
  NSImage *image = [[NSImage alloc] initWithSize:pointSize];
  [image addRepresentation:rep];
  return image;
}

static NSImage * _Nullable SXCreateDownscaledPreviewFromCGImage(CGImageRef full,
                                                                NSSize logicalSize) {
  if (!full) return nil;
  size_t srcW = CGImageGetWidth(full), srcH = CGImageGetHeight(full);
  if (srcW == 0 || srcH == 0) return nil;
  size_t maxDim = 1280;
  double scale = 1.0;
  size_t larger = srcW > srcH ? srcW : srcH;
  if (larger > maxDim) {
    scale = (double)maxDim / (double)larger;
  }
  size_t dstW = (size_t)fmax(1.0, round((double)srcW * scale));
  size_t dstH = (size_t)fmax(1.0, round((double)srcH * scale));
  CGColorSpaceRef cs = CGImageGetColorSpace(full);
  CGColorSpaceRef space = cs ? (CGColorSpaceRef)CFRetain(cs) : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(NULL, dstW, dstH, 8, dstW * 4, space,
                                           kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  if (!ctx && space) {
    CGColorSpaceRelease(space);
    space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    ctx = CGBitmapContextCreate(NULL, dstW, dstH, 8, dstW * 4, space,
                                kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  }
  if (space) CGColorSpaceRelease(space);
  if (!ctx) return nil;
  CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
  CGContextDrawImage(ctx, CGRectMake(0, 0, dstW, dstH), full);
  CGImageRef thumb = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  if (!thumb) return nil;
  NSSize pointSize = (logicalSize.width >= 2.0 && logicalSize.height >= 2.0)
                         ? logicalSize
                         : NSMakeSize(dstW, dstH);
  NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:thumb];
  CGImageRelease(thumb);
  if (!rep) return nil;
  NSImage *image = [[NSImage alloc] initWithSize:pointSize];
  [image addRepresentation:rep];
  return image;
}

CefRefPtr<CefDictionaryValue> SXBuildPrivacyExtraInfoDictionary(bool isPrivate) {
  auto policySnap = sx::privacy::SXPrivacyEngine::Shared().Snapshot();
  CefRefPtr<CefDictionaryValue> extraInfo = CefDictionaryValue::Create();
  extraInfo->SetBool("sx_privacy_is_private", isPrivate);
  extraInfo->SetBool("sx_privacy_fp_enabled", policySnap->advanced_fingerprint);
  extraInfo->SetInt("sx_privacy_fp_scope", policySnap->advanced_fingerprint_scope);
  extraInfo->SetBool("sx_privacy_gpc_enabled", policySnap->global_privacy_control);
  extraInfo->SetInt("sx_privacy_level", policySnap->protection_level);
  extraInfo->SetInt("sx_privacy_cb_default", policySnap->content_blockers_default);
  extraInfo->SetInt("sx_privacy_mic_default", policySnap->microphone_default);
  extraInfo->SetInt("sx_privacy_cam_default", policySnap->camera_default);
  std::string salt = isPrivate
                         ? sx::privacy::SXPrivacyEngine::Shared().IncognitoSessionSalt()
                         : sx::privacy::SXPrivacyEngine::Shared().NormalSessionSalt();
  extraInfo->SetString("sx_privacy_session_salt", salt);
  auto setHostList = [&](const char* key, const std::unordered_set<std::string>& hosts) {
    CefRefPtr<CefListValue> list = CefListValue::Create();
    size_t idx = 0;
    for (const auto& h : hosts) {
      list->SetString(idx++, h);
    }
    extraInfo->SetList(key, list);
  };
  setHostList("sx_privacy_disabled_hosts", policySnap->content_blockers_disabled_hosts);
  setHostList("sx_privacy_enabled_hosts", policySnap->content_blockers_enabled_hosts);
  setHostList("sx_privacy_mic_allowed_hosts", policySnap->microphone_allowed_hosts);
  setHostList("sx_privacy_cam_allowed_hosts", policySnap->camera_allowed_hosts);
  return extraInfo;
}

CefRefPtr<CefDictionaryValue> SXBuildPrivacyConfigUpdateDictionary(bool isPrivate) {
  auto snap = sx::privacy::SXPrivacyEngine::Shared().Snapshot();
  CefRefPtr<CefDictionaryValue> cfg = CefDictionaryValue::Create();
  cfg->SetBool("is_private", isPrivate);
  cfg->SetBool("fp_enabled", snap->advanced_fingerprint);
  cfg->SetInt("fp_scope", snap->advanced_fingerprint_scope);
  cfg->SetBool("gpc_enabled", snap->global_privacy_control);
  cfg->SetInt("level", snap->protection_level);
  cfg->SetInt("cb_default", snap->content_blockers_default);
  cfg->SetInt("mic_default", snap->microphone_default);
  cfg->SetInt("cam_default", snap->camera_default);
  std::string salt = isPrivate
                         ? sx::privacy::SXPrivacyEngine::Shared().IncognitoSessionSalt()
                         : sx::privacy::SXPrivacyEngine::Shared().NormalSessionSalt();
  cfg->SetString("session_salt", salt);
  auto setHostList = [&](const char* key, const std::unordered_set<std::string>& hosts) {
    CefRefPtr<CefListValue> list = CefListValue::Create();
    size_t idx = 0;
    for (const auto& h : hosts) {
      list->SetString(idx++, h);
    }
    cfg->SetList(key, list);
  };
  setHostList("disabled_hosts", snap->content_blockers_disabled_hosts);
  setHostList("enabled_hosts", snap->content_blockers_enabled_hosts);
  setHostList("mic_allowed_hosts", snap->microphone_allowed_hosts);
  setHostList("cam_allowed_hosts", snap->camera_allowed_hosts);
  return cfg;
}

static void SXApplyPrivacySnapshotToContext(
    CefRefPtr<CefRequestContext> ctx,
    const std::shared_ptr<const sx::privacy::PolicySnapshot>& snap,
    bool isIncognito = false) {
  if (!ctx || !snap) return;
  auto setBoolPref = [&](const char *name, bool val) {
    CefRefPtr<CefValue> v = CefValue::Create();
    v->SetBool(val);
    CefString err;
    ctx->SetPreference(name, v, err);
  };
  auto setIntPref = [&](const char *name, int val) {
    CefRefPtr<CefValue> v = CefValue::Create();
    v->SetInt(val);
    CefString err;
    ctx->SetPreference(name, v, err);
  };
  auto setStrPref = [&](const char *name, const char *val) {
    CefRefPtr<CefValue> v = CefValue::Create();
    v->SetString(val);
    CefString err;
    ctx->SetPreference(name, v, err);
  };

  setBoolPref("enable_do_not_track", snap->prevent_cross_site_tracking);
  setIntPref("profile.default_content_setting_values.cookies", snap->block_all_cookies ? 2 : 1);
  setIntPref("profile.cookie_controls_mode", snap->prevent_cross_site_tracking ? 1 : 0);
  setBoolPref("privacy_sandbox.m1.topics_enabled", false);
  setBoolPref("privacy_sandbox.m1.fledge_enabled", false);
  setBoolPref("privacy_sandbox.m1.ad_measurement_enabled", false);
  // Strictly block network prediction in Private Browsing (2 = NETWORK_PREDICTION_NEVER);
  // allow Speculation Rules prefetch/prerender and preconnect in standard profiles (0 = ALWAYS).
  setIntPref("net.network_prediction_options", isIncognito ? 2 : 0);
  setStrPref("webrtc.ip_handling_policy",
             snap->webrtc_ip_protection ? "default_public_interface_only" : "default");
}

static void SXApplyPreferencesDictionaryToContext(
    CefRefPtr<CefRequestContext> ctx,
    NSDictionary<NSString *, id> * _Nullable prefsCopy,
    bool isIncognito = false) {
  if (!ctx) return;
  auto snap = sx::privacy::SXPrivacyEngine::Shared().Snapshot();
  SXApplyPrivacySnapshotToContext(ctx, snap, isIncognito);
  if (!prefsCopy.count) return;

  auto setBool = [&](const char *name, NSString *key) {
    NSNumber *num = prefsCopy[key];
    if (![num isKindOfClass:[NSNumber class]]) return;
    CefRefPtr<CefValue> v = CefValue::Create();
    v->SetBool(num.boolValue ? true : false);
    CefString err;
    ctx->SetPreference(name, v, err);
  };
  auto setInt = [&](const char *name, int val) {
    CefRefPtr<CefValue> v = CefValue::Create();
    v->SetInt(val);
    CefString err;
    ctx->SetPreference(name, v, err);
  };
  auto setString = [&](const char *name, NSString *str) {
    if (![str isKindOfClass:[NSString class]] || str.length == 0) return;
    CefRefPtr<CefValue> v = CefValue::Create();
    v->SetString(CefString(str.UTF8String));
    CefString err;
    ctx->SetPreference(name, v, err);
  };

  setBool("safebrowsing.enabled", @"warnFraudulent");
  setBool("enable_do_not_track", @"preventCrossSiteTracking");
  setBool("webkit.webprefs.javascript_enabled", @"enableJavaScript");
  setBool("download.prompt_for_download", @"askForEachDownload");
  setBool("extensions.ui.developer_mode", @"allowUnsignedExtensions");
  setBool("credentials_enable_service", @"autofillPasswords");
  setBool("autofill.profile_enabled", @"autofillAddresses");
  setBool("autofill.credit_card_enabled", @"autofillCards");

  if ([prefsCopy[@"enableJavaScript"] isKindOfClass:[NSNumber class]]) {
    BOOL jsOn = [prefsCopy[@"enableJavaScript"] boolValue];
    setInt("profile.default_content_setting_values.javascript", jsOn ? 1 : 2);
  }
  if ([prefsCopy[@"blockAllCookies"] isKindOfClass:[NSNumber class]]) {
    BOOL blockAll = [prefsCopy[@"blockAllCookies"] boolValue];
    setInt("profile.default_content_setting_values.cookies", blockAll ? 2 : 1);
  }
  if ([prefsCopy[@"preventCrossSiteTracking"] isKindOfClass:[NSNumber class]]) {
    BOOL prevent3P = [prefsCopy[@"preventCrossSiteTracking"] boolValue];
    setInt("profile.cookie_controls_mode", prevent3P ? 1 : 0);
  }
  if ([prefsCopy[@"minimumFontSize"] isKindOfClass:[NSNumber class]]) {
    setInt("webkit.webprefs.minimum_font_size", [prefsCopy[@"minimumFontSize"] intValue]);
  }
  setString("webkit.webprefs.default_encoding", prefsCopy[@"defaultEncoding"]);
  setString("download.default_directory", prefsCopy[@"downloadDirectory"]);

  if ([prefsCopy[@"webrtcIPProtection"] isKindOfClass:[NSNumber class]]) {
    BOOL webrtcOn = [prefsCopy[@"webrtcIPProtection"] boolValue];
    setString("webrtc.ip_handling_policy",
              webrtcOn ? @"default_public_interface_only" : @"default");
  }
}

@interface SXEngineRuntime (SXIncognitoInternal)
- (CefRefPtr<CefRequestContext>)sharedIncognitoRequestContext;
- (nullable NSDictionary<NSString *, id> *)cachedPreferencesCopy;
- (void)notifyNavigationBurst;
@end

@interface SXBrowserTab () {
  CefRefPtr<SXBrowserClient> _client;
  CefRefPtr<CefBrowser> _browser;
  CefRefPtr<CefBrowser> _authPopupBrowser;
  CefRefPtr<CefClient> _authPopupClient;
  NSWindow *_authPopupWindow;
  CFAbsoluteTime _lastAppleSignInIntentTime;
  BOOL _browserCreationRequested;
  BOOL _isClosed;
  BOOL _closeNotified;
  BOOL _incognito;
  BOOL _tabActiveState;
  BOOL _mainFrameLoading;
  BOOL _pendingOriginThemeReset;
  NSString *_lastPrewarmedOrigin;
  CFTimeInterval _lastPrewarmedAt;
  dispatch_source_t _previewSnapshotTimer;
  BOOL _previewCaptureInFlight;
  CFTimeInterval _lastPreviewCaptureTime;
  NSUInteger _previewCaptureGeneration;
  // Navigation freeze frame (see "Navigation freeze frame" below).
  NSUInteger _freezeGeneration;
  id _freezeImage;                // CGImageRef of the page as it was on screen when the navigation started
  CGFloat _freezeImageScale;
  SXFreezeFrameView *_freezeOverlay;
  NSMutableArray<dispatch_block_t> *_heldChromeUpdates;
  CFTimeInterval _tabHiddenAt;  // toolbar colour updates held while frozen
  NSTimer *_freezeTimer;
  CFTimeInterval _freezeRequestedAt;
  CFTimeInterval _freezeCapturedAt;
  NSUInteger _freezeCommittedGeneration;
  NSUInteger _freezeIncomingGeneration;  // generation whose new document is known to be arriving
  // Standing full-resolution copy of the active page, refreshed by the periodic preview captures. Used when the
  // view swap comes before a fresh copy exists (back/forward-cache restores swap within ~1 ms of the request).
  id _standbyImage;
  CGFloat _standbyScale;
  CFTimeInterval _standbyCapturedAt;
  CGFloat _standbyScrollY;
}

@property (nonatomic, weak) SXEngineRuntime *runtime;
@property (nonatomic, strong, nullable) NSURL *pendingURL;
@property (nonatomic, strong) SXBrowserHostView *hostView;
@property (nonatomic, readwrite, strong) NSView *authPopupContainerView;
@property (nonatomic, readwrite, strong, nullable) NSURL *activeAuthPopupURL;
@property (nonatomic, strong) SXTopEdgeColorSampler *colorSampler;
@property (nonatomic, strong, nullable) NSTimer *overshootSpringTimer;
@property (nonatomic, strong, nullable) CADisplayLink *overshootDisplayLink API_AVAILABLE(macos(14.0));
@property (nonatomic, assign) CGFloat currentOvershootScale;
@property (nonatomic, assign) CFTimeInterval overshootSpringStart;
@property (nonatomic, assign) CGFloat overshootSpringFrom;
@property (nonatomic, assign) NSPoint overshootAnchor;
@property (nonatomic, assign) BOOL hasOvershootAnchor;

@property (nonatomic, readwrite, copy) NSString *tabIdentifier;
@property (nonatomic, readwrite, strong, nullable) NSURL *currentURL;
@property (nonatomic, readwrite, copy) NSString *title;
@property (nonatomic, readwrite, getter=isLoading) BOOL loading;
@property (nonatomic, readwrite) double estimatedProgress;
@property (nonatomic, readwrite) BOOL canGoBack;
@property (nonatomic, readwrite) BOOL canGoForward;
@property (nonatomic, readwrite, strong, nullable) NSImage *favicon;
@property (nonatomic, readwrite) SXConnectionSecurityState connectionSecurityState;
@property (nonatomic, readwrite, copy, nullable) NSString *connectionSecurityHost;
@property (nonatomic, assign) NSUInteger faviconGeneration;
@property (nonatomic, readwrite) CGFloat scrollY;
@property (nonatomic, readwrite) CGFloat contentHeight;
@property (nonatomic, readwrite) CGFloat viewportHeight;
@property (nonatomic, readwrite) BOOL canInnerScrollUp;
@property (nonatomic, readwrite) BOOL canInnerScrollDown;
@property (nonatomic, readwrite) BOOL canScrollLeft;
@property (nonatomic, readwrite) BOOL canScrollRight;
@property (nonatomic, readwrite) BOOL pageConsumesPinchZoom;
@property (nonatomic, readwrite) CGFloat pageScale;
@property (nonatomic, readwrite) CGFloat overscrollY;
@property (nonatomic, readwrite, getter=isPullToRefreshArmed) BOOL pullToRefreshArmed;
@property (nonatomic, readwrite, strong, nullable) NSImage *cachedSnapshot;
@property (nonatomic, readwrite) NSInteger currentNavigationEntryID;
@property (nonatomic, readwrite) NSInteger previousNavigationEntryID;
@property (nonatomic, readwrite) NSInteger nextNavigationEntryID;
@property (nonatomic, readwrite, copy) NSArray<NSNumber *> *validNavigationEntryIDs;
@property (nonatomic, readwrite, strong, nullable) NSColor *pageBackgroundColor;
@property (nonatomic, readwrite, strong, nullable) NSColor *lastSampledTopEdgeColor;
@property (nonatomic, readwrite, strong, nullable) NSColor *fixedHeaderColor;
@property (nonatomic, strong, nullable) NSColor *domFixedHeaderColor;
@property (nonatomic, strong, nullable) dispatch_source_t scrollSnapshotTimer;
@property (nonatomic, assign) CGFloat lastSnapshotScrollY;
@property (nonatomic, assign) NSInteger lastSnapshotEntryID;
@property (nonatomic, strong, nullable) NSWindow *devToolsWindow;
@property (nonatomic, strong, nullable) id<NSWindowDelegate> devToolsWindowDelegate;
@property (nonatomic, assign) SXDevToolsDockMode devToolsDockMode;
@property (nonatomic, assign) NSWindowStyleMask originalDevToolsStyleMask;
@property (nonatomic, strong, nullable) NSTitlebarAccessoryViewController *devToolsTitlebarAccessory;
@property (nonatomic, weak, nullable) NSWindow *observedHostWindow;
@property (nonatomic, strong, nullable) NSTimer *devToolsCaptureTimer;
@property (nonatomic, strong, nullable) id devToolsMouseMonitor;
- (void)handleDevToolsCreatedWithWindow:(NSWindow *)devWindow;
- (void)syncDockedDevToolsWindowFrame;

@end

namespace {

class SXDevToolsClient : public CefClient,
                         public CefLifeSpanHandler {
 public:
  explicit SXDevToolsClient(SXBrowserTab *tab) : tab_(tab) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    [[SXEngineRuntime sharedRuntime] noteBrowserCreated];
    if (!browser || !browser->GetHost()) return;
    NSView *devView = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    SXBrowserTab *strongTab = tab_;
    if (devView && strongTab) {
      dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *devWin = devView.window;
        if (devWin) {
          [strongTab handleDevToolsCreatedWithWindow:devWin];
        }
      });
    }
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
    (void)browser;
    [[SXEngineRuntime sharedRuntime] noteBrowserClosed];
    SXBrowserTab *strongTab = tab_;
    if (strongTab) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [strongTab handleDevToolsClosed];
      });
    }
  }

 private:
  __weak SXBrowserTab *tab_;
  IMPLEMENT_REFCOUNTING(SXDevToolsClient);
};

class SXAuthPopupClient : public CefClient,
                          public CefLifeSpanHandler,
                          public CefDisplayHandler,
                          public CefLoadHandler {
 public:
  explicit SXAuthPopupClient(SXBrowserTab *tab) : tab_(tab) {}

  void DetachTab() { tab_ = nil; }

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    (void)browser;
    (void)frame;
    (void)source_process;
    if (!message) return false;
    if (message->GetName().ToString() == "sx.auth_event") {
      CefRefPtr<CefListValue> args = message->GetArgumentList();
      if (!args || args->GetSize() < 1) return true;
      std::string payload = args->GetString(0).ToString();
      NSString *jsonStr = [NSString stringWithUTF8String:payload.c_str()] ?: @"";
      SXBrowserTab *strongTab = tab_;
      if (strongTab) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [strongTab handleAuthEventJSON:jsonStr];
        });
      }
      return true;
    }
    return false;
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    [[SXEngineRuntime sharedRuntime] noteBrowserCreated];
    SXBrowserTab *strongTab = tab_;
    if (strongTab) {
      [strongTab handleAuthPopupBrowserCreated:browser];
    } else if (browser && browser->GetHost()) {
      browser->GetHost()->CloseBrowser(true);
    }
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
    (void)frame;
    (void)popup_id;
    (void)target_frame_name;
    (void)target_disposition;
    (void)user_gesture;
    (void)popupFeatures;
    (void)windowInfo;
    (void)client;
    (void)settings;
    (void)extra_info;
    (void)no_javascript_access;
    std::string urlStr = target_url.ToString();
    if (!urlStr.empty() && browser && browser->GetMainFrame()) {
      browser->GetMainFrame()->LoadURL(target_url);
    }
    return true;
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    bool stillAttachedToWindow = false;
    if (browser && browser->GetHost()) {
      NSView *cefView = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
      if (cefView && cefView.superview) {
        [cefView removeFromSuperview];
      }
      stillAttachedToWindow = (cefView && cefView.window != nil);
    }
    return stillAttachedToWindow;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    [[SXEngineRuntime sharedRuntime] noteBrowserClosed];
    SXBrowserTab *strongTab = tab_;
    if (strongTab) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [strongTab handleAuthPopupClosed:browser];
      });
    }
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    (void)browser;
    if (!frame || !frame->IsMain()) return;
    std::string u = url.ToString();
    NSString *nsStr = u.empty() ? @"" : [NSString stringWithUTF8String:u.c_str()];
    NSURL *nsURL = nsStr.length > 0 ? [NSURL URLWithString:nsStr] : nil;
    SXBrowserTab *strongTab = tab_;
    if (strongTab && nsURL) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [strongTab handleAuthPopupURLChanged:nsURL];
      });
    }
  }

 private:
  __weak SXBrowserTab *tab_;
  IMPLEMENT_REFCOUNTING(SXAuthPopupClient);
};

}  // namespace

@interface SXDevToolsWindowDelegate : NSObject <NSWindowDelegate>
@property (nonatomic, weak, nullable) SXBrowserTab *ownerTab;
@end

@implementation SXDevToolsWindowDelegate
- (void)windowWillClose:(NSNotification *)notification {
  (void)notification;
  [self.ownerTab closeDevTools];
}
@end

@interface SXSaveFormatAccessoryController : NSObject
@property (nonatomic, weak, nullable) NSSavePanel *panel;
@property (nonatomic, strong) NSPopUpButton *formatPopup;
@property (nonatomic, strong) NSView *accessoryView;
- (instancetype)initWithPanel:(NSSavePanel *)panel;
- (void)formatChanged:(id)sender;
@end

@implementation SXSaveFormatAccessoryController

- (instancetype)initWithPanel:(NSSavePanel *)panel {
  if ((self = [super init])) {
    _panel = panel;
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 44)];
    NSTextField *label = [NSTextField labelWithString:@"Format:"];
    label.font = [NSFont systemFontOfSize:13.0];
    label.alignment = NSTextAlignmentRight;
    label.frame = NSMakeRect(16, 12, 64, 20);
    [container addSubview:label];

    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(88, 9, 212, 26) pullsDown:NO];
    [popup addItemWithTitle:@"Page Source"];
    [popup addItemWithTitle:@"PDF"];
    [popup selectItemAtIndex:0];
    popup.target = self;
    popup.action = @selector(formatChanged:);
    [container addSubview:popup];

    _formatPopup = popup;
    _accessoryView = container;
  }
  return self;
}

- (void)formatChanged:(id)sender {
  (void)sender;
  NSSavePanel *panel = self.panel;
  if (!panel) return;
  BOOL isPDF = (self.formatPopup.indexOfSelectedItem == 1);
  if (@available(macOS 11.0, *)) {
    panel.allowedContentTypes = isPDF ? @[UTTypePDF] : @[UTTypeHTML];
  } else {
    panel.allowedFileTypes = isPDF ? @[@"pdf"] : @[@"html", @"htm"];
  }
  NSString *currentName = panel.nameFieldStringValue ?: @"Untitled";
  NSString *stem = currentName;
  NSString *lowerExt = currentName.pathExtension.lowercaseString;
  if ([lowerExt isEqualToString:@"html"] || [lowerExt isEqualToString:@"htm"] || [lowerExt isEqualToString:@"pdf"]) {
    stem = [currentName stringByDeletingPathExtension];
  }
  if (stem.length == 0) stem = @"Untitled";
  panel.nameFieldStringValue = [stem stringByAppendingPathExtension:(isPDF ? @"pdf" : @"html")];
}

@end

@implementation SXBrowserTab

- (instancetype)initWithRuntime:(SXEngineRuntime *)runtime
                     initialURL:(nullable NSURL *)initialURL
                     parentView:(nullable NSView *)parentView
                       delegate:(nullable id<SXBrowserTabDelegate>)delegate
                      incognito:(BOOL)incognito {
  self = [super init];
  if (self) {
    _runtime = runtime;
    _incognito = incognito;
    _topContentInset = 48.0;  // SafariMetrics.toolbarHeight; the shell updates it (e.g. separate tab strip)
    _tabActiveState = YES;
    _tabIdentifier = [[NSUUID UUID] UUIDString];
    _delegate = delegate;
    _pendingURL = initialURL;
    _currentURL = initialURL;
    _title = @"";
    _pageScale = 1.0;
    _currentOvershootScale = 1.0;
    _automaticTopEdgeSamplingEnabled = YES;
    _topEdgeSampleHeightPoints = 3.0;

    NSRect initialFrame = parentView ? parentView.bounds : NSMakeRect(0, 0, 1280, 800);
    if (initialFrame.size.width < 1 || initialFrame.size.height < 1) {
      initialFrame = NSMakeRect(0, 0, 1280, 800);
    }
    _hostView = [[SXBrowserHostView alloc] initWithFrame:initialFrame];
    _hostView.ownerTab = self;
    _hostView.wantsLayer = YES;
    _hostView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self syncHostCanvasBackgroundColor];

    _authPopupContainerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 500)];
    _authPopupContainerView.wantsLayer = YES;
    _authPopupContainerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    _client = new SXBrowserClient(self);

    __weak SXBrowserTab *weakSelf = self;
    _colorSampler = [[SXTopEdgeColorSampler alloc]
        initWithWidthProvider:^CGFloat {
          SXBrowserTab *s = weakSelf;
          return s ? s.hostView.bounds.size.width : 1024.0;
        }
        readbackProvider:^(void (^resultHandler)(NSData * _Nullable imageData)) {
          SXBrowserTab *s = weakSelf;
          if (!s || !s->_client || !s->_browser || s->_isClosed || s.hostView.isHidden) {
            resultHandler(nil);
            return;
          }
          s->_client->CaptureSurfaceForTopEdgeSample(
              [resultHandler](const std::string& imageBytes) {
                NSData *data = !imageBytes.empty()
                                   ? [NSData dataWithBytes:imageBytes.data()
                                                    length:imageBytes.size()]
                                   : nil;
                resultHandler(data);
              });
        }];
    _colorSampler.automaticSamplingEnabled = _automaticTopEdgeSamplingEnabled;
    _colorSampler.stripHeightPoints = _topEdgeSampleHeightPoints;
    _colorSampler.backingScaleProvider = ^CGFloat {
      SXBrowserTab *s = weakSelf;
      if (s && s.hostView.window && s.hostView.window.backingScaleFactor >= 1.0) {
        return s.hostView.window.backingScaleFactor;
      }
      return [NSScreen mainScreen] ? [NSScreen mainScreen].backingScaleFactor : 2.0;
    };
    _colorSampler.topOffsetPointsProvider = ^CGFloat {
      SXBrowserTab *s = weakSelf;
      if (!s) return 0.0;
      double z = s.pageZoomFactor > 0.1 ? s.pageZoomFactor : 1.0;
      return MAX(0.0, round(s->_topContentInset * z));
    };
    _colorSampler.onColorSampled = ^(NSColor *color, double luminance) {
      SXBrowserTab *s = weakSelf;
      if (!s || s->_isClosed) return;
      s.lastSampledTopEdgeColor = color;
      [s reconcileFixedHeaderColorWithPixelSample];
      __weak SXBrowserTab *weakTab = s;
      [s deliverChromeUpdate:^{
        SXBrowserTab *t = weakTab;
        if (t && [t.delegate respondsToSelector:@selector(browserTab:didSampleTopEdgeColor:relativeLuminance:)]) {
          [t.delegate browserTab:t didSampleTopEdgeColor:color relativeLuminance:luminance];
        }
      }];
    };

    if (parentView) {
      [self attachToParentView:parentView];
    }
    [self startPreviewSnapshotTimer];
  }
  return self;
}

- (void)dealloc {
  if (_previewSnapshotTimer) {
    dispatch_source_cancel(_previewSnapshotTimer);
    _previewSnapshotTimer = nil;
  }
  _cachedSnapshot = nil;
  [_colorSampler invalidate];
  _colorSampler = nil;
  [self stopOvershootAnimation];
  _authPopupClient = nullptr;
  _authPopupBrowser = nullptr;
  if (_client) {
    _client->DetachTab();
    _client = nullptr;
  }
  _browser = nullptr;
}

- (void)setAutomaticTopEdgeSamplingEnabled:(BOOL)automaticTopEdgeSamplingEnabled {
  _automaticTopEdgeSamplingEnabled = automaticTopEdgeSamplingEnabled;
  self.colorSampler.automaticSamplingEnabled = automaticTopEdgeSamplingEnabled;
}

- (void)setTopEdgeSampleHeightPoints:(CGFloat)topEdgeSampleHeightPoints {
  _topEdgeSampleHeightPoints = MAX(2.0, MIN(4.0, topEdgeSampleHeightPoints));
  self.colorSampler.stripHeightPoints = _topEdgeSampleHeightPoints;
}

- (NSView *)contentView {
  return self.hostView;
}

- (BOOL)isScrolledToTop {
  return self.scrollY <= 0.5;
}

- (int)chromiumBrowserIdentifier {
  return _browser ? _browser->GetIdentifier() : 1;
}

- (void)attachToParentView:(NSView *)parentView {
  if (!parentView) {
    return;
  }
  if (self.hostView.superview != parentView) {
    [self.hostView removeFromSuperview];
    self.hostView.frame = parentView.bounds;
    self.hostView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [parentView addSubview:self.hostView];
  } else if (!NSEqualRects(self.hostView.frame, parentView.bounds)) {
    self.hostView.frame = parentView.bounds;
  }
  SXSyncSubviewHierarchy(self.hostView, self.hostView.bounds, self.hostView.isHidden);
  [self createChromiumBrowserIfNeeded];
  if (_browser && _browser->GetHost()) {
    _browser->GetHost()->NotifyScreenInfoChanged();
  }
}

- (void)detachFromParentView {
  [self.colorSampler notifyScrollGestureActive:NO];
  if (_browser && _browser->GetHost()) {
    _browser->GetHost()->SetFocus(false);
  }
  [self.hostView removeFromSuperview];
}

- (void)setTabActive:(BOOL)active {
  if (_isClosed) {
    return;
  }
  BOOL currentlyVisible = !self.hostView.isHidden &&
                          self.hostView.alphaValue > 0.99 &&
                          !self.hostView.layer.hidden;
  if (active && currentlyVisible && _tabActiveState) {
    // Already active & visible: avoid redundant needsDisplay / NotifyScreenInfoChanged / colorSampler thrash
    // that causes a visible page flicker on every link click.
    if (self.hostView.superview && !NSEqualRects(self.hostView.frame, self.hostView.superview.bounds)) {
      self.hostView.frame = self.hostView.superview.bounds;
      SXSyncSubviewHierarchy(self.hostView, self.hostView.bounds, NO);
    }
    return;
  }
  if (!active && !currentlyVisible && !_tabActiveState) {
    return;
  }
  _tabActiveState = active;
  SXFreezeLog(@"tabActive=%d url=%@", active, self.currentURL.host);
  if (!active) {
    // Keep the standing copy: it is exactly what the tab showed and covers its repaint when it comes back.
    id standby = _standbyImage;
    [self discardFreezeFrame];
    _standbyImage = standby;
    CFTimeInterval hiddenAt = CACurrentMediaTime();
    _tabHiddenAt = hiddenAt;
    __weak SXBrowserTab *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      SXBrowserTab *strongSelf = weakSelf;
      if (strongSelf && !strongSelf->_tabActiveState && strongSelf->_tabHiddenAt == hiddenAt) {
        strongSelf->_standbyImage = nil;  // long in the background: free the memory
      }
    });
  }

  // (No capture on the way out: it would complete after the hide below, and Chromium returns an empty surface for
  // a hidden view. The periodic / scroll-settle / load-end captures keep the preview and standing copy current.)
  self.hostView.hidden = !active;
  self.hostView.alphaValue = active ? 1.0 : 0.0;
  self.hostView.layer.hidden = !active;
  SXSyncSubviewHierarchy(self.hostView, self.hostView.bounds, !active);

  if (active) {
    if (self.hostView.superview) {
      self.hostView.frame = self.hostView.superview.bounds;
      SXSyncSubviewHierarchy(self.hostView, self.hostView.bounds, NO);
    }
    [self handleHostViewVisibilityChanged:NO];
    [self presentStandbyForTabShow];
    [self.runtime scheduleMessagePumpWorkWithDelayMs:0];
    [[SXExtensionManager sharedManager] notifyActiveTabChanged];
  } else {
    [self handleHostViewVisibilityChanged:YES];
  }
}

- (void)focusWebContent {
  if (_isClosed || self.hostView.isHidden) {
    return;
  }
  NSWindow *window = self.hostView.window;
  NSView *rwhv = SXFindFocusableWebView(self.hostView, self.hostView.devToolsContainer);
  if (window && rwhv) {
    [window makeFirstResponder:rwhv];
  }
  if (_browser && _browser->GetHost()) {
    _browser->GetHost()->SetFocus(true);
  }
}

- (void)handleHostViewVisibilityChanged:(BOOL)hidden {
  if (_isClosed) {
    return;
  }
  if (hidden) {
    if (_browser && _browser->GetHost()) {
      _browser->GetHost()->SetFocus(false);
    }
    NSWindow *window = self.hostView.window;
    if (window && [window.firstResponder isKindOfClass:[NSView class]]) {
      NSView *frView = (NSView *)window.firstResponder;
      if ([frView isDescendantOf:self.hostView]) {
        [window makeFirstResponder:nil];
      }
    }
  } else {
    if (_browser && _browser->GetHost()) {
      _browser->GetHost()->NotifyScreenInfoChanged();
      _browser->GetHost()->SetFocus(true);
    }
    // Restore first responder to Chromium's RenderWidgetHostViewCocoa unless the user
    // is actively typing in an AppKit text field (such as the address bar or search bar).
    NSWindow *window = self.hostView.window;
    if (window) {
      NSResponder *currentFR = window.firstResponder;
      BOOL isEditingText = [currentFR isKindOfClass:[NSText class]] ||
                           [currentFR isKindOfClass:[NSTextField class]];
      if (!isEditingText) {
        NSView *rwhv = SXFindFocusableWebView(self.hostView);
        if (rwhv) {
          [window makeFirstResponder:rwhv];
        }
      }
    }
    [self.colorSampler notifyTabActivated];
  }
}

- (void)handleHostViewFrameChanged {
  if (_isClosed) {
    return;
  }
  if (_freezeOverlay || _freezeImage) {
    NSRect webRect = [self.hostView webContentRectForBounds:self.hostView.bounds];
    CGFloat scale = self.hostView.window.backingScaleFactor ?: 2.0;
    id img = _freezeOverlay ? _freezeOverlay.layer.contents : _freezeImage;
    if (!img || fabs((CGFloat)SXFreezeImageWidth(img) - webRect.size.width * scale) > 2.0 ||
        fabs((CGFloat)SXFreezeImageHeight(img) - webRect.size.height * scale) > 2.0) {
      [self discardFreezeFrame];
    }
  }
  [self.colorSampler notifyResizeActivity];
  if (_browser && _browser->GetHost()) {
    _browser->GetHost()->NotifyScreenInfoChanged();
  }
}

- (void)createChromiumBrowserIfNeeded {
  if (_browserCreationRequested || _isClosed) {
    return;
  }
  if (![self.runtime isContextInitialized]) {
    return;
  }
  _browserCreationRequested = YES;

  NSRect bounds = self.hostView.bounds;
  if (bounds.size.width < 1 || bounds.size.height < 1) {
    bounds = NSMakeRect(0, 0, 1280, 800);
    self.hostView.frame = bounds;
  }

  CefWindowInfo windowInfo;
  CefRect cefBounds(0, 0, (int)std::round(bounds.size.width),
                    (int)std::round(bounds.size.height));
  // Embeds Chromium's RenderWidgetHostViewCocoa directly into SafariShell's NSView
  // without Chrome's own toolbar/tabstrip, running inside CEF 156's Chrome runtime.
  windowInfo.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(self.hostView), cefBounds);

  CefBrowserSettings browserSettings;
  // Match macOS Safari's exact default web font families and sizes.
  CefString(&browserSettings.standard_font_family).FromASCII("Times");
  CefString(&browserSettings.serif_font_family).FromASCII("Times");
  CefString(&browserSettings.sans_serif_font_family).FromASCII("Helvetica");
  CefString(&browserSettings.fixed_font_family).FromASCII("Courier");
  CefString(&browserSettings.cursive_font_family).FromASCII("Apple Chancery");
  CefString(&browserSettings.fantasy_font_family).FromASCII("Papyrus");
  browserSettings.default_font_size = 16;
  browserSettings.default_fixed_font_size = 13;
  // Match pre-paint background to Dark Mode or Private Browsing to prevent white flashes during navigation.
  BOOL preferDarkPrepaint = _incognito;
  if (!preferDarkPrepaint && NSApp) {
    NSAppearanceName best = [NSApp.effectiveAppearance
        bestMatchFromAppearancesWithNames:@[NSAppearanceNameDarkAqua, NSAppearanceNameAqua]];
    preferDarkPrepaint = [best isEqualToString:NSAppearanceNameDarkAqua];
  }
  browserSettings.background_color = preferDarkPrepaint
      ? CefColorSetARGB(0xFF, 0x1C, 0x1C, 0x1E)
      : CefColorSetARGB(0xFF, 0xFF, 0xFF, 0xFF);
  NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
  if ([ud objectForKey:@"Safarium.Pref.EnableJavaScript"] != nil &&
      ![ud boolForKey:@"Safarium.Pref.EnableJavaScript"]) {
    browserSettings.javascript = STATE_DISABLED;
  }
  if ([ud boolForKey:@"Safarium.Pref.MinFontEnabled"]) {
    static const int kMinSizes[] = {9, 10, 11, 12, 14, 16, 18, 24};
    NSInteger idx = [ud integerForKey:@"Safarium.Pref.MinFontSize"];
    if (idx < 0) idx = 0;
    if (idx > 7) idx = 7;
    browserSettings.minimum_font_size = kMinSizes[idx];
  }
  static const char *kEncodings[] = {"UTF-8", "ISO-8859-1", "windows-1252", "ISO-8859-9", "Shift_JIS"};
  NSInteger encIdx = [ud integerForKey:@"Safarium.Pref.DefaultEncoding"];
  if (encIdx >= 0 && encIdx < 5) {
    CefString(&browserSettings.default_encoding).FromASCII(kEncodings[encIdx]);
  }

  CefRefPtr<CefRequestContext> requestContext = nullptr;
  if (_incognito && _runtime) {
    requestContext = [_runtime sharedIncognitoRequestContext];
  }

  CefRefPtr<CefDictionaryValue> extraInfo =
      SXBuildPrivacyExtraInfoDictionary(_incognito ? true : false);
  if (extraInfo) extraInfo->SetInt("sx_top_inset", (int)lround(_topContentInset));

  NSString *urlStr = self.pendingURL.absoluteString ?: @"about:blank";
  BOOL created = CefBrowserHost::CreateBrowser(
      windowInfo, _client, CefString(urlStr.UTF8String), browserSettings,
      extraInfo, requestContext);
  if (getenv("SAFARIUM_CEF_DEBUG")) {
    fprintf(stderr, "[BrowserCore] CreateBrowser(%s) -> %d (bounds %.0fx%.0f)\n",
            urlStr.UTF8String, created ? 1 : 0, bounds.size.width,
            bounds.size.height);
    fflush(stderr);
  }
}

- (void)handleBrowserCreated:(CefRefPtr<CefBrowser>)browser {
  SXInstallRenderWidgetVisibilityHook();
  if (_isClosed) {
    // The tab was closed while CreateBrowser was still pending: tear the late browser down instead of leaking a
    // live, hidden WebContents that keeps loading (and playing audio) with no tab attached.
    if (browser && browser->GetHost()) {
      browser->GetHost()->SetFocus(false);
      browser->GetHost()->CloseBrowser(true);
    }
    return;
  }
  _browser = browser;
  if (browser && browser->GetHost()) {
    NSView *cefView =
        CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    if (cefView) {
      cefView.frame = self.hostView.bounds;
      cefView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      cefView.hidden = self.hostView.isHidden;
      cefView.alphaValue = self.hostView.isHidden ? 0.0 : 1.0;
      cefView.layer.hidden = self.hostView.isHidden;
    }
    browser->GetHost()->NotifyScreenInfoChanged();
    if (!self.hostView.isHidden) {
      browser->GetHost()->SetFocus(true);
    } else {
      browser->GetHost()->SetFocus(false);
    }
  }
  [self pushTopContentInsetToMainFrame];
  if (self.pendingURL && _browser && _browser->GetMainFrame()) {
    NSString *current = [NSString
        stringWithUTF8String:_browser->GetMainFrame()->GetURL().ToString().c_str()];
    if (![current isEqualToString:self.pendingURL.absoluteString]) {
      _browser->GetMainFrame()->LoadURL(
          CefString(self.pendingURL.absoluteString.UTF8String));
    }
  }
}

- (void)handleBrowserClosing {
  [self stopPreviewSnapshotTimerAndReleaseCache];
  [self.colorSampler invalidate];
  [self.hostView removeFromSuperview];
}

- (void)handleBrowserClosed {
  _isClosed = YES;
  _browser = nullptr;
  if (_closeNotified) return;  // closeTab (pending creation) and the late browser's OnBeforeClose both end up here
  _closeNotified = YES;
  [self stopPreviewSnapshotTimerAndReleaseCache];
  [self.colorSampler invalidate];
  [self.hostView removeFromSuperview];
  [self.runtime tabDidClose:self];
  if ([self.delegate respondsToSelector:@selector(browserTabDidClose:)]) {
    [self.delegate browserTabDidClose:self];
  }
}

- (void)closeTab {
  if (_isClosed) {
    return;
  }
  [self discardFreezeFrame];
  _isClosed = YES;
  [self closeAuthPopup];
  [self closeDevTools];
  [self stopPreviewSnapshotTimerAndReleaseCache];
  [self.colorSampler invalidate];
  if (_browser && _browser->GetHost()) {
    _browser->GetHost()->SetFocus(false);
    // Detach hostView BEFORE CloseBrowser(true) so CEF tears down only this tab's
    // WebContents and can never send performClose: to the host NSWindow.
    [self.hostView removeFromSuperview];
    _browser->GetHost()->CloseBrowser(true);
  } else {
    [self handleBrowserClosed];
  }
}

#pragma mark Navigation

- (NSColor *)defaultPrepaintCanvasColor {
  BOOL preferDark = _incognito;
  if (!preferDark) {
    NSAppearance *app = self.hostView.effectiveAppearance ?: (NSApp ? NSApp.effectiveAppearance : nil);
    if (app) {
      NSAppearanceName best = [app bestMatchFromAppearancesWithNames:@[NSAppearanceNameDarkAqua, NSAppearanceNameAqua]];
      preferDark = [best isEqualToString:NSAppearanceNameDarkAqua];
    }
  }
  return preferDark
      ? [NSColor colorWithSRGBRed:(28.0 / 255.0) green:(28.0 / 255.0) blue:(30.0 / 255.0) alpha:1.0]
      : [NSColor colorWithSRGBRed:1.0 green:1.0 blue:1.0 alpha:1.0];
}

- (void)syncHostCanvasBackgroundColor {
  if (!self.hostView) return;
  self.hostView.wantsLayer = YES;
  NSColor *target = self.pageBackgroundColor ?: [self defaultPrepaintCanvasColor];
  NSColor *srgb = [target colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: target;
  self.hostView.layer.backgroundColor = srgb.CGColor;
}

- (void)handleHostEffectiveAppearanceChanged {
  if (!self.pageBackgroundColor) {
    [self syncHostCanvasBackgroundColor];
  }
}

- (void)flushPendingOriginThemeResetIfNeeded {
  if (!_pendingOriginThemeReset) return;
  _pendingOriginThemeReset = NO;
  if (self.fixedHeaderColor != nil) {
    self.fixedHeaderColor = nil;
    __weak SXBrowserTab *weakSelf = self;
    [self deliverChromeUpdate:^{
      SXBrowserTab *t = weakSelf;
      if (t && [t.delegate respondsToSelector:@selector(browserTab:didUpdateFixedHeaderColor:)]) {
        [t.delegate browserTab:t didUpdateFixedHeaderColor:nil];
      }
    }];
  }
}

- (void)loadURL:(NSURL *)url {
  if (!url) {
    return;
  }
  NSString *prevHost = self.currentURL.host.lowercaseString ?: @"";
  NSString *newHost = url.host.lowercaseString ?: @"";
  NSString *prevScheme = self.currentURL.scheme.lowercaseString ?: @"";
  NSString *newScheme = url.scheme.lowercaseString ?: @"";
  BOOL originChanged = ![prevHost isEqualToString:newHost] || ![prevScheme isEqualToString:newScheme];

  [self.runtime notifyNavigationBurst];
  [self.colorSampler notifyNavigationStarted];
  self.pendingURL = url;
  self.currentURL = url;
  self.estimatedProgress = 0.0;
  self.loading = YES;
  self.domFixedHeaderColor = nil;
  if (self.fixedHeaderColor != nil) {
    // Defer clearing fixedHeaderColor until the incoming document commits/reveals so
    // toolbar tint transitions once in lockstep with page reveal rather than snapping twice.
    _pendingOriginThemeReset = YES;
  }
  if (originChanged) {
    _previewCaptureGeneration += 1;  // invalidate any snapshot still decoding for the previous page
    self.pageBackgroundColor = nil;
    [self syncHostCanvasBackgroundColor];
    self.faviconGeneration += 1;
    if (self.favicon != nil) {
      self.favicon = nil;
      if ([self.delegate respondsToSelector:@selector(browserTab:didUpdateFavicon:)]) {
        [self.delegate browserTab:self didUpdateFavicon:nil];
      }
    }
  }
  if ([self.delegate respondsToSelector:@selector(browserTab:didUpdateProgress:)]) {
    [self.delegate browserTab:self didUpdateProgress:0.0];
  }
  if (_browser && _browser->GetMainFrame()) {
    [self handleMainFrameNavigationWillStart];
    _browser->GetMainFrame()->LoadURL(CefString(url.absoluteString.UTF8String));
  }
}

- (void)loadURLString:(NSString *)urlString {
  if (urlString.length == 0) {
    return;
  }
  NSString *trimmed =
      [urlString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSURL *url = [NSURL URLWithString:trimmed];
  if (!url || !url.scheme) {
    url = [NSURL URLWithString:[@"https://" stringByAppendingString:trimmed]];
  }
  if (url) {
    [self loadURL:url];
  }
}

- (void)prewarmOrigin:(NSURL *)url {
  if (_isClosed || _incognito || !url || !_browser || !_browser->GetMainFrame()) {
    return;
  }
  NSString *scheme = url.scheme.lowercaseString;
  NSString *host = url.host.lowercaseString;
  if (!host.length || !([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])) {
    return;
  }
  NSCharacterSet *unsafe = [NSCharacterSet characterSetWithCharactersInString:@"\"'<>\\ \t\r\n"];
  if ([host rangeOfCharacterFromSet:unsafe].location != NSNotFound) {
    return;
  }
  NSString *origin = url.port ? [NSString stringWithFormat:@"%@://%@:%@", scheme, host, url.port]
                              : [NSString stringWithFormat:@"%@://%@", scheme, host];
  CFTimeInterval now = CACurrentMediaTime();
  if (_lastPrewarmedOrigin && [_lastPrewarmedOrigin isEqualToString:origin] && (now - _lastPrewarmedAt) < 15.0) {
    return;
  }
  _lastPrewarmedOrigin = [origin copy];
  _lastPrewarmedAt = now;
  NSString *js = [NSString stringWithFormat:
      @"(function(){try{var h=document.head||document.documentElement;if(!h)return;"
      @"var id='__sx_pw_'+btoa('%@').replace(/[^a-zA-Z0-9]/g,'');if(document.getElementById(id))return;"
      @"var l=document.createElement('link');l.id=id;l.rel='preconnect';l.href='%@';l.crossOrigin='anonymous';"
      @"h.appendChild(l);}catch(_){}})();",
      origin, origin];
  _browser->GetMainFrame()->ExecuteJavaScript(CefString(js.UTF8String), CefString(), 0);
}

- (void)pushTopContentInsetToMainFrame {
  if (_browser && _browser->GetMainFrame() && _browser->GetMainFrame()->IsValid()) {
    CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create("sx.top_inset");
    msg->GetArgumentList()->SetInt(0, (int)lround(_topContentInset));
    _browser->GetMainFrame()->SendProcessMessage(PID_RENDERER, msg);
  }
}

- (void)probeScrollStateAtCSSPoint:(NSPoint)point {
  if (_isClosed || !_browser || !_browser->GetMainFrame() || !_browser->GetMainFrame()->IsValid()) {
    return;
  }
  CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create("sx.probe_point");
  msg->GetArgumentList()->SetInt(0, (int)lround(point.x));
  msg->GetArgumentList()->SetInt(1, (int)lround(point.y));
  _browser->GetMainFrame()->SendProcessMessage(PID_RENDERER, msg);
}

- (void)setTopContentInset:(CGFloat)topContentInset {
  CGFloat v = MAX(0.0, round(topContentInset));
  if (fabs(v - _topContentInset) < 0.5) return;
  _topContentInset = v;
  [self pushTopContentInsetToMainFrame];
}

- (void)goBack {
  if (_browser && _browser->CanGoBack()) {
    [self.runtime notifyNavigationBurst];
    if (self.fixedHeaderColor != nil) {
      _pendingOriginThemeReset = YES;
    }
    self.estimatedProgress = 0.0;
    [self handleMainFrameNavigationWillStart];
    // Back/forward-cache restores swap views within ~1 ms of this call, before any fresh copy could exist:
    // pin the standing copy (identical to the screen) right away.
    [self presentFreezeFrameIfReady];
    _browser->GoBack();
  }
}

- (void)goForward {
  if (_browser && _browser->CanGoForward()) {
    [self.runtime notifyNavigationBurst];
    if (self.fixedHeaderColor != nil) {
      _pendingOriginThemeReset = YES;
    }
    self.estimatedProgress = 0.0;
    [self handleMainFrameNavigationWillStart];
    // Back/forward-cache restores swap views within ~1 ms of this call, before any fresh copy could exist:
    // pin the standing copy (identical to the screen) right away.
    [self presentFreezeFrameIfReady];
    _browser->GoForward();
  }
}

- (void)reload {
  if (_browser) {
    self.estimatedProgress = 0.0;
    if ([self.delegate respondsToSelector:@selector(browserTab:didUpdateProgress:)]) {
      [self.delegate browserTab:self didUpdateProgress:0.0];
    }
    [self handleMainFrameNavigationWillStart];
    _browser->Reload();
  }
}

- (void)reloadIgnoringCache {
  if (_browser) {
    self.estimatedProgress = 0.0;
    if ([self.delegate respondsToSelector:@selector(browserTab:didUpdateProgress:)]) {
      [self.delegate browserTab:self didUpdateProgress:0.0];
    }
    [self handleMainFrameNavigationWillStart];
    _browser->ReloadIgnoreCache();
  }
}

- (void)stopLoading {
  if (_browser) {
    _browser->StopLoad();
  }
}

static const void *kSXDockedDevToolsKeyWindowFlag = &kSXDockedDevToolsKeyWindowFlag;
static NSMutableSet<NSString *> *SXSwizzledDevToolsWindowClasses(void) {
  static NSMutableSet<NSString *> *set = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
  return set;
}

static void SXEnsureBorderlessWindowCanBecomeKey(NSWindow *win) {
  if (!win) return;
  objc_setAssociatedObject(win, kSXDockedDevToolsKeyWindowFlag, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  Class cls = [win class];
  NSString *clsName = NSStringFromClass(cls);
  NSMutableSet<NSString *> *done = SXSwizzledDevToolsWindowClasses();
  if ([done containsObject:clsName]) return;
  [done addObject:clsName];

  // 1. Allow borderless docked DevTools window to become key and receive clicks/typing
  {
    SEL sel = @selector(canBecomeKeyWindow);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
      BOOL (*origIMP)(id, SEL) = (BOOL (*)(id, SEL))method_getImplementation(m);
      IMP newIMP = imp_implementationWithBlock(^BOOL(id selfObj) {
        if ([objc_getAssociatedObject(selfObj, kSXDockedDevToolsKeyWindowFlag) boolValue]) {
          return YES;
        }
        return origIMP ? origIMP(selfObj, sel) : NO;
      });
      if (!class_addMethod(cls, sel, newIMP, method_getTypeEncoding(m))) {
        method_setImplementation(m, newIMP);
      }
    }
  }

  // 2. Prevent Chrome's BrowserWindow minSize / contentMinSize (~300px) from clamping docked frames above the control bar
  {
    SEL sel = @selector(minSize);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
      NSSize (*origIMP)(id, SEL) = (NSSize (*)(id, SEL))method_getImplementation(m);
      IMP newIMP = imp_implementationWithBlock(^NSSize(id selfObj) {
        if ([objc_getAssociatedObject(selfObj, kSXDockedDevToolsKeyWindowFlag) boolValue]) {
          return NSMakeSize(100.0, 80.0);
        }
        return origIMP ? origIMP(selfObj, sel) : NSMakeSize(100.0, 80.0);
      });
      if (!class_addMethod(cls, sel, newIMP, method_getTypeEncoding(m))) {
        method_setImplementation(m, newIMP);
      }
    }
  }
  {
    SEL sel = @selector(contentMinSize);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
      NSSize (*origIMP)(id, SEL) = (NSSize (*)(id, SEL))method_getImplementation(m);
      IMP newIMP = imp_implementationWithBlock(^NSSize(id selfObj) {
        if ([objc_getAssociatedObject(selfObj, kSXDockedDevToolsKeyWindowFlag) boolValue]) {
          return NSMakeSize(100.0, 80.0);
        }
        return origIMP ? origIMP(selfObj, sel) : NSMakeSize(100.0, 80.0);
      });
      if (!class_addMethod(cls, sel, newIMP, method_getTypeEncoding(m))) {
        method_setImplementation(m, newIMP);
      }
    }
  }

  // 3. Bypass screen/titlebar frame clamping when docked inside the browser window
  {
    SEL sel = @selector(constrainFrameRect:toScreen:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
      NSRect (*origIMP)(id, SEL, NSRect, NSScreen *) = (NSRect (*)(id, SEL, NSRect, NSScreen *))method_getImplementation(m);
      IMP newIMP = imp_implementationWithBlock(^NSRect(id selfObj, NSRect frameRect, NSScreen *screen) {
        if ([objc_getAssociatedObject(selfObj, kSXDockedDevToolsKeyWindowFlag) boolValue]) {
          return frameRect;
        }
        return origIMP ? origIMP(selfObj, sel, frameRect, screen) : frameRect;
      });
      if (!class_addMethod(cls, sel, newIMP, method_getTypeEncoding(m))) {
        method_setImplementation(m, newIMP);
      }
    }
  }
}

static void SXApplyDockedDevToolsCornerMask(NSWindow *devWindow, SXDevToolsDockMode mode, NSSize size) {
  if (!devWindow) return;
  NSView *cv = devWindow.contentView;
  if (!cv) return;
  cv.wantsLayer = YES;
  CALayer *layer = cv.layer;
  if (!layer) return;

  if (mode == SXDevToolsDockSeparate || size.width < 10 || size.height < 10) {
    layer.mask = nil;
    return;
  }

  CGFloat r = 16.0;
  CGFloat rBL = (mode == SXDevToolsDockBottom || mode == SXDevToolsDockLeft) ? r : 0.0;
  CGFloat rBR = (mode == SXDevToolsDockBottom || mode == SXDevToolsDockRight) ? r : 0.0;
  CGFloat w = size.width;
  CGFloat h = size.height;

  CGMutablePathRef path = CGPathCreateMutable();
  // Start at top-left (non-flipped layer coords: y = h is top, y = 0 is bottom)
  CGPathMoveToPoint(path, NULL, 0, h);
  CGPathAddLineToPoint(path, NULL, w, h);
  if (rBR > 0) {
    CGPathAddLineToPoint(path, NULL, w, rBR);
    CGPathAddArcToPoint(path, NULL, w, 0, w - rBR, 0, rBR);
  } else {
    CGPathAddLineToPoint(path, NULL, w, 0);
  }
  if (rBL > 0) {
    CGPathAddLineToPoint(path, NULL, rBL, 0);
    CGPathAddArcToPoint(path, NULL, 0, 0, 0, rBL, rBL);
  } else {
    CGPathAddLineToPoint(path, NULL, 0, 0);
  }
  CGPathCloseSubpath(path);

  CAShapeLayer *mask = [layer.mask isKindOfClass:[CAShapeLayer class]]
                           ? (CAShapeLayer *)layer.mask
                           : [CAShapeLayer layer];
  mask.frame = CGRectMake(0, 0, w, h);
  mask.path = path;
  layer.mask = mask;
  CGPathRelease(path);
}

- (void)devToolsNativeWindowWillClose:(NSNotification *)notification {
  if (notification.object == self.devToolsWindow) {
    [self handleDevToolsClosed];
  }
}

- (SXDevToolsDockMode)resolvedPreferredDevToolsDockMode {
  NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
  if ([ud boolForKey:@"Safarium.Pref.DevSeparateDevTools"]) {
    return SXDevToolsDockSeparate;
  }
  if ([ud objectForKey:@"Safarium.Pref.DevToolsDockMode"] != nil) {
    NSInteger saved = [ud integerForKey:@"Safarium.Pref.DevToolsDockMode"];
    if (saved == SXDevToolsDockLeft || saved == SXDevToolsDockRight || saved == SXDevToolsDockBottom) {
      return (SXDevToolsDockMode)saved;
    }
  }
  return SXDevToolsDockBottom;
}

- (void)ensureDockedViewsInstalledForMode:(SXDevToolsDockMode)mode {
  NSString *hostTitle = self.currentURL.host.length > 0 ? self.currentURL.host : (self.title.length > 0 ? self.title : @"Page");
  NSString *barTitle = [NSString stringWithFormat:@"Web Inspector — %@", hostTitle];

  if (!self.hostView.devToolsContainer) {
    NSView *container = [[NSView alloc] initWithFrame:NSZeroRect];
    container.wantsLayer = YES;
    [self.hostView addSubview:container];
    self.hostView.devToolsContainer = container;
  }
  if (!self.hostView.devToolsControlBar) {
    SXDevToolsControlBarView *bar = [[SXDevToolsControlBarView alloc] initWithFrame:NSZeroRect showCloseButton:YES];
    bar.ownerTab = self;
    [self.hostView addSubview:bar];
    self.hostView.devToolsControlBar = bar;
  }
  if (!self.hostView.devToolsSplitter) {
    SXDevToolsSplitterView *splitter = [[SXDevToolsSplitterView alloc] initWithFrame:NSZeroRect];
    splitter.hostView = self.hostView;
    [self.hostView addSubview:splitter];
    self.hostView.devToolsSplitter = splitter;
  }

  self.hostView.devToolsDockMode = mode;
  self.hostView.devToolsDocked = YES;
  self.hostView.devToolsControlBar.inspectorTitle = barTitle;
  [self.hostView.devToolsControlBar updateActiveMode:mode];
  [self.hostView syncLayoutAndVisibility];
  [self handleHostViewFrameChanged];
}

- (void)removeDockedViewsFromHost {
  if (!self.hostView.devToolsDocked) return;
  self.hostView.devToolsDocked = NO;
  [self.hostView.devToolsContainer removeFromSuperview];
  [self.hostView.devToolsControlBar removeFromSuperview];
  [self.hostView.devToolsSplitter removeFromSuperview];
  self.hostView.devToolsContainer = nil;
  self.hostView.devToolsControlBar = nil;
  self.hostView.devToolsSplitter = nil;
  [self.hostView syncLayoutAndVisibility];
  [self handleHostViewFrameChanged];
}

- (void)removeSeparateTitlebarAccessoryFromWindow:(NSWindow *)win {
  if (self.devToolsTitlebarAccessory && win) {
    NSUInteger idx = [win.titlebarAccessoryViewControllers indexOfObject:self.devToolsTitlebarAccessory];
    if (idx != NSNotFound) {
      [win removeTitlebarAccessoryViewControllerAtIndex:idx];
    }
  }
  self.devToolsTitlebarAccessory = nil;
}

- (void)installSeparateTitlebarAccessoryOnWindow:(NSWindow *)win {
  [self removeSeparateTitlebarAccessoryFromWindow:win];
  if (!win) return;
  NSTitlebarAccessoryViewController *acc = [[NSTitlebarAccessoryViewController alloc] init];
  SXDevToolsControlBarView *bar = [[SXDevToolsControlBarView alloc] initWithFrame:NSMakeRect(0, 0, 122, 26) showCloseButton:NO];
  bar.ownerTab = self;
  [bar updateActiveMode:SXDevToolsDockSeparate];
  acc.view = bar;
  acc.layoutAttribute = NSLayoutAttributeTrailing;
  [win addTitlebarAccessoryViewController:acc];
  self.devToolsTitlebarAccessory = acc;
}

- (void)applyDockModeToCurrentDevToolsWindow {
  NSWindow *devWindow = self.devToolsWindow;
  if (!devWindow) return;

  NSString *hostTitle = self.currentURL.host.length > 0 ? self.currentURL.host : (self.title.length > 0 ? self.title : @"Page");
  if (self.devToolsDockMode == SXDevToolsDockSeparate) {
    if (self.devToolsMouseMonitor) {
      [NSEvent removeMonitor:self.devToolsMouseMonitor];
      self.devToolsMouseMonitor = nil;
    }
    if (self.observedHostWindow) {
      [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidMoveNotification object:self.observedHostWindow];
      [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidResizeNotification object:self.observedHostWindow];
      self.observedHostWindow = nil;
    }
    if (devWindow.parentWindow) {
      [devWindow.parentWindow removeChildWindow:devWindow];
    }
    [self removeDockedViewsFromHost];

    objc_setAssociatedObject(devWindow, kSXDockedDevToolsKeyWindowFlag, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSWindowStyleMask restoredStyle = self.originalDevToolsStyleMask;
    if (restoredStyle == 0 || restoredStyle == NSWindowStyleMaskBorderless) {
      restoredStyle = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                      NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    }
    devWindow.styleMask = restoredStyle;
    devWindow.opaque = YES;
    devWindow.backgroundColor = [NSColor windowBackgroundColor];
    devWindow.minSize = NSMakeSize(420.0, 260.0);
    devWindow.contentMinSize = NSMakeSize(420.0, 260.0);
    SXApplyDockedDevToolsCornerMask(devWindow, SXDevToolsDockSeparate, NSZeroSize);
    devWindow.hasShadow = YES;
    devWindow.movable = YES;
    devWindow.titleVisibility = NSWindowTitleVisible;
    devWindow.titlebarAppearsTransparent = NO;
    devWindow.ignoresMouseEvents = NO;
    devWindow.alphaValue = 1.0;
    devWindow.title = [NSString stringWithFormat:@"Web Inspector — %@", hostTitle];
    [self installSeparateTitlebarAccessoryOnWindow:devWindow];

    NSWindow *mainWin = self.hostView.window ?: NSApp.keyWindow;
    if (mainWin) {
      NSRect mf = mainWin.frame;
      NSRect df = NSMakeRect(mf.origin.x + 48, fmax(40, mf.origin.y + 36), 980, 680);
      [devWindow setFrame:df display:YES];
    }
    [devWindow makeKeyAndOrderFront:nil];
  } else {
    [self removeSeparateTitlebarAccessoryFromWindow:devWindow];
    [self ensureDockedViewsInstalledForMode:self.devToolsDockMode];

    SXEnsureBorderlessWindowCanBecomeKey(devWindow);
    devWindow.styleMask = NSWindowStyleMaskBorderless;
    devWindow.opaque = NO;
    devWindow.backgroundColor = [NSColor clearColor];
    devWindow.minSize = NSMakeSize(100.0, 80.0);
    devWindow.contentMinSize = NSMakeSize(100.0, 80.0);
    devWindow.hasShadow = NO;
    devWindow.movable = NO;
    devWindow.acceptsMouseMovedEvents = YES;
    devWindow.ignoresMouseEvents = NO;
    devWindow.titleVisibility = NSWindowTitleHidden;
    devWindow.titlebarAppearsTransparent = YES;

    NSWindow *mainWin = self.hostView.window ?: NSApp.keyWindow;
    if (mainWin) {
      if (self.observedHostWindow != mainWin) {
        if (self.observedHostWindow) {
          [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidMoveNotification object:self.observedHostWindow];
          [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidResizeNotification object:self.observedHostWindow];
        }
        self.observedHostWindow = mainWin;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(syncDockedDevToolsWindowFrame) name:NSWindowDidMoveNotification object:mainWin];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(syncDockedDevToolsWindowFrame) name:NSWindowDidResizeNotification object:mainWin];
      }
      if (devWindow.parentWindow != mainWin) {
        [mainWin addChildWindow:devWindow ordered:NSWindowAbove];
      }
    }

    if (!self.devToolsMouseMonitor) {
      __weak SXBrowserTab *weakSelf = self;
      self.devToolsMouseMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown)
                                                                        handler:^NSEvent * _Nullable(NSEvent *ev) {
        SXBrowserTab *s = weakSelf;
        if (!s || s.devToolsDockMode == SXDevToolsDockSeparate || !s.devToolsWindow) return ev;
        if (ev.window == s.devToolsWindow && !s.devToolsWindow.isKeyWindow) {
          [s.devToolsWindow makeKeyWindow];
        }
        return ev;
      }];
    }

    [self syncDockedDevToolsWindowFrame];
    [devWindow makeKeyAndOrderFront:nil];
    __weak SXBrowserTab *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [weakSelf syncDockedDevToolsWindowFrame];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [weakSelf syncDockedDevToolsWindowFrame];
    });
  }
}

- (void)setDevToolsDockMode:(SXDevToolsDockMode)mode {
  NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
  BOOL isSep = (mode == SXDevToolsDockSeparate);
  [ud setBool:isSep forKey:@"Safarium.Pref.DevSeparateDevTools"];
  if (!isSep) {
    [ud setInteger:mode forKey:@"Safarium.Pref.DevToolsDockMode"];
  }
  _devToolsDockMode = mode;
  if (self.devToolsWindow) {
    [self applyDockModeToCurrentDevToolsWindow];
  } else if (!isSep && self.hostView.devToolsDocked) {
    [self ensureDockedViewsInstalledForMode:mode];
  }
}

- (void)handleDevToolsCreatedWithWindow:(NSWindow *)devWindow {
  if (!devWindow || _isClosed) return;
  if (self.devToolsWindow == devWindow) {
    [self syncDockedDevToolsWindowFrame];
    return;
  }
  [self.devToolsCaptureTimer invalidate];
  self.devToolsCaptureTimer = nil;

  self.devToolsWindow = devWindow;
  self.originalDevToolsStyleMask = devWindow.styleMask;
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(devToolsNativeWindowWillClose:)
                                               name:NSWindowWillCloseNotification
                                             object:devWindow];
  [self applyDockModeToCurrentDevToolsWindow];
}

- (void)syncDockedDevToolsWindowFrame {
  if (self.devToolsDockMode == SXDevToolsDockSeparate || !self.devToolsWindow || !self.hostView.devToolsDocked || !self.hostView.devToolsContainer) {
    return;
  }
  NSWindow *mainWin = self.hostView.window;
  if (!mainWin || self.hostView.isHidden || !mainWin.isVisible || mainWin.isMiniaturized) {
    [self.devToolsWindow setAlphaValue:0.0];
    [self.devToolsWindow setIgnoresMouseEvents:YES];
    return;
  }
  SXEnsureBorderlessWindowCanBecomeKey(self.devToolsWindow);
  if (self.devToolsWindow.styleMask != NSWindowStyleMaskBorderless) {
    self.devToolsWindow.styleMask = NSWindowStyleMaskBorderless;
    self.devToolsWindow.opaque = NO;
    self.devToolsWindow.backgroundColor = [NSColor clearColor];
    self.devToolsWindow.minSize = NSMakeSize(100.0, 80.0);
    self.devToolsWindow.contentMinSize = NSMakeSize(100.0, 80.0);
    self.devToolsWindow.hasShadow = NO;
    self.devToolsWindow.movable = NO;
  }
  self.devToolsWindow.acceptsMouseMovedEvents = YES;
  if (self.devToolsWindow.parentWindow != mainWin) {
    [self.devToolsWindow.parentWindow removeChildWindow:self.devToolsWindow];
    [mainWin addChildWindow:self.devToolsWindow ordered:NSWindowAbove];
  }
  NSRect rectInWin = [self.hostView.devToolsContainer convertRect:self.hostView.devToolsContainer.bounds toView:nil];
  NSRect rectScreen = [mainWin convertRectToScreen:rectInWin];
  // Snap to integer points so Chromium's compositor surface & rounded corner mask stay razor-sharp
  rectScreen = NSMakeRect(round(rectScreen.origin.x),
                          round(rectScreen.origin.y),
                          round(rectScreen.size.width),
                          round(rectScreen.size.height));
  if (rectScreen.size.width >= 20 && rectScreen.size.height >= 20) {
    if (!NSEqualRects(self.devToolsWindow.frame, rectScreen)) {
      [self.devToolsWindow setFrame:rectScreen display:YES animate:NO];
    }
    SXApplyDockedDevToolsCornerMask(self.devToolsWindow, self.devToolsDockMode, rectScreen.size);
    [self.devToolsWindow setAlphaValue:1.0];
    [self.devToolsWindow setIgnoresMouseEvents:NO];
  }
}

- (void)handleDevToolsClosed {
  [self.devToolsCaptureTimer invalidate];
  self.devToolsCaptureTimer = nil;
  if (self.devToolsMouseMonitor) {
    [NSEvent removeMonitor:self.devToolsMouseMonitor];
    self.devToolsMouseMonitor = nil;
  }
  if (_client) {
    _client->SetDevToolsOpen(false);
  }
  if (self.observedHostWindow) {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidMoveNotification object:self.observedHostWindow];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidResizeNotification object:self.observedHostWindow];
    self.observedHostWindow = nil;
  }
  [self removeDockedViewsFromHost];
  if (self.devToolsWindow) {
    NSWindow *w = self.devToolsWindow;
    self.devToolsWindow = nil;
    self.devToolsWindowDelegate = nil;
    [self removeSeparateTitlebarAccessoryFromWindow:w];
    objc_setAssociatedObject(w, kSXDockedDevToolsKeyWindowFlag, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowWillCloseNotification object:w];
    if (w.parentWindow) {
      [w.parentWindow removeChildWindow:w];
    }
    w.delegate = nil;
  }
}

- (void)closeDevTools {
  if (_browser && _browser->GetHost() && _browser->GetHost()->HasDevTools()) {
    _browser->GetHost()->CloseDevTools();
  }
  [self handleDevToolsClosed];
}

- (void)showDevTools {
  [self showDevToolsAtPoint:NSZeroPoint];
}

- (void)startPollingForDevToolsWindowExcluding:(NSSet<NSWindow *> *)existingWindows {
  [self.devToolsCaptureTimer invalidate];
  __weak SXBrowserTab *weakSelf = self;
  __block int attempts = 0;
  self.devToolsCaptureTimer = [NSTimer scheduledTimerWithTimeInterval:0.02
                                                              repeats:YES
                                                                block:^(NSTimer *timer) {
    SXBrowserTab *strongSelf = weakSelf;
    if (!strongSelf || strongSelf->_isClosed || strongSelf.devToolsWindow != nil) {
      [timer invalidate];
      if (strongSelf) strongSelf.devToolsCaptureTimer = nil;
      return;
    }
    attempts++;
    for (NSWindow *win in NSApp.windows) {
      if ([existingWindows containsObject:win]) continue;
      if ([win isKindOfClass:[NSPanel class]]) continue;
      NSString *cls = NSStringFromClass([win class]);
      NSString *title = win.title ?: @"";
      BOOL isChromeDevWin = [cls containsString:@"NativeWidget"] ||
                            [cls containsString:@"Browser"] ||
                            [cls containsString:@"Chrome"] ||
                            [title rangeOfString:@"DevTools" options:NSCaseInsensitiveSearch].location != NSNotFound;
      if (isChromeDevWin && win.frame.size.width > 100 && win.frame.size.height > 100) {
        [timer invalidate];
        strongSelf.devToolsCaptureTimer = nil;
        [strongSelf handleDevToolsCreatedWithWindow:win];
        return;
      }
    }
    if (attempts >= 100) {
      [timer invalidate];
      strongSelf.devToolsCaptureTimer = nil;
    }
  }];
}

- (void)showDevToolsAtPoint:(NSPoint)point {
  if (!_browser || !_browser->GetHost()) {
    return;
  }

  SXDevToolsDockMode desiredMode = [self resolvedPreferredDevToolsDockMode];
  CefPoint inspectAt((int)std::round(point.x), (int)std::round(point.y));

  if (_browser->GetHost()->HasDevTools()) {
    if (self.devToolsDockMode != desiredMode) {
      [self setDevToolsDockMode:desiredMode];
    } else if (desiredMode == SXDevToolsDockSeparate && self.devToolsWindow) {
      [self.devToolsWindow makeKeyAndOrderFront:nil];
    } else {
      [self syncDockedDevToolsWindowFrame];
    }
    if (point.x > 0 || point.y > 0) {
      CefWindowInfo dummyWin;
      dummyWin.parent_view = nullptr;
      dummyWin.runtime_style = CEF_RUNTIME_STYLE_CHROME;
      CefBrowserSettings dummySettings;
      _browser->GetHost()->ShowDevTools(dummyWin, nullptr, dummySettings, inspectAt);
    }
    return;
  }

  if (_client) {
    _client->SetDevToolsOpen(true);
  }
  _devToolsDockMode = desiredMode;

  NSSet<NSWindow *> *beforeWindows = [NSSet setWithArray:NSApp.windows];

  if (desiredMode != SXDevToolsDockSeparate) {
    [self ensureDockedViewsInstalledForMode:desiredMode];
  }

  [self startPollingForDevToolsWindowExcluding:beforeWindows];

  CefWindowInfo devWin;
  devWin.parent_view = nullptr;
  devWin.runtime_style = CEF_RUNTIME_STYLE_CHROME;
  CefBrowserSettings devSettings;
  CefRefPtr<CefClient> devClient = new SXDevToolsClient(self);
  _browser->GetHost()->ShowDevTools(devWin, devClient, devSettings, inspectAt);
}

namespace {
class SXPdfPrintCallback : public CefPdfPrintCallback {
 public:
  explicit SXPdfPrintCallback(void (^completion)(BOOL)) : completion_([completion copy]) {}
  void OnPdfPrintFinished(const CefString& path, bool ok) override {
    (void)path;
    if (completion_) {
      void (^cb)(BOOL) = completion_;
      dispatch_async(dispatch_get_main_queue(), ^{
        cb(ok ? YES : NO);
      });
    }
  }
 private:
  void (^completion_)(BOOL);
  IMPLEMENT_REFCOUNTING(SXPdfPrintCallback);
};

class SXPageSourceVisitor : public CefStringVisitor {
 public:
  explicit SXPageSourceVisitor(void (^completion)(NSString * _Nullable))
      : completion_([completion copy]) {}
  void Visit(const CefString& string) override {
    if (!completion_) return;
    std::string utf8 = string.ToString();
    NSString *html = [[NSString alloc] initWithBytes:utf8.data()
                                              length:utf8.size()
                                            encoding:NSUTF8StringEncoding];
    if (!html) {
      html = [NSString stringWithUTF8String:utf8.c_str()] ?: @"";
    }
    void (^cb)(NSString * _Nullable) = completion_;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(html);
    });
  }
 private:
  void (^completion_)(NSString * _Nullable);
  IMPLEMENT_REFCOUNTING(SXPageSourceVisitor);
};
}  // namespace

- (void)executeJavaScript:(NSString *)script {
  if (!_browser || script.length == 0) {
    return;
  }
  CefRefPtr<CefFrame> mainFrame = _browser->GetMainFrame();
  if (mainFrame && mainFrame->IsValid()) {
    mainFrame->ExecuteJavaScript(CefString(script.UTF8String), mainFrame->GetURL(), 0);
  }
}

- (void)executeJavaScriptInAllFrames:(NSString *)script {
  if (script.length == 0) {
    return;
  }
  CefString js(script.UTF8String);
  if (_browser) {
    std::vector<CefString> ids;
    _browser->GetFrameIdentifiers(ids);
    for (const auto& fid : ids) {
      CefRefPtr<CefFrame> f = _browser->GetFrameByIdentifier(fid);
      if (f && f->IsValid()) {
        f->ExecuteJavaScript(js, f->GetURL(), 0);
      }
    }
  }
  if (_authPopupBrowser) {
    std::vector<CefString> pids;
    _authPopupBrowser->GetFrameIdentifiers(pids);
    for (const auto& fid : pids) {
      CefRefPtr<CefFrame> f = _authPopupBrowser->GetFrameByIdentifier(fid);
      if (f && f->IsValid()) {
        f->ExecuteJavaScript(js, f->GetURL(), 0);
      }
    }
  }
}

- (void)executeJavaScriptInAuthPopup:(NSString *)script {
  if (!_authPopupBrowser || script.length == 0) {
    return;
  }
  CefString js(script.UTF8String);
  std::vector<CefString> ids;
  _authPopupBrowser->GetFrameIdentifiers(ids);
  for (const auto& fid : ids) {
    CefRefPtr<CefFrame> f = _authPopupBrowser->GetFrameByIdentifier(fid);
    if (f && f->IsValid()) {
      f->ExecuteJavaScript(js, f->GetURL(), 0);
    }
  }
}

- (BOOL)hasActiveAuthPopup {
  return _authPopupBrowser != nullptr;
}

- (void)closeAuthPopup {
  [self dismissAuthPopupWindow];
  CefRefPtr<CefBrowser> popup = _authPopupBrowser;
  _authPopupBrowser = nullptr;
  _authPopupClient = nullptr;
  self.activeAuthPopupURL = nil;
  if (popup && popup->GetHost()) {
    popup->GetHost()->SetFocus(false);
    NSView *cefView = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(popup->GetHost()->GetWindowHandle());
    if (cefView && cefView.superview) {
      [cefView removeFromSuperview];
    }
    popup->GetHost()->CloseBrowser(true);
  }
}

- (void)printPage {
  if (!_browser || !_browser->GetHost()) {
    return;
  }
  _browser->GetHost()->Print();
}

- (void)exportToPDFAtPath:(NSString *)filePath
               completion:(nullable void (^)(BOOL success))completion {
  if (!_browser || !_browser->GetHost() || filePath.length == 0) {
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
    }
    return;
  }
  CefPdfPrintSettings settings;
  settings.print_background = 1;
  settings.prefer_css_page_size = 1;
  CefRefPtr<CefPdfPrintCallback> cb = new SXPdfPrintCallback(completion);
  _browser->GetHost()->PrintToPDF(CefString(filePath.UTF8String), settings, cb);
}

- (void)getPageSourceWithCompletion:(void (^)(NSString * _Nullable htmlSource))completion {
  if (!completion) return;
  if (_isClosed || !_browser) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
    return;
  }
  CefRefPtr<CefBrowser> targetBrowser = _browser;
  void (^cb)(NSString * _Nullable) = [completion copy];
  CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
      ^(CefRefPtr<CefBrowser> b) {
        CefRefPtr<CefFrame> mainFrame = b ? b->GetMainFrame() : nullptr;
        if (!mainFrame || !mainFrame->IsValid()) {
          dispatch_async(dispatch_get_main_queue(), ^{ cb(nil); });
          return;
        }
        mainFrame->GetSource(new SXPageSourceVisitor(cb));
      },
      targetBrowser)));
}

static NSString *SXSanitizedSaveFileBaseName(NSString * _Nullable title, NSURL * _Nullable url) {
  NSString *candidate = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (candidate.length == 0) {
    NSString *last = url.lastPathComponent;
    if (last.length > 0 && ![last isEqualToString:@"/"]) {
      candidate = last;
    } else if (url.host.length > 0) {
      candidate = url.host;
    } else {
      candidate = @"Untitled";
    }
  }
  NSString *ext = candidate.pathExtension.lowercaseString;
  if ([ext isEqualToString:@"html"] || [ext isEqualToString:@"htm"] || [ext isEqualToString:@"pdf"]) {
    NSString *stripped = [candidate stringByDeletingPathExtension];
    if (stripped.length > 0) candidate = stripped;
  }
  NSMutableCharacterSet *illegal = [NSMutableCharacterSet characterSetWithCharactersInString:@"/:\\?%*|\"<>"];
  [illegal formUnionWithCharacterSet:[NSCharacterSet controlCharacterSet]];
  [illegal formUnionWithCharacterSet:[NSCharacterSet newlineCharacterSet]];
  NSArray<NSString *> *parts = [candidate componentsSeparatedByCharactersInSet:illegal];
  NSString *clean = [[parts componentsJoinedByString:@"-"]
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  while ([clean hasPrefix:@"."]) {
    clean = [clean substringFromIndex:1];
  }
  if (clean.length > 120) {
    clean = [clean substringToIndex:120];
  }
  return clean.length > 0 ? clean : @"Untitled";
}

- (void)savePageWithPanelForWindow:(nullable NSWindow *)window
                        completion:(nullable void (^)(BOOL saved, NSURL * _Nullable savedURL))completion {
  if (_isClosed || !_browser) {
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, nil); });
    }
    return;
  }

  dispatch_block_t presentPanel = ^{
    if (self->_isClosed || !self->_browser) {
      if (completion) completion(NO, nil);
      return;
    }
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.canCreateDirectories = YES;
    panel.extensionHidden = NO;
    NSString *baseName = SXSanitizedSaveFileBaseName(self.title, self.currentURL);
    panel.nameFieldStringValue = [baseName stringByAppendingPathExtension:@"html"];
    if (@available(macOS 11.0, *)) {
      panel.allowedContentTypes = @[UTTypeHTML];
    } else {
      panel.allowedFileTypes = @[@"html", @"htm"];
    }
    SXSaveFormatAccessoryController *accessory = [[SXSaveFormatAccessoryController alloc] initWithPanel:panel];
    panel.accessoryView = accessory.accessoryView;

    __weak SXBrowserTab *weakSelf = self;
    void (^handleResult)(NSModalResponse) = ^(NSModalResponse response) {
      SXBrowserTab *strongSelf = weakSelf;
      // Keep accessory alive until panel finishes.
      BOOL isPDF = (accessory.formatPopup.indexOfSelectedItem == 1);
      if (response != NSModalResponseOK || !panel.URL || !strongSelf || strongSelf->_isClosed) {
        if (completion) completion(NO, nil);
        return;
      }
      NSURL *destURL = panel.URL;
      if (isPDF || [destURL.pathExtension.lowercaseString isEqualToString:@"pdf"]) {
        [strongSelf exportToPDFAtPath:destURL.path completion:^(BOOL success) {
          if (completion) completion(success, success ? destURL : nil);
        }];
      } else {
        [strongSelf getPageSourceWithCompletion:^(NSString * _Nullable htmlSource) {
          if (!htmlSource) {
            if (completion) completion(NO, nil);
            return;
          }
          NSError *writeErr = nil;
          BOOL ok = [htmlSource writeToURL:destURL
                                atomically:YES
                                  encoding:NSUTF8StringEncoding
                                     error:&writeErr];
          if (completion) completion(ok, ok ? destURL : nil);
        }];
      }
    };

    NSWindow *targetWindow = window ?: self.hostView.window;
    if (targetWindow && targetWindow.isVisible) {
      [panel beginSheetModalForWindow:targetWindow completionHandler:handleResult];
    } else {
      NSModalResponse resp = [panel runModal];
      handleResult(resp);
    }
  };

  if ([NSThread isMainThread]) {
    presentPanel();
  } else {
    dispatch_async(dispatch_get_main_queue(), presentPanel);
  }
}

- (void)setAudioMuted:(BOOL)muted {
  if (!_browser || !_browser->GetHost()) {
    return;
  }
  _browser->GetHost()->SetAudioMuted(muted ? true : false);
}

- (BOOL)isAudioMuted {
  if (!_browser || !_browser->GetHost()) {
    return NO;
  }
  return _browser->GetHost()->IsAudioMuted() ? YES : NO;
}

#pragma mark Top-Edge Surface Sampling

- (void)sampleTopEdgeColorWithStripHeightPoints:(CGFloat)stripHeightPoints
                                     completion:(void (^)(NSColor * _Nullable color,
                                                          double relativeLuminance))completion {
  [self.colorSampler sampleNowWithStripHeightPoints:stripHeightPoints
                                         completion:completion];
}

#pragma mark Zoom, Pinch Scale, Downloads, Find, Snapshot

- (void)setPageZoomFactor:(double)zoomFactor {
  if (!_browser || !_browser->GetHost() || zoomFactor <= 0.0) {
    return;
  }
  // Chromium zoom level satisfies zoomFactor = 1.2 ^ zoomLevel.
  double zoomLevel = std::log(zoomFactor) / std::log(1.2);
  _browser->GetHost()->SetZoomLevel(zoomLevel);
}

- (double)pageZoomFactor {
  if (!_browser || !_browser->GetHost()) {
    return 1.0;
  }
  double zoomLevel = _browser->GetHost()->GetZoomLevel();
  return std::pow(1.2, zoomLevel);
}

- (void)setPageScale:(CGFloat)scale {
  CGFloat clamped = MAX(1.0, MIN(4.0, scale));
  _pageScale = clamped;
  if (_client && _browser && !_isClosed) {
    if (clamped <= 1.001) {
      _client->ResetPageScaleFactor();
    } else {
      _client->SetPageScaleFactor((double)clamped);
    }
  }
  if ([self.delegate respondsToSelector:@selector(browserTab:didUpdatePageScale:isPinching:)]) {
    [self.delegate browserTab:self didUpdatePageScale:clamped isPinching:NO];
  }
}

- (CGFloat)applyPinchMagnification:(CGFloat)magnification
                           atPoint:(NSPoint)viewPoint
                        isPinching:(BOOL)isPinching {
  // Deprecated for live trackpad gestures: Chromium's native 120fps GPU compositor
  // (RenderWidgetHostViewCocoa) handles trackpad pinch-to-zoom directly with cursor anchor.
  // Do NOT drive live pinch through async CDP Emulation.setPageScaleFactor.
  (void)magnification;
  (void)viewPoint;
  (void)isPinching;
  return _pageScale > 0.01 ? _pageScale : 1.0;
}

- (void)resetPageScale {
  _pageScale = 1.0;
  [self applyHostOvershootTransform:1.0];
  if (_client && _browser && !_isClosed) {
    _client->ResetPageScaleFactor();
  }
  if ([self.delegate respondsToSelector:@selector(browserTab:didUpdatePageScale:isPinching:)]) {
    [self.delegate browserTab:self didUpdatePageScale:1.0 isPinching:NO];
  }
}

- (void)stopOvershootAnimation {
  [_overshootSpringTimer invalidate];
  _overshootSpringTimer = nil;
  if (@available(macOS 14.0, *)) {
    [_overshootDisplayLink invalidate];
    _overshootDisplayLink = nil;
  }
}

- (void)applyHostOvershootTransform:(CGFloat)scale {
  _currentOvershootScale = scale;
  CALayer *layer = self.hostView.layer;
  if (!layer) {
    return;
  }
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (scale >= 0.9995) {
    layer.transform = CATransform3DIdentity;
    _hasOvershootAnchor = NO;
  } else {
    CGSize sz = self.hostView.bounds.size;
    CGFloat ax = _hasOvershootAnchor ? MAX(0.0, MIN(sz.width, _overshootAnchor.x)) : (sz.width * 0.5);
    CGFloat ay = _hasOvershootAnchor ? MAX(0.0, MIN(sz.height, _overshootAnchor.y)) : (sz.height * 0.5);
    CATransform3D t = CATransform3DMakeTranslation(ax, ay, 0);
    t = CATransform3DScale(t, scale, scale, 1.0);
    t = CATransform3DTranslate(t, -ax, -ay, 0);
    layer.transform = t;
  }
  [CATransaction commit];
}

- (void)setPageOvershootScale:(CGFloat)scale {
  [self stopOvershootAnimation];
  _hasOvershootAnchor = NO;
  CGFloat clamped = MAX(0.75, MIN(1.0, scale));
  [self applyHostOvershootTransform:clamped];
}

- (void)setPageOvershootScale:(CGFloat)scale anchorPoint:(NSPoint)anchorPoint {
  [self stopOvershootAnimation];
  _overshootAnchor = anchorPoint;
  _hasOvershootAnchor = YES;
  CGFloat clamped = MAX(0.75, MIN(1.0, scale));
  [self applyHostOvershootTransform:clamped];
}

- (void)stepOvershootSpring {
  double t = MAX(0.0, CACurrentMediaTime() - _overshootSpringStart);
  double w = 16.0;
  double decay = (1.0 + w * t) * std::exp(-w * t);
  if (decay < 0.002 || t > 0.6) {
    [self stopOvershootAnimation];
    [self applyHostOvershootTransform:1.0];
    return;
  }
  CGFloat nextScale = 1.0 - (1.0 - _overshootSpringFrom) * (CGFloat)decay;
  [self applyHostOvershootTransform:nextScale];
}

- (void)handleOvershootDisplayLink:(CADisplayLink *)link API_AVAILABLE(macos(14.0)) {
  (void)link;
  [self stepOvershootSpring];
}

- (void)endPageOvershoot {
  [self stopOvershootAnimation];
  CGFloat from = _currentOvershootScale;
  if (from >= 0.9995) {
    [self applyHostOvershootTransform:1.0];
    return;
  }
  _overshootSpringFrom = from;
  _overshootSpringStart = CACurrentMediaTime();
  // Critically damped Safari spring back: x(t) = (1 + W*t) * e^(-W*t), W = 16 (~0.35s)
  if (@available(macOS 14.0, *)) {
    if (self.hostView.window) {
      CADisplayLink *link = [self.hostView displayLinkWithTarget:self selector:@selector(handleOvershootDisplayLink:)];
      [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
      _overshootDisplayLink = link;
      return;
    }
  }
  __weak SXBrowserTab *weakSelf = self;
  _overshootSpringTimer = [NSTimer timerWithTimeInterval:(1.0 / 120.0)
                                                 repeats:YES
                                                   block:^(NSTimer * _Nonnull timer) {
    SXBrowserTab *strongSelf = weakSelf;
    if (!strongSelf) {
      [timer invalidate];
      return;
    }
    [strongSelf stepOvershootSpring];
  }];
  [[NSRunLoop mainRunLoop] addTimer:_overshootSpringTimer forMode:NSRunLoopCommonModes];
}

- (void)notifyScrollPhase:(SXScrollPhase)phase {
  // No-op: native AppKit ElasticScrollEngine owns trackpad scroll phase tracking.
}

- (void)setScrollInteractionActive:(BOOL)active {
  if (_isClosed) return;
  [self.colorSampler notifyScrollGestureActive:active];
}

- (void)resetOverscroll {
  // No-op: native AppKit ElasticScrollEngine owns elastic overscroll state.
}

- (void)startDownloadAtURL:(NSURL *)url {
  if (!url || !_browser || !_browser->GetHost() || _isClosed) {
    return;
  }
  _browser->GetHost()->StartDownload(CefString(url.absoluteString.UTF8String));
}

- (void)findText:(NSString *)searchText
         forward:(BOOL)forward
       matchCase:(BOOL)matchCase
        findNext:(BOOL)findNext {
  if (!_browser || !_browser->GetHost()) {
    return;
  }
  _browser->GetHost()->Find(CefString((searchText ?: @"").UTF8String),
                            forward ? true : false, matchCase ? true : false,
                            findNext ? true : false);
}

- (void)stopFindingAndClearSelection:(BOOL)clearSelection {
  if (!_browser || !_browser->GetHost()) {
    return;
  }
  _browser->GetHost()->StopFinding(clearSelection ? true : false);
}

- (void)startPreviewSnapshotTimer {
  if (_previewSnapshotTimer || _isClosed) {
    return;
  }
  dispatch_source_t timer = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  if (!timer) {
    return;
  }
  const uint64_t intervalNs = (uint64_t)(3.0 * NSEC_PER_SEC);
  const uint64_t leewayNs = (uint64_t)(0.4 * NSEC_PER_SEC);
  dispatch_source_set_timer(timer,
                            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                            intervalNs,
                            leewayNs);
  __weak SXBrowserTab *weakSelf = self;
  dispatch_source_set_event_handler(timer, ^{
    SXBrowserTab *strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }
    [strongSelf capturePeriodicPreviewIfEligibleForce:NO];
  });
  _previewSnapshotTimer = timer;
  dispatch_resume(timer);
}

- (void)stopPreviewSnapshotTimerAndReleaseCache {
  _previewCaptureGeneration += 1;
  _previewCaptureInFlight = NO;
  if (_previewSnapshotTimer) {
    dispatch_source_cancel(_previewSnapshotTimer);
    _previewSnapshotTimer = nil;
  }
  if (_scrollSnapshotTimer) {
    dispatch_source_cancel(_scrollSnapshotTimer);
    _scrollSnapshotTimer = nil;
  }
  self.cachedSnapshot = nil;
}

- (void)updateCachedPreviewFromJPEGData:(NSData *)data {
  if (!data || data.length == 0 || _isClosed || _previewSnapshotPaused) {
    return;
  }
  NSSize logicalSize = self.hostView.bounds.size;
  if (logicalSize.width < 64.0 || logicalSize.height < 64.0) {
    return;
  }
  _lastPreviewCaptureTime = CACurrentMediaTime();
  NSUInteger captureGen = _previewCaptureGeneration;
  __weak SXBrowserTab *weakSelf = self;
  dispatch_async(SXPreviewSnapshotDecodeQueue(), ^{
    NSImage *decoded = nil;
    @autoreleasepool {
      decoded = SXDecodeDownscaledPreviewImage(data, logicalSize);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      SXBrowserTab *strongSelf = weakSelf;
      if (!strongSelf || strongSelf->_isClosed) {
        return;
      }
      if (strongSelf->_previewCaptureGeneration != captureGen) {
        return;
      }
      if (decoded) {
        strongSelf.cachedSnapshot = decoded;
        if (getenv("SAFARIUM_PREVIEW_DEBUG")) {
          fprintf(stderr, "[PreviewCache] updated from JPEG (%zu bytes -> %.0fx%.0f pt)\n",
                  (size_t)data.length, decoded.size.width, decoded.size.height);
          fflush(stderr);
        }
      }
    });
  });
}

- (void)capturePeriodicPreviewIfEligibleForce:(BOOL)force {
  if (_isClosed || !_client || !_browser || _previewCaptureInFlight || _previewSnapshotPaused) {
    return;
  }
  if (self.hostView.isHidden || self.hostView.alphaValue < 0.9) {
    return;
  }
  if (!force && !_tabActiveState) {
    return;
  }
  NSWindow *win = self.hostView.window;
  if (!win || !win.isVisible || (!force && win.inLiveResize)) {
    return;
  }
  if (self.pageScale > 1.01) {
    return;
  }
  if (!force && (fabs(self.overscrollY) > 0.5 || fabs(self.currentOvershootScale - 1.0) > 0.005)) {
    return;
  }
  NSSize logicalSize = self.hostView.bounds.size;
  if (logicalSize.width < 64.0 || logicalSize.height < 64.0) {
    return;
  }
  NSString *scheme = self.currentURL.scheme.lowercaseString;
  if (!([scheme isEqualToString:@"http"] ||
        [scheme isEqualToString:@"https"] ||
        [scheme isEqualToString:@"file"] ||
        [scheme isEqualToString:@"chrome-extension"])) {
    return;
  }
  CFTimeInterval now = CACurrentMediaTime();
  CFTimeInterval minInterval = force ? 0.25 : 2.6;
  if (_lastPreviewCaptureTime > 0.0 && (now - _lastPreviewCaptureTime) < minInterval) {
    return;
  }

  _previewCaptureInFlight = YES;
  _lastPreviewCaptureTime = now;
  NSUInteger captureGen = _previewCaptureGeneration;
  NSInteger capturedEntryID = self.currentNavigationEntryID;
  CGFloat capturedScrollY = self.scrollY;
  CGFloat backingScale = win.backingScaleFactor > 0.5 ? win.backingScaleFactor : 2.0;
  NSColor *capturedBg = self.pageBackgroundColor ?: self.lastSampledTopEdgeColor;
  CFTimeInterval capturedHiddenGen = _tabHiddenAt;
  __weak SXBrowserTab *weakSelf = self;
  // Lossless capture: it doubles as the standing freeze frame (must match the live page pixel for pixel). The
  // navigation snapshot store keeps getting compact JPEG, re-encoded here off the main thread.
  _client->CaptureFreezeFramePNG([weakSelf, logicalSize, captureGen, capturedEntryID, capturedScrollY, backingScale, capturedBg, capturedHiddenGen](const std::string& pngBytes) {
    if (pngBytes.empty()) {
      dispatch_async(dispatch_get_main_queue(), ^{
        SXBrowserTab *strongSelf = weakSelf;
        if (strongSelf) {
          strongSelf->_previewCaptureInFlight = NO;
        }
      });
      return;
    }
    NSData *pngData = [NSData dataWithBytes:pngBytes.data() length:pngBytes.size()];
    dispatch_async(SXPreviewSnapshotDecodeQueue(), ^{
      NSImage *decoded = nil;
      id fullImage = nil;
      id standbySurface = nil;
      NSData *data = nil;
      @autoreleasepool {
        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)pngData, NULL);
        if (src) {
          NSDictionary *opts = @{ (__bridge NSString *)kCGImageSourceShouldCacheImmediately : @YES };
          CGImageRef full = CGImageSourceCreateImageAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
          CFRelease(src);
          if (full) {
            fullImage = CFBridgingRelease(full);
            CGImageRef fullRef = (__bridge CGImageRef)fullImage;
            standbySurface = SXCopyImageToIOSurface(fullRef);
            decoded = SXCreateDownscaledPreviewFromCGImage(fullRef, logicalSize);
            NSMutableData *jpeg = [NSMutableData data];
            CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg,
                                                                         CFSTR("public.jpeg"), 1, NULL);
            if (dst) {
              NSDictionary *jopts = @{ (__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @0.6 };
              CGImageDestinationAddImage(dst, fullRef, (__bridge CFDictionaryRef)jopts);
              if (CGImageDestinationFinalize(dst)) data = jpeg;
              CFRelease(dst);
            }
          }
        }
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        SXBrowserTab *strongSelf = weakSelf;
        if (!strongSelf) {
          return;
        }
        strongSelf->_previewCaptureInFlight = NO;
        if (strongSelf->_isClosed) {
          return;
        }
        if (strongSelf->_previewCaptureGeneration != captureGen) {
          return;
        }
        if (!strongSelf->_tabActiveState || strongSelf.hostView.isHiddenOrHasHiddenAncestor ||
            capturedHiddenGen != strongSelf->_tabHiddenAt) {
          // Finished after the tab went to the background: Chromium hands back an empty surface then.
          return;
        }
        if (standbySurface && capturedEntryID == strongSelf.currentNavigationEntryID &&
            strongSelf->_freezeCommittedGeneration == strongSelf->_freezeGeneration && !strongSelf->_freezeOverlay) {
          strongSelf->_standbyImage = standbySurface;
          strongSelf->_standbyScale = backingScale;
          strongSelf->_standbyCapturedAt = CACurrentMediaTime();
          strongSelf->_standbyScrollY = capturedScrollY;
        }
        if (decoded && data) {
          // Atomically replace previous cached preview so ARC frees old image immediately.
          strongSelf.cachedSnapshot = decoded;
          // Only bind snapshot to a history entry if we are still on that exact entry (never mis-attribute across commits).
          if (capturedEntryID > 0 && capturedEntryID == strongSelf.currentNavigationEntryID) {
            strongSelf.lastSnapshotEntryID = capturedEntryID;
            strongSelf.lastSnapshotScrollY = capturedScrollY;
            if ([strongSelf.delegate respondsToSelector:@selector(browserTab:didUpdateNavigationSnapshotData:entryID:logicalSize:backingScale:backgroundColor:)]) {
              [strongSelf.delegate browserTab:strongSelf
              didUpdateNavigationSnapshotData:data
                                      entryID:capturedEntryID
                                  logicalSize:logicalSize
                                 backingScale:backingScale
                              backgroundColor:capturedBg];
            }
          }
        }
      });
    });
  });
}

- (void)captureSnapshotWithCompletion:(void (^)(NSImage * _Nullable image))completion {
  if (!completion) {
    return;
  }
  if (!_client || !_browser || _isClosed) {
    NSImage *fallback = self.cachedSnapshot;
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(fallback);
    });
    return;
  }
  // If tab is currently hidden, return cached crisp Retina snapshot immediately when available.
  if (self.hostView.isHidden && self.cachedSnapshot) {
    NSImage *cached = self.cachedSnapshot;
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(cached);
    });
    return;
  }

  NSSize logicalSize = self.hostView.bounds.size;
  CGFloat backingScale = self.hostView.window ? self.hostView.window.backingScaleFactor : 2.0;
  if (backingScale < 1.0) backingScale = 2.0;

  __weak SXBrowserTab *weakSelf = self;
  _client->CaptureFullSnapshotPNG(
      (double)logicalSize.width, (double)logicalSize.height,
      [weakSelf, logicalSize, backingScale, completion](const std::string& pngBytes) {
    NSImage *image = nil;
    if (!pngBytes.empty()) {
      NSData *data = [NSData dataWithBytes:pngBytes.data()
                                    length:pngBytes.size()];
      NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:data];
      if (rep) {
        // Construct true Retina NSImage: preserve full 2x pixel bitmap rep, set point size cleanly.
        NSSize pointSize = logicalSize;
        if (pointSize.width < 2.0 || pointSize.height < 2.0) {
          pointSize = NSMakeSize(rep.pixelsWide / backingScale,
                                 rep.pixelsHigh / backingScale);
        }
        image = [[NSImage alloc] initWithSize:pointSize];
        [image addRepresentation:rep];
      } else {
        image = [[NSImage alloc] initWithData:data];
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      SXBrowserTab *strongSelf = weakSelf;
      if (image && strongSelf) {
        strongSelf.cachedSnapshot = image;
      }
      completion(image ?: strongSelf.cachedSnapshot);
    });
  });
}

#pragma mark Internal Delegate Dispatchers

- (void)handleURLChanged:(NSURL *)url {
  NSString *prevHost = self.currentURL.host.lowercaseString ?: @"";
  NSString *newHost = url.host.lowercaseString ?: @"";
  NSString *prevScheme = self.currentURL.scheme.lowercaseString ?: @"";
  NSString *newScheme = url.scheme.lowercaseString ?: @"";
  BOOL originChanged = ![prevHost isEqualToString:newHost] || ![prevScheme isEqualToString:newScheme];

  self.currentURL = url;
  if (originChanged) {
    _previewCaptureGeneration += 1;
    self.pageBackgroundColor = nil;
    [self syncHostCanvasBackgroundColor];
    if (self.fixedHeaderColor != nil) {
      _pendingOriginThemeReset = YES;
    }
    self.faviconGeneration += 1;
    if (self.favicon != nil) {
      self.favicon = nil;
      if ([self.delegate respondsToSelector:@selector(browserTab:didUpdateFavicon:)]) {
        [self.delegate browserTab:self didUpdateFavicon:nil];
      }
    }
  }
  if ([self.delegate respondsToSelector:@selector(browserTab:didChangeURL:)]) {
    [self.delegate browserTab:self didChangeURL:url];
  }
  [[SXExtensionManager sharedManager] notifyActiveTabChanged];
}

- (void)handleTitleChanged:(NSString *)title {
  NSString *clean = title ?: @"";
  // Avoid overwriting a real page's title with transient "about:blank" during initial load.
  if ([clean caseInsensitiveCompare:@"about:blank"] == NSOrderedSame &&
      self.currentURL &&
      [self.currentURL.absoluteString caseInsensitiveCompare:@"about:blank"] != NSOrderedSame) {
    return;
  }
  self.title = clean;
  if ([self.delegate respondsToSelector:@selector(browserTab:didChangeTitle:)]) {
    [self.delegate browserTab:self didChangeTitle:clean];
  }
  [[SXExtensionManager sharedManager] notifyActiveTabChanged];
}

- (void)handleLoadingStateChanged:(BOOL)isLoading
                        canGoBack:(BOOL)canGoBack
                     canGoForward:(BOOL)canGoForward {
  self.canGoBack = canGoBack;
  self.canGoForward = canGoForward;

  // Ignore subframe-only loading bursts (e.g. Bitwarden password-field autofill iframe injection)
  // so clicking a password input never flashes the address bar progress bar.
  if (isLoading && !_mainFrameLoading) {
    if ([self.delegate respondsToSelector:@selector(browserTab:didChangeLoadingState:canGoBack:canGoForward:)]) {
      [self.delegate browserTab:self
          didChangeLoadingState:self.loading
                      canGoBack:canGoBack
                   canGoForward:canGoForward];
    }
    return;
  }

  BOOL wasLoading = self.loading;
  if (isLoading && !wasLoading && !_mainFrameLoading) {
    // Renderer-initiated history navigations (history.back(), back/forward cache) never reach OnBeforeBrowse.
    [self handleMainFrameNavigationWillStart];
  }
  if (!isLoading) {
    _mainFrameLoading = NO;
    if (_freezeCommittedGeneration != _freezeGeneration) {
      // Navigation ended without committing a new document (download, 204, cancelled): unfreeze.
      [self discardFreezeFrame];
    } else {
      [self releaseFreezeFrameAfterLoadIfStillHeld];
    }
  }
  self.loading = isLoading;
  if (isLoading && !wasLoading && self.estimatedProgress >= 0.99) {
    self.estimatedProgress = 0.0;
  } else if (!isLoading) {
    self.estimatedProgress = 1.0;
    if (wasLoading) {
      __weak SXBrowserTab *weakSelf = self;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
        SXBrowserTab *strongSelf = weakSelf;
        if (strongSelf) {
          [strongSelf capturePeriodicPreviewIfEligibleForce:YES];
        }
      });
    }
  }
  if ([self.delegate respondsToSelector:@selector(browserTab:didChangeLoadingState:canGoBack:canGoForward:)]) {
    [self.delegate browserTab:self
        didChangeLoadingState:isLoading
                    canGoBack:canGoBack
                 canGoForward:canGoForward];
  }
}

- (void)handleProgressChanged:(double)progress {
  if (!_mainFrameLoading && !self.loading) {
    return;
  }
  double clamped = MAX(0.0, MIN(1.0, progress));
  self.estimatedProgress = clamped;
  if ([self.delegate respondsToSelector:@selector(browserTab:didUpdateProgress:)]) {
    [self.delegate browserTab:self didUpdateProgress:clamped];
  }
}

/// A cross-document commit swaps in a new RenderWidgetHostViewCocoa that is not first responder, so the new page
/// had no focus (document.hasFocus() false) even with the window key: autofocused fields could not be typed into
/// until clicked, and Bitwarden skips positioning its inline menu without page focus, leaving its frames as bare
/// blue boxes at the top-left. Hand focus to the new view when keyboard focus was on the page or nowhere (never
/// while an AppKit text field such as the address bar is being edited).
- (void)restoreWebContentFocusAfterCommit {
  if (_isClosed || self.hostView.isHidden) return;
  NSWindow *window = self.hostView.window;
  if (!window || !window.isKeyWindow) return;
  NSResponder *fr = window.firstResponder;
  if ([fr isKindOfClass:[NSText class]] || [fr isKindOfClass:[NSTextField class]]) return;
  BOOL focusOnPageOrNowhere = (fr == nil || fr == window ||
                               ([fr isKindOfClass:[NSView class]] && [(NSView *)fr isDescendantOf:self.hostView]));
  if (!focusOnPageOrNowhere) return;
  NSView *rwhv = SXFindFocusableWebView(self.hostView, self.hostView.devToolsContainer);
  if (rwhv && fr != rwhv) [window makeFirstResponder:rwhv];
  if (_browser && _browser->GetHost()) _browser->GetHost()->SetFocus(true);
}

- (void)handleMainFrameLoadStart {
  [self pushTopContentInsetToMainFrame];
  [self restoreWebContentFocusAfterCommit];
  // The new view can be attached a turn later; check again once it is in place.
  __weak SXBrowserTab *weakFocusSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [weakFocusSelf restoreWebContentFocusAfterCommit];
  });
  [self installFreezeFrameForCommitIfReady];
  _mainFrameLoading = YES;
  [self.runtime notifyNavigationBurst];
  [self.colorSampler notifyNavigationStarted];
  self.domFixedHeaderColor = nil;
  if (self.fixedHeaderColor != nil) {
    _pendingOriginThemeReset = YES;
  }
  if (_scrollSnapshotTimer) {
    dispatch_source_cancel(_scrollSnapshotTimer);
    _scrollSnapshotTimer = nil;
  }
  self.estimatedProgress = 0.0;
  self.loading = YES;
  if ([self.delegate respondsToSelector:@selector(browserTab:didUpdateProgress:)]) {
    [self.delegate browserTab:self didUpdateProgress:0.0];
  }
  if ([self.delegate respondsToSelector:@selector(browserTab:didChangeLoadingState:canGoBack:canGoForward:)]) {
    [self.delegate browserTab:self
        didChangeLoadingState:YES
                    canGoBack:self.canGoBack
                 canGoForward:self.canGoForward];
  }
}

- (void)handleKeyboardNavigateBack {
  if ([self.delegate respondsToSelector:@selector(browserTabDidRequestNavigateBack:)]) {
    [self.delegate browserTabDidRequestNavigateBack:self];
  } else {
    [self goBack];
  }
}

- (void)handleKeyboardNavigateForward {
  if ([self.delegate respondsToSelector:@selector(browserTabDidRequestNavigateForward:)]) {
    [self.delegate browserTabDidRequestNavigateForward:self];
  } else {
    [self goForward];
  }
}

- (void)handleSpaceScrollDirection:(int)direction isRepeat:(BOOL)isRepeat {
  [[NSNotificationCenter defaultCenter]
      postNotificationName:@"SXBrowserTabRequestSpaceScrollNotification"
                    object:self
                  userInfo:@{
                    @"tabIdentifier" : self.tabIdentifier ?: @"",
                    @"direction" : @(direction),
                    @"isRepeat" : @(isRepeat)
                  }];
}

- (NSUInteger)currentFaviconGeneration {
  return self.faviconGeneration;
}

- (void)handleFaviconLoaded:(nullable NSImage *)favicon {
  [self handleFaviconLoaded:favicon forGeneration:self.faviconGeneration];
}

- (void)handleFaviconLoaded:(nullable NSImage *)favicon forGeneration:(NSUInteger)generation {
  if (generation != self.faviconGeneration) {
    return;
  }
  self.favicon = favicon;
  if ([self.delegate respondsToSelector:@selector(browserTab:didUpdateFavicon:)]) {
    [self.delegate browserTab:self didUpdateFavicon:favicon];
  }
}

- (void)handleMainFrameLoadEnd:(int)httpStatusCode {
  _mainFrameLoading = NO;
  [self releaseFreezeFrameAfterLoadIfStillHeld];
  [self flushPendingOriginThemeResetIfNeeded];
  [self.colorSampler notifyMainFrameLoadEnded];
  __weak SXBrowserTab *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    SXBrowserTab *strongSelf = weakSelf;
    if (strongSelf) {
      [strongSelf capturePeriodicPreviewIfEligibleForce:YES];
    }
  });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.85 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    SXBrowserTab *strongSelf = weakSelf;
    if (strongSelf) {
      [strongSelf capturePeriodicPreviewIfEligibleForce:YES];
    }
  });
}

- (void)handleMainFrameLoadError:(NSInteger)errorCode
                       errorText:(NSString *)errorText
                       failedURL:(NSURL *)failedURL {
  _mainFrameLoading = NO;
  [self discardFreezeFrame];
  [self flushPendingOriginThemeResetIfNeeded];
  self.loading = NO;
  self.estimatedProgress = 1.0;
  if ([self.delegate respondsToSelector:@selector(browserTab:didFailLoadURL:errorCode:errorText:)]) {
    [self.delegate browserTab:self
               didFailLoadURL:failedURL
                    errorCode:errorCode
                    errorText:errorText];
  }
}

- (void)handleTelemetryScrollY:(CGFloat)scrollY
                 contentHeight:(CGFloat)contentHeight
                     pageScale:(CGFloat)pageScale
                    isPinching:(BOOL)isPinching
                viewportHeight:(CGFloat)viewportHeight
              canInnerScrollUp:(BOOL)canInnerScrollUp
            canInnerScrollDown:(BOOL)canInnerScrollDown
                 canScrollLeft:(BOOL)canScrollLeft
                canScrollRight:(BOOL)canScrollRight
         pageConsumesPinchZoom:(BOOL)pageConsumesPinchZoom {
  CGFloat normalizedY = scrollY < 0.01 ? 0.0 : scrollY;
  CGFloat normalizedScale = (pageScale <= 1.001) ? 1.0 : pageScale;
  if (_freezeOverlay && _freezeCommittedGeneration != _freezeGeneration &&
      _freezeIncomingGeneration != _freezeGeneration && fabs(normalizedY - self.scrollY) > 1.0) {
    // The user is still scrolling the old page while the next one loads: show it live again.
    _freezeImage = nil;
    [self removeFreezeFrame];
  }
  BOOL topBoundaryChanged = (self.scrollY <= 0.5) != (normalizedY <= 0.5);
  BOOL innerChanged = (self.canInnerScrollUp != canInnerScrollUp) ||
                      (self.canInnerScrollDown != canInnerScrollDown) ||
                      (self.canScrollLeft != canScrollLeft) ||
                      (self.canScrollRight != canScrollRight) ||
                      fabs(viewportHeight - self.viewportHeight) > 0.5;
  BOOL scrollChanged = topBoundaryChanged ||
                       innerChanged ||
                       fabs(normalizedY - self.scrollY) > 0.25 ||
                       fabs(contentHeight - self.contentHeight) > 0.5;
  BOOL scaleBoundaryChanged = (_pageScale > 1.001) != (normalizedScale > 1.001);
  BOOL scaleChanged = scaleBoundaryChanged ||
                      fabs(normalizedScale - _pageScale) > 0.0005 ||
                      isPinching;

  self.scrollY = normalizedY;
  self.contentHeight = contentHeight;
  if (viewportHeight > 1.0) {
    self.viewportHeight = viewportHeight;
  }
  self.canInnerScrollUp = canInnerScrollUp;
  self.canInnerScrollDown = canInnerScrollDown;
  self.canScrollLeft = canScrollLeft;
  self.canScrollRight = canScrollRight;
  self.pageConsumesPinchZoom = pageConsumesPinchZoom;
  _pageScale = normalizedScale;

  [self.colorSampler notifyPinchActive:isPinching];
  if (scrollChanged) {
    [self.colorSampler notifyScrollOffsetChanged];
  }

  if (scrollChanged &&
      [self.delegate respondsToSelector:@selector(browserTab:didUpdateScrollY:contentHeight:)]) {
    [self.delegate browserTab:self
             didUpdateScrollY:normalizedY
                contentHeight:contentHeight];
  }
  if (scrollChanged && !_mainFrameLoading && self.currentNavigationEntryID > 0 &&
      fabs(normalizedY - self.lastSnapshotScrollY) > 1.0) {
    // Any scroll stop refreshes the exact copy (thumbnails, back/forward and tab-switch cover must match the screen).
    [self scheduleSettledScrollSnapshotCapture];
  }
  if (scaleChanged &&
      [self.delegate respondsToSelector:@selector(browserTab:didUpdatePageScale:isPinching:)]) {
    [self.delegate browserTab:self
           didUpdatePageScale:normalizedScale
                   isPinching:isPinching];
  }
}

- (void)scheduleSettledScrollSnapshotCapture {
  if (_isClosed || _mainFrameLoading) return;
  if (_scrollSnapshotTimer) {
    dispatch_source_cancel(_scrollSnapshotTimer);
    _scrollSnapshotTimer = nil;
  }
  dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                            DISPATCH_TIME_FOREVER, 25 * NSEC_PER_MSEC);
  __weak SXBrowserTab *weakSelf = self;
  dispatch_source_set_event_handler(timer, ^{
    SXBrowserTab *strongSelf = weakSelf;
    if (!strongSelf) return;
    if (strongSelf->_scrollSnapshotTimer) {
      dispatch_source_cancel(strongSelf->_scrollSnapshotTimer);
      strongSelf->_scrollSnapshotTimer = nil;
    }
    if (!strongSelf->_isClosed && !strongSelf->_mainFrameLoading) {
      [strongSelf capturePeriodicPreviewIfEligibleForce:YES];
    }
  });
  _scrollSnapshotTimer = timer;
  dispatch_resume(timer);
}

- (void)handleNavigationEntriesCurrentID:(NSInteger)currentID
                              previousID:(NSInteger)previousID
                                  nextID:(NSInteger)nextID
                           validEntryIDs:(NSArray<NSNumber *> *)validIDs {
  if (_isClosed) return;
  BOOL changed = (self.currentNavigationEntryID != currentID) ||
                 (self.previousNavigationEntryID != previousID) ||
                 (self.nextNavigationEntryID != nextID);
  self.currentNavigationEntryID = currentID;
  self.previousNavigationEntryID = previousID;
  self.nextNavigationEntryID = nextID;
  self.validNavigationEntryIDs = validIDs ?: @[];
  if (changed && [self.delegate respondsToSelector:@selector(browserTab:didUpdateNavigationEntryIDs:previousID:nextID:validEntryIDs:)]) {
    [self.delegate browserTab:self
  didUpdateNavigationEntryIDs:currentID
                   previousID:previousID
                       nextID:nextID
                validEntryIDs:self.validNavigationEntryIDs];
  }
}

- (void)handleNavigationVisuallyReadyFromBFCache:(BOOL)fromBFCache {
  if (_isClosed) return;
  [self flushPendingOriginThemeResetIfNeeded];
  if ([self.delegate respondsToSelector:@selector(browserTab:didBecomeVisuallyReadyForNavigation:)]) {
    [self.delegate browserTab:self didBecomeVisuallyReadyForNavigation:fromBFCache];
  }
  // CEF's OnLoadStart can trail the commit by ~100 ms, so the new document's first paint may be reported before
  // it. A ready signal after the main-frame response therefore ends the navigation's freeze; one before the
  // response can only come from the old document (e.g. it was still loading) and is ignored.
  BOOL pending = (_freezeCommittedGeneration != _freezeGeneration);
  SXFreezeLog(@"ready gen=%lu pending=%d incoming=%d overlay=%d bfcache=%d", (unsigned long)_freezeGeneration, pending,
              _freezeIncomingGeneration == _freezeGeneration, _freezeOverlay != nil, fromBFCache);
  if (pending && _freezeIncomingGeneration != _freezeGeneration) return;
  if (pending) {
    _freezeCommittedGeneration = _freezeGeneration;
    _freezeImage = nil;
  }
  if (fromBFCache && _freezeOverlay && _client && [self freezeFrameEligibleForCapture]) {
    // On a BFCache restore (or tab re-show), Blink's rAF fires BEFORE Viz finishes re-rasterizing
    // the evicted tiles and submitting the new IOSurface/CAContext to WindowServer (~70-100ms).
    // Queueing a priority CopyFromSurface on the restored RenderWidgetHostView acts as an exact
    // Viz compositor frame-presentation barrier AND refreshes _standbyImage in the same round-trip.
    NSUInteger readyGen = _freezeGeneration;
    CGFloat scale = self.hostView.window.backingScaleFactor;
    if (scale < 1.0) scale = 2.0;
    CGFloat capturedScrollY = self.scrollY;
    NSInteger capturedEntryID = self.currentNavigationEntryID;
    CFTimeInterval capturedHiddenGen = _tabHiddenAt;
    __weak SXBrowserTab *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      SXBrowserTab *strongSelf = weakSelf;
      if (strongSelf && strongSelf->_freezeGeneration == readyGen && strongSelf->_freezeOverlay) {
        SXFreezeLog(@"bfcache-barrier-timeout gen=%lu", (unsigned long)readyGen);
        [strongSelf removeFreezeFrame];
      }
    });
    _client->CaptureFreezeFramePNG([weakSelf, readyGen, scale, capturedScrollY, capturedEntryID, capturedHiddenGen](const std::string& pngBytes) {
      NSData *data = pngBytes.empty() ? nil : [NSData dataWithBytes:pngBytes.data() length:pngBytes.size()];
      dispatch_async(dispatch_get_main_queue(), ^{
        SXBrowserTab *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_isClosed) return;
        if (strongSelf->_freezeGeneration == readyGen && strongSelf->_freezeOverlay) {
          SXFreezeLog(@"bfcache-barrier-done gen=%lu bytes=%zu", (unsigned long)readyGen, pngBytes.size());
          // Wait one CA commit turn (16ms) after Viz fulfills CopyFromSurface so WindowServer
          // has latched the restored CALayerHost IOSurface before dropping the cover.
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            SXBrowserTab *s2 = weakSelf;
            if (s2 && s2->_freezeGeneration == readyGen && s2->_freezeOverlay) {
              [s2 removeFreezeFrame];
            }
          });
        }
      });
      if (!data) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          [weakSelf capturePeriodicPreviewIfEligibleForce:YES];
        });
        return;
      }
      dispatch_async(SXPreviewSnapshotDecodeQueue(), ^{
        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (!src) return;
        NSDictionary *opts = @{ (__bridge NSString *)kCGImageSourceShouldCacheImmediately : @YES };
        CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
        CFRelease(src);
        if (!img) return;
        id surface = SXCopyImageToIOSurface(img);
        CGImageRelease(img);
        if (!surface) return;
        dispatch_async(dispatch_get_main_queue(), ^{
          SXBrowserTab *strongSelf = weakSelf;
          if (!strongSelf || strongSelf->_isClosed || !strongSelf->_tabActiveState) return;
          if (strongSelf->_tabHiddenAt != capturedHiddenGen) return;
          if (strongSelf->_freezeGeneration == readyGen && capturedEntryID == strongSelf.currentNavigationEntryID) {
            strongSelf->_standbyImage = surface;
            strongSelf->_standbyScale = scale;
            strongSelf->_standbyCapturedAt = CACurrentMediaTime();
            strongSelf->_standbyScrollY = capturedScrollY;
          }
        });
      });
    }, /*priority=*/true);
    return;
  }
  [self removeFreezeFrame];
  // Refresh the standing copy for the new page promptly (back/forward-cache restores don't fire load-end captures,
  // and script-triggered history.back() needs a fresh standby copy quickly).
  __weak SXBrowserTab *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [weakSelf capturePeriodicPreviewIfEligibleForce:YES];
  });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [weakSelf capturePeriodicPreviewIfEligibleForce:YES];
  });
}

- (void)handleScriptTraverseNavigation {
  if (_isClosed || _freezeOverlay) return;
  // Script-triggered history.back() / history.forward() / history.go() starts in the renderer
  // before Chromium empties the old view's remote CALayerHost or swaps RenderWidgetHostViewCocoa.
  // When the standing copy already matches the screen, pin it directly WITHOUT queuing a
  // redundant CaptureFreezeFramePNG of the departing page (which would stall the Viz barrier).
  SXFreezeLog(@"traverse gen=%lu standby=%d", (unsigned long)_freezeGeneration, _standbyImage != nil);
  if ([self standbyImageMatchesScreen]) {
    _freezeGeneration += 1;
    _freezeRequestedAt = CACurrentMediaTime();
    _freezeIncomingGeneration = _freezeGeneration;
    _freezeImage = _standbyImage;
    _freezeImageScale = _standbyScale;
    _freezeCapturedAt = CACurrentMediaTime();
    [self presentFreezeFrameIfReady];
    return;
  }
  [self handleMainFrameNavigationWillStart];
  _freezeIncomingGeneration = _freezeGeneration;
  [self presentFreezeFrameIfReady];
}

#pragma mark Navigation freeze frame
// At every cross-document commit Chromium swaps in a new RenderWidgetHostView, and in CEF's windowed mode on macOS
// that view shows nothing (the bare host background, often white) until the new document's first frame arrives;
// Chromium's own Paint Holding can't carry the old picture across views here. Safari keeps the old page on screen
// until the new one has painted. Same here: copy the page as it is on screen when a navigation starts, pin that
// copy over the web view at commit, and drop it the moment the new document's first contentful paint is on screen
// (sx.nav_ready). The swap is a single frame with no fade, as in Safari. The old frame can't be held at the
// compositor level instead: the hidden view's remote CALayer context is cleared at commit (checked live).

static const CFTimeInterval kSXFreezeFrameMaxHold = 3.0;        // never hold a stale page longer than this
static const CFTimeInterval kSXFreezeFrameMaxImageAge = 4.0;    // capture older than this is not used at commit

- (BOOL)freezeFrameEligibleForCapture {
  if (_isClosed || !_client || !_browser) return NO;
  NSView *host = self.hostView;
  if (!host.window || host.isHiddenOrHasHiddenAncestor || host.alphaValue < 0.99) return NO;
  if (host.bounds.size.width < 16 || host.bounds.size.height < 16) return NO;
  // The committed document (currentURL already points at the destination during a browser-initiated load).
  CefRefPtr<CefFrame> main = _browser->GetMainFrame();
  std::string url = main ? main->GetURL().ToString() : std::string();
  return url.rfind("https:", 0) == 0 || url.rfind("http:", 0) == 0 || url.rfind("file:", 0) == 0;
}

- (void)handleMainFrameNavigationWillStart {
  if (_isClosed) return;
  CFTimeInterval now = CACurrentMediaTime();
  // Browser-side entry points (loadURL/goBack/reload) and OnBeforeBrowse both report the same navigation.
  if (_freezeCommittedGeneration != _freezeGeneration && (now - _freezeRequestedAt) < 0.25) return;
  _freezeGeneration += 1;
  _freezeRequestedAt = now;
  SXFreezeLog(@"start gen=%lu overlay=%d eligible=%d", (unsigned long)_freezeGeneration, _freezeOverlay != nil,
              [self freezeFrameEligibleForCapture]);
  _freezeImage = nil;
  if (_freezeOverlay) {
    // Navigating again while the previous navigation is still frozen: keep showing the last real page.
    [self armFreezeFrameTimeout];
    return;
  }
  if ([self standbyImageMatchesScreen]) {
    // Until the fresh copy arrives, the standing one covers a very fast commit.
    // Refresh _freezeCapturedAt so presentFreezeFrameIfReady never rejects a valid standby copy on age mismatch.
    _freezeImage = _standbyImage;
    _freezeImageScale = _standbyScale;
    _freezeCapturedAt = CACurrentMediaTime();
  }
  {
    // A navigation that never gets going (Chromium skipping a history entry, a cancelled load) must not leave
    // the state pending: that would block standby refreshes and ignore the next ready signal.
    NSUInteger startGen = _freezeGeneration;
    __weak SXBrowserTab *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      SXBrowserTab *strongSelf = weakSelf;
      if (!strongSelf || strongSelf->_freezeGeneration != startGen) return;
      if (strongSelf->_freezeCommittedGeneration == startGen || strongSelf->_freezeIncomingGeneration == startGen) return;
      if (strongSelf.loading || (strongSelf->_browser && strongSelf->_browser->IsLoading())) return;
      SXFreezeLog(@"abandon gen=%lu", (unsigned long)startGen);
      strongSelf->_freezeCommittedGeneration = startGen;
      strongSelf->_freezeImage = nil;
      [strongSelf removeFreezeFrame];
    });
  }
  if (![self freezeFrameEligibleForCapture]) return;
  NSUInteger gen = _freezeGeneration;
  CGFloat scale = self.hostView.window.backingScaleFactor;
  if (scale < 1.0) scale = 2.0;
  __weak SXBrowserTab *weakSelf = self;
  _client->CaptureFreezeFramePNG([weakSelf, gen, scale](const std::string& pngBytes) {
    if (pngBytes.empty()) return;
    NSData *data = [NSData dataWithBytes:pngBytes.data() length:pngBytes.size()];
    if (SXFreezeDebugFile()) {
      [data writeToFile:[NSString stringWithFormat:@"/tmp/safarium-freeze-%lu.png", (unsigned long)gen] atomically:NO];
    }
    dispatch_async(SXPreviewSnapshotDecodeQueue(), ^{
      CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
      if (!src) return;
      NSDictionary *opts = @{ (__bridge NSString *)kCGImageSourceShouldCacheImmediately : @YES };
      CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
      CFRelease(src);
      if (!img) return;
      id image = SXCopyImageToIOSurface(img);
      CGImageRelease(img);
      if (!image) return;
      dispatch_async(dispatch_get_main_queue(), ^{
        SXBrowserTab *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_isClosed) return;
        // Too late: the commit already happened (installing now would show blank -> old -> new).
        if (gen != strongSelf->_freezeGeneration || strongSelf->_freezeCommittedGeneration == gen) return;
        strongSelf->_freezeImage = image;
        strongSelf->_freezeImageScale = scale;
        SXFreezeLog(@"captured gen=%lu", (unsigned long)gen);
        strongSelf->_freezeCapturedAt = CACurrentMediaTime();
        // Pin it now: it is identical to the live page, and some commits give no earlier warning than a blank
        // frame (service-worker responses never reach OnResourceResponse, and Chromium empties the old view a
        // task before it toggles visibility). Scrolling the old page before the new one arrives unpins it.
        [strongSelf presentFreezeFrameIfReady];
      });
    });
  });
}

- (void)installFreezeFrameForCommitIfReady {
  // OnLoadStart (commit). Usually the frame is already up (response / view swap); otherwise this is the last chance.
  SXFreezeLog(@"loadstart gen=%lu committed=%lu", (unsigned long)_freezeGeneration, (unsigned long)_freezeCommittedGeneration);
  if (_freezeCommittedGeneration == _freezeGeneration) return;  // already finished (ready arrived first)
  [self presentFreezeFrameIfReady];
  _freezeCommittedGeneration = _freezeGeneration;
  _freezeImage = nil;
  _standbyImage = nil;  // belongs to the previous document
  if (_freezeOverlay) [self armFreezeFrameTimeout];
}

- (void)handleMainFrameResponseReceived {
  SXFreezeLog(@"response gen=%lu image=%d", (unsigned long)_freezeGeneration, _freezeImage != nil);
  if (_isClosed || _freezeCommittedGeneration == _freezeGeneration) return;
  _freezeIncomingGeneration = _freezeGeneration;
  [self presentFreezeFrameIfReady];
}

- (void)presentFreezeFrameIfReady {
  if (_freezeOverlay) return;
  id image = _freezeImage;
  if (!image || (CACurrentMediaTime() - _freezeCapturedAt) > kSXFreezeFrameMaxImageAge) return;
  NSView *host = self.hostView;
  if (!host.window || host.isHiddenOrHasHiddenAncestor) return;
  NSRect webRect = [self.hostView webContentRectForBounds:host.bounds];

  CGFloat scale = _freezeImageScale;
  // The copy must line up pixel for pixel with the live page; after a resize it would not.
  if (fabs((CGFloat)SXFreezeImageWidth(image) - webRect.size.width * scale) > 2.0 ||
      fabs((CGFloat)SXFreezeImageHeight(image) - webRect.size.height * scale) > 2.0) {
    return;
  }
  SXFreezeFrameView *overlay = [[SXFreezeFrameView alloc] initWithFrame:webRect];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  overlay.layer.contentsScale = scale;
  overlay.layer.contents = image;
  [host addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
  [CATransaction commit];
  [CATransaction flush];
  _freezeOverlay = overlay;
  _freezeImage = nil;
  SXFreezeLog(@"present gen=%lu", (unsigned long)_freezeGeneration);
  [self armFreezeFrameTimeout];
}

- (void)handleRenderWidgetVisibilityChanged {
  // Only meaningful while a navigation is between start and commit. A view swap means the new document (or a
  // back/forward-cache page, which has no network response) is on its way.
  SXFreezeLog(@"swap gen=%lu image=%d standby=%d", (unsigned long)_freezeGeneration, _freezeImage != nil,
              _standbyImage != nil);
  if (_isClosed || _freezeOverlay) return;
  if (_freezeCommittedGeneration == _freezeGeneration) {
    // A swap with no navigation announced: a back/forward-cache restore started by the page (history.back()),
    // which reaches us only after the swap. Cover it with the standing copy if that still matches the screen.
    if (![self standbyImageMatchesScreen]) return;
    _freezeGeneration += 1;
    _freezeRequestedAt = CACurrentMediaTime();
  }
  _freezeIncomingGeneration = _freezeGeneration;
  if (!_freezeImage && [self standbyImageMatchesScreen]) {
    _freezeImage = _standbyImage;
    _freezeImageScale = _standbyScale;
    _freezeCapturedAt = CACurrentMediaTime();
  }
  [self presentFreezeFrameIfReady];
}

// Chromium drops a background tab's rendered surface, so a tab coming back paints nothing for ~150 ms. Cover it
// with the copy taken when it was last on screen until the page reports a fresh frame (sx.nav_ready after
// `visibilitychange`), like Safari's instant tab switch.
- (void)presentStandbyForTabShow {
  if (_isClosed || _freezeOverlay || !_standbyImage) return;
  _freezeGeneration += 1;
  _freezeCommittedGeneration = _freezeGeneration;
  _freezeIncomingGeneration = _freezeGeneration;
  _freezeImage = _standbyImage;
  _freezeImageScale = _standbyScale;
  _freezeCapturedAt = CACurrentMediaTime();
  [self presentFreezeFrameIfReady];
  _freezeImage = nil;
  if (!_freezeOverlay) return;
  SXFreezeLog(@"tabshow present gen=%lu", (unsigned long)_freezeGeneration);
  [_freezeTimer invalidate];
  __weak SXBrowserTab *weakSelf = self;
  _freezeTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 repeats:NO block:^(NSTimer *t) {
    (void)t;
    [weakSelf removeFreezeFrame];
  }];
}

- (nullable id)currentFrameSurface {
  if (_isClosed || !_standbyImage) return nil;
  if (!_tabActiveState || self.hostView.isHiddenOrHasHiddenAncestor) return _standbyImage;  // as it last appeared
  if (_freezeOverlay || _freezeCommittedGeneration != _freezeGeneration) return nil;      // mid-navigation
  // Same document and scroll position as now (age doesn't matter here: an older exact copy still beats the preview).
  if (self.pageScale > 1.01 || fabs(_standbyScrollY - self.scrollY) > 1.0) return nil;
  return _standbyImage;
}

static NSView * _Nullable SXFindVisibleRenderWidgetView(NSView *root) {
  for (NSView *sub in root.subviews) {
    if (sub.isHidden) continue;
    if ([NSStringFromClass([sub class]) containsString:@"RenderWidgetHostViewCocoa"]) return sub;
    NSView *nested = SXFindVisibleRenderWidgetView(sub);
    if (nested) return nested;
  }
  return nil;
}

static CALayer * _Nullable SXFindRemoteLayerHost(CALayer *root, int depth) {
  if (!root || depth > 6) return nil;
  if ([NSStringFromClass([root class]) isEqualToString:@"CALayerHost"]) return root;
  for (CALayer *sub in root.sublayers) {
    CALayer *found = SXFindRemoteLayerHost(sub, depth + 1);
    if (found) return found;
  }
  return nil;
}

- (nullable CALayer *)makeLiveContentMirrorLayer {
  if (_isClosed || !_tabActiveState || _freezeOverlay || self.hostView.isHiddenOrHasHiddenAncestor) return nil;
  NSView *rwhv = SXFindVisibleRenderWidgetView(self.hostView);
  CALayer *source = SXFindRemoteLayerHost(rwhv.layer, 0);
  id contextId = [source valueForKey:@"contextId"];
  Class hostClass = NSClassFromString(@"CALayerHost");
  if (!rwhv || !source || !contextId || !hostClass) return nil;
  // A second host of the same remote context: the window server draws Chromium's live frames in both places.
  CALayer *mirror = [[hostClass alloc] init];
  [mirror setValue:contextId forKey:@"contextId"];
  mirror.actions = @{ @"position": [NSNull null], @"bounds": [NSNull null], @"transform": [NSNull null] };
  CALayer *container = [CALayer layer];
  container.geometryFlipped = YES;  // remote content is laid out top-down from the host's origin
  container.masksToBounds = YES;
  container.bounds = CGRectMake(0, 0, rwhv.bounds.size.width, rwhv.bounds.size.height);
  container.actions = @{ @"position": [NSNull null], @"bounds": [NSNull null], @"transform": [NSNull null],
                         @"sublayers": [NSNull null] };
  [container addSublayer:mirror];
  return container;
}

- (void)refreshCurrentFrameWithCompletion:(void (^)(id _Nullable surface, NSSize size))completion {
  if (!completion) return;
  if (![self freezeFrameEligibleForCapture] || !_tabActiveState) {
    completion(nil, NSZeroSize);
    return;
  }
  CGFloat scale = self.hostView.window.backingScaleFactor;
  if (scale < 1.0) scale = 2.0;
  CGFloat capturedScrollY = self.scrollY;
  CFTimeInterval hiddenGen = _tabHiddenAt;
  NSUInteger navGen = _freezeGeneration;
  __weak SXBrowserTab *weakSelf = self;
  _client->CaptureFreezeFramePNG([weakSelf, scale, capturedScrollY, hiddenGen, navGen, completion](const std::string& pngBytes) {
    NSData *data = pngBytes.empty() ? nil : [NSData dataWithBytes:pngBytes.data() length:pngBytes.size()];
    dispatch_async(SXPreviewSnapshotDecodeQueue(), ^{
      id surface = nil;
      if (data) {
        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (src) {
          NSDictionary *opts = @{ (__bridge NSString *)kCGImageSourceShouldCacheImmediately : @YES };
          CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
          CFRelease(src);
          if (img) { surface = SXCopyImageToIOSurface(img); CGImageRelease(img); }
        }
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        SXBrowserTab *strongSelf = weakSelf;
        BOOL valid = surface && strongSelf && !strongSelf->_isClosed && strongSelf->_tabActiveState &&
                     strongSelf->_tabHiddenAt == hiddenGen && strongSelf->_freezeGeneration == navGen &&
                     !strongSelf.hostView.isHiddenOrHasHiddenAncestor;
        if (!valid) { completion(nil, NSZeroSize); return; }
        strongSelf->_standbyImage = surface;
        strongSelf->_standbyScale = scale;
        strongSelf->_standbyCapturedAt = CACurrentMediaTime();
        strongSelf->_standbyScrollY = capturedScrollY;
        completion(surface, [strongSelf currentFrameSize]);
      });
    });
  });
}

- (NSSize)currentFrameSize {
  id surf = _standbyImage;
  CGFloat scale = _standbyScale > 0.5 ? _standbyScale : 2.0;
  return surf ? NSMakeSize(SXFreezeImageWidth(surf) / scale, SXFreezeImageHeight(surf) / scale) : NSZeroSize;
}

- (BOOL)standbyImageMatchesScreen {
  if (!_standbyImage || ![self freezeFrameEligibleForCapture]) return NO;
  if ((CACurrentMediaTime() - _standbyCapturedAt) > 30.0) return NO;
  // The copy is dropped at every commit, so it always shows the current document; the history entry ID can't be
  // compared here because Chromium has already switched it to the destination by the time the views swap.
  if (fabs(_standbyScrollY - self.scrollY) > 1.0) return NO;
  return self.pageScale <= 1.01;
}

- (void)armFreezeFrameTimeout {
  [_freezeTimer invalidate];
  __weak SXBrowserTab *weakSelf = self;
  _freezeTimer = [NSTimer scheduledTimerWithTimeInterval:kSXFreezeFrameMaxHold repeats:NO block:^(NSTimer *t) {
    (void)t;
    [weakSelf removeFreezeFrame];
  }];
  _freezeTimer.tolerance = 0.05;
}

- (void)releaseFreezeFrameAfterLoadIfStillHeld {
  if (!_freezeOverlay) return;
  // The document finished loading without reporting a contentful paint (e.g. an empty page): give it a few more
  // frames, then show whatever it has.
  SXFreezeFrameView *overlay = _freezeOverlay;
  __weak SXBrowserTab *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    SXBrowserTab *strongSelf = weakSelf;
    if (strongSelf && strongSelf->_freezeOverlay == overlay) [strongSelf removeFreezeFrame];
  });
}

- (void)deliverChromeUpdate:(dispatch_block_t)update {
  // While the old page is frozen on screen the toolbar must keep matching it; colour updates from the incoming
  // page are applied in the same transaction that reveals it.
  if (_freezeOverlay) {
    if (!_heldChromeUpdates) _heldChromeUpdates = [NSMutableArray array];
    [_heldChromeUpdates addObject:[update copy]];
    return;
  }
  update();
}

- (void)removeFreezeFrame {
  [_freezeTimer invalidate];
  _freezeTimer = nil;
  if (!_freezeOverlay) return;
  SXFreezeLog(@"remove gen=%lu", (unsigned long)_freezeGeneration);
  SXFreezeFrameView *overlay = _freezeOverlay;
  _freezeOverlay = nil;
  NSArray<dispatch_block_t> *held = _heldChromeUpdates;
  _heldChromeUpdates = nil;
  [CATransaction begin];
  for (dispatch_block_t update in held) update();
  [CATransaction setDisableActions:YES];
  [overlay removeFromSuperview];
  [CATransaction commit];
  _freezeOverlay = nil;
}

- (void)discardFreezeFrame {
  _standbyImage = nil;
  _freezeGeneration += 1;
  _freezeCommittedGeneration = _freezeGeneration;
  _freezeImage = nil;
  [self removeFreezeFrame];
}

- (void)handleOverscrollY:(CGFloat)overscrollY armed:(BOOL)armed {
  // No-op: native AppKit ElasticScrollEngine owns all elastic overscroll state.
}

- (void)handlePullToRefreshTriggered {
  // No-op: native AppKit ElasticScrollEngine owns pull-to-refresh state.
}

- (BOOL)pixelSampleMatchesFixedHeaderColor:(NSColor *)domColor {
  if (!domColor) return NO;
  if (!self.colorSampler.hasSampleForCurrentNavigation || !self.colorSampler.lastSampledColor) {
    return YES;
  }
  NSColor *domSRGB = [domColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: domColor;
  // Translucent backdrop-filter bars show varying page imagery underneath; only pixel-veto opaque bars.
  if (domSRGB.alphaComponent < 0.95) {
    return YES;
  }
  // Require the actual rendered top 3pt strip to be horizontally uniform across the full viewport width.
  if (self.colorSampler.lastSampleUniformity < 0.68 || self.colorSampler.lastSampleEdgeDelta > 0.14) {
    return NO;
  }
  NSColor *pixSRGB = [self.colorSampler.lastSampledColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
  if (!pixSRGB) return YES;
  double dr = fabs(domSRGB.redComponent - pixSRGB.redComponent);
  double dg = fabs(domSRGB.greenComponent - pixSRGB.greenComponent);
  double db = fabs(domSRGB.blueComponent - pixSRGB.blueComponent);
  return fmax(dr, fmax(dg, db)) <= 0.14;
}

- (void)reconcileFixedHeaderColorWithPixelSample {
  if (_isClosed) return;
  NSColor *effective = nil;
  if (self.domFixedHeaderColor && [self pixelSampleMatchesFixedHeaderColor:self.domFixedHeaderColor]) {
    effective = self.domFixedHeaderColor;
  }
  BOOL changed = NO;
  if (effective == nil && self.fixedHeaderColor == nil) {
    changed = NO;
  } else if (effective == nil || self.fixedHeaderColor == nil) {
    changed = YES;
  } else {
    NSColor *a = [effective colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: effective;
    NSColor *b = [self.fixedHeaderColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: self.fixedHeaderColor;
    changed = fabs(a.redComponent - b.redComponent) > 0.004 ||
              fabs(a.greenComponent - b.greenComponent) > 0.004 ||
              fabs(a.blueComponent - b.blueComponent) > 0.004 ||
              fabs(a.alphaComponent - b.alphaComponent) > 0.004;
  }
  if (!changed) return;
  self.fixedHeaderColor = effective;
  __weak SXBrowserTab *weakSelf = self;
  [self deliverChromeUpdate:^{
    SXBrowserTab *t = weakSelf;
    if (t && [t.delegate respondsToSelector:@selector(browserTab:didUpdateFixedHeaderColor:)]) {
      [t.delegate browserTab:t didUpdateFixedHeaderColor:effective];
    }
  }];
}

- (void)handleFixedHeaderColor:(nullable NSColor *)color {
  if (_isClosed) return;
  _pendingOriginThemeReset = NO;
  self.domFixedHeaderColor = color;
  [self reconcileFixedHeaderColorWithPixelSample];
}

- (void)handlePageBackgroundColor:(NSColor *)color {
  if (_isClosed || !color) return;
  NSColor *srgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: color;
  self.pageBackgroundColor = srgb;
  [self syncHostCanvasBackgroundColor];
  [self flushPendingOriginThemeResetIfNeeded];
  if (self.fixedHeaderColor != nil) return;
  double lum = SXRelativeLuminanceSRGB(srgb.redComponent, srgb.greenComponent, srgb.blueComponent);
  self.lastSampledTopEdgeColor = srgb;
  __weak SXBrowserTab *weakSelf = self;
  [self deliverChromeUpdate:^{
    SXBrowserTab *t = weakSelf;
    if (t && [t.delegate respondsToSelector:@selector(browserTab:didSampleTopEdgeColor:relativeLuminance:)]) {
      [t.delegate browserTab:t didSampleTopEdgeColor:srgb relativeLuminance:lum];
    }
  }];
}

- (void)handleNativeVideoID:(NSString *)videoID
                     srcURL:(NSString *)srcURL
                       rect:(NSRect)rect
                    visible:(BOOL)visible
                   autoplay:(BOOL)autoplay {
  if (_isClosed) return;
  if ([self.delegate respondsToSelector:@selector(browserTab:didUpdateNativeVideoID:srcURL:rect:visible:autoplay:)]) {
    [self.delegate browserTab:self
       didUpdateNativeVideoID:videoID
                       srcURL:srcURL
                         rect:rect
                      visible:visible
                     autoplay:autoplay];
  }
}

- (void)handleAuthEventJSON:(NSString *)jsonString {
  if (_isClosed) return;
  if (jsonString.length > 0 && [jsonString containsString:@"\"apple_signin_intent\""]) {
    _lastAppleSignInIntentTime = CFAbsoluteTimeGetCurrent();
  }
  if ([self.delegate respondsToSelector:@selector(browserTab:didReceiveAuthEventJSON:)]) {
    [self.delegate browserTab:self didReceiveAuthEventJSON:jsonString ?: @""];
  }
}

- (BOOL)hasRecentAppleSignInIntent {
  if (_lastAppleSignInIntentTime <= 0) return NO;
  return (CFAbsoluteTimeGetCurrent() - _lastAppleSignInIntentTime) < 6.0;
}

- (CefRefPtr<CefClient>)prepareAuthPopupClientWithInitialURL:(nullable NSURL *)url {
  [self closeAuthPopup];
  self.activeAuthPopupURL = url;
  CefRefPtr<CefClient> client = new SXAuthPopupClient(self);
  _authPopupClient = client;
  if (url) {
    NSURL *initialURL = url;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!self->_isClosed && [self.delegate respondsToSelector:@selector(browserTab:didOpenAuthPopupWithURL:)]) {
        [self.delegate browserTab:self didOpenAuthPopupWithURL:initialURL];
      }
    });
  }
  return client;
}

- (void)handleAuthPopupBrowserCreated:(CefRefPtr<CefBrowser>)browser {
  if (_isClosed) {
    if (browser && browser->GetHost()) {
      browser->GetHost()->CloseBrowser(true);
    }
    return;
  }
  _authPopupBrowser = browser;
  if (browser && browser->GetHost()) {
    NSView *cefView = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    if (cefView) {
      NSRect b = self.authPopupContainerView.bounds;
      if (b.size.width < 100 || b.size.height < 100) {
        b = NSMakeRect(0, 0, 440, 500);
        self.authPopupContainerView.frame = b;
      }
      cefView.frame = b;
      cefView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    }
    [self presentAuthPopupWindow];
    browser->GetHost()->NotifyScreenInfoChanged();
    browser->GetHost()->SetFocus(true);
  }
}

/// Sign in with Apple (and other window.open sign-in popups routed here) is shown as a real popup window holding
/// the provider's own page. The popup stays a true child of the page (window.opener works, so the result reaches
/// the site); it used to be hidden in a container and driven behind a look-alike Apple sheet.
- (void)presentAuthPopupWindow {
  if (_authPopupWindow) {
    [_authPopupWindow makeKeyAndOrderFront:nil];
    return;
  }
  NSWindow *parent = self.hostView.window;
  NSSize size = NSMakeSize(500, 680);
  NSRect pf = parent ? parent.frame : (NSScreen.mainScreen ?: NSScreen.screens.firstObject).visibleFrame;
  NSRect frame = NSMakeRect(NSMidX(pf) - size.width / 2, NSMidY(pf) - size.height / 2, size.width, size.height);
  NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskResizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
  win.releasedWhenClosed = NO;
  win.title = self.activeAuthPopupURL.host ?: @"Sign In";
  win.minSize = NSMakeSize(360, 420);
  [self.authPopupContainerView removeFromSuperview];
  self.authPopupContainerView.frame = ((NSView *)win.contentView).bounds;
  self.authPopupContainerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [win.contentView addSubview:self.authPopupContainerView];
  for (NSView *sub in self.authPopupContainerView.subviews) {
    sub.frame = self.authPopupContainerView.bounds;
  }
  win.delegate = (id<NSWindowDelegate>)self;
  _authPopupWindow = win;
  [win makeKeyAndOrderFront:nil];
}

/// Closing the sign-in window by hand closes the popup page (the opener sees window.closed).
- (void)windowWillClose:(NSNotification *)note {
  if (note.object != _authPopupWindow) return;
  _authPopupWindow.delegate = nil;
  _authPopupWindow = nil;
  [self.authPopupContainerView removeFromSuperview];
  if (_authPopupBrowser) [self closeAuthPopup];
}

- (void)dismissAuthPopupWindow {
  NSWindow *win = _authPopupWindow;
  if (!win) return;
  _authPopupWindow = nil;
  win.delegate = nil;
  [self.authPopupContainerView removeFromSuperview];
  [win orderOut:nil];
  [win close];
}

- (void)handleAuthPopupURLChanged:(NSURL *)url {
  if (_isClosed || !url) return;
  self.activeAuthPopupURL = url;
  if ([self.delegate respondsToSelector:@selector(browserTab:didUpdateAuthPopupURL:)]) {
    [self.delegate browserTab:self didUpdateAuthPopupURL:url];
  }
}

- (void)handleAuthPopupClosed:(CefRefPtr<CefBrowser>)browser {
  if (_authPopupBrowser && browser && _authPopupBrowser->GetIdentifier() != browser->GetIdentifier()) {
    return;
  }
  _authPopupBrowser = nullptr;
  _authPopupClient = nullptr;
  self.activeAuthPopupURL = nil;
  [self dismissAuthPopupWindow];
  if (!_isClosed && [self.delegate respondsToSelector:@selector(browserTabDidCloseAuthPopup:)]) {
    [self.delegate browserTabDidCloseAuthPopup:self];
  }
}

- (void)handleDownloadStarted:(SXDownloadItem *)item {
  if ([self.delegate respondsToSelector:@selector(browserTab:didStartDownload:)]) {
    [self.delegate browserTab:self didStartDownload:item];
  }
}

- (void)handleDownloadUpdated:(SXDownloadItem *)item {
  if ([self.delegate respondsToSelector:@selector(browserTab:didUpdateDownload:)]) {
    [self.delegate browserTab:self didUpdateDownload:item];
  }
}

- (nullable SXBrowserTab *)handlePopupRequestURL:(NSURL *)url
                                     userGesture:(BOOL)userGesture {
  if ([self.delegate respondsToSelector:@selector(browserTab:requestNewTabWithURL:userGesture:)]) {
    return [self.delegate browserTab:self
                requestNewTabWithURL:url
                         userGesture:userGesture];
  }
  return nil;
}

- (BOOL)handleOpenRequestURL:(NSURL *)url
                 disposition:(SXWindowOpenDisposition)disposition
                 userGesture:(BOOL)userGesture {
  if (_isClosed || !url) return NO;
  if ([self.delegate respondsToSelector:@selector(browserTab:requestOpenURL:disposition:userGesture:)]) {
    return [self.delegate browserTab:self
                      requestOpenURL:url
                         disposition:disposition
                         userGesture:userGesture];
  }
  if ([self.delegate respondsToSelector:@selector(browserTab:requestNewTabWithURL:userGesture:)]) {
    (void)[self.delegate browserTab:self
               requestNewTabWithURL:url
                        userGesture:userGesture];
    return YES;
  }
  return NO;
}

- (BOOL)isPrivateBrowsing {
  return _incognito;
}

- (void)handlePrivacyEvent:(SXPrivacyEvent *)event {
  if (_isClosed || !event) return;
  if ([self.delegate respondsToSelector:@selector(browserTab:didRecordPrivacyEvent:)]) {
    [self.delegate browserTab:self didRecordPrivacyEvent:event];
  }
}

- (void)handleConnectionSecurityState:(SXConnectionSecurityState)state host:(NSString *)host {
  if (_isClosed) return;
  NSString *cleanHost = host ?: @"";
  BOOL changed = (_connectionSecurityState != state) ||
                 (![(_connectionSecurityHost ?: @"") isEqualToString:cleanHost]);
  _connectionSecurityState = state;
  _connectionSecurityHost = [cleanHost copy];
  if (changed && [self.delegate respondsToSelector:@selector(browserTab:didUpdateConnectionSecurity:host:)]) {
    [self.delegate browserTab:self didUpdateConnectionSecurity:state host:cleanHost];
  }
}

- (void)sendPrivacyConfigUpdateDictionary:(CefRefPtr<CefDictionaryValue>)configDict {
  if (_isClosed || !_browser || !configDict) return;
  CefRefPtr<CefBrowser> targetBrowser = _browser;
  CefRefPtr<CefDictionaryValue> dictCopy = configDict->Copy(false);
  CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
      [](CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> cfg) {
        if (!b || !cfg) return;
        std::vector<CefString> frameIds;
        b->GetFrameIdentifiers(frameIds);
        for (const auto& fid : frameIds) {
          CefRefPtr<CefFrame> f = b->GetFrameByIdentifier(fid);
          if (!f || !f->IsValid()) continue;
          CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create("sx_privacy_config_update");
          msg->GetArgumentList()->SetDictionary(0, cfg->Copy(false));
          f->SendProcessMessage(PID_RENDERER, msg);
        }
      },
      targetBrowser, dictCopy)));
}

@end

#pragma mark - SXEngineRuntime

@interface SXEngineRuntime () {
  CefRefPtr<SXBrowserApp> _app;
  CefRefPtr<CefRequestContext> _incognitoRequestContext;
  BOOL _cefLoaded;
  BOOL _contextInitialized;
  BOOL _reentrancyDetected;
  BOOL _isPumping;
  BOOL _immediatePumpPending;
  CFTimeInterval _navigationBurstUntil;
  std::mutex _downloadMutex;
  std::unordered_map<uint32_t, CefRefPtr<CefDownloadItemCallback>> _downloads;
  std::mutex _prefsMutex;
  NSDictionary<NSString *, id> *_latestPreferences;
  std::atomic<int> _liveBrowserCount;
}

@property (nonatomic, readwrite, getter=isInitialized) BOOL initialized;
@property (nonatomic, readwrite, copy) NSString *chromiumVersion;
@property (nonatomic, readwrite, copy) NSString *userAgent;
@property (nonatomic, readwrite, copy) NSString *profileDirectory;
@property (nonatomic, readwrite) NSInteger activeRemoteDebuggingPort;
@property (nonatomic, strong) NSMutableArray<SXBrowserTab *> *mutableTabs;
@property (nonatomic, strong, nullable) NSTimer *pumpTimer;
@property (nonatomic, strong, nullable) id scrollPhaseMonitor;

@end

@implementation SXEngineRuntime

+ (instancetype)sharedRuntime {
  static SXEngineRuntime *shared = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    shared = [[SXEngineRuntime alloc] initPrivate];
  });
  return shared;
}

- (instancetype)initPrivate {
  self = [super init];
  if (self) {
    _mutableTabs = [NSMutableArray array];
    _chromiumVersion = [NSString
        stringWithFormat:@"%d.%d.%d.%d", CHROME_VERSION_MAJOR,
                         CHROME_VERSION_MINOR, CHROME_VERSION_BUILD,
                         CHROME_VERSION_PATCH];
    _userAgent = [NSString
        stringWithFormat:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                         @"AppleWebKit/537.36 (KHTML, like Gecko) "
                         @"Chrome/%d.0.0.0 Safari/537.36",
                         CHROME_VERSION_MAJOR];
    _profileDirectory = @"";
  }
  return self;
}

+ (void)installApplicationProtocolHooks {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    Class appClass = NSApp ? [NSApp class] : [NSApplication class];
    if (!appClass) {
      return;
    }

    // Add CrAppProtocol / CefAppProtocol methods if not already implemented.
    if (!class_getInstanceMethod(appClass, @selector(isHandlingSendEvent))) {
      class_addMethod(appClass, @selector(isHandlingSendEvent),
                      (IMP)SXIsHandlingSendEvent, "B@:");
    }
    if (!class_getInstanceMethod(appClass, @selector(setHandlingSendEvent:))) {
      class_addMethod(appClass, @selector(setHandlingSendEvent:),
                      (IMP)SXSetHandlingSendEvent, "v@:B");
    }
    Protocol *cefProto = @protocol(CefAppProtocol);
    if (cefProto && !class_conformsToProtocol(appClass, cefProto)) {
      class_addProtocol(appClass, cefProto);
    }
    Protocol *crProto = @protocol(CrAppProtocol);
    if (crProto && !class_conformsToProtocol(appClass, crProto)) {
      class_addProtocol(appClass, crProto);
    }

    // Wrap -[NSApplication sendEvent:] to maintain isHandlingSendEvent state.
    Method sendEventMethod = class_getInstanceMethod(appClass, @selector(sendEvent:));
    if (sendEventMethod) {
      gOriginalSendEventIMP = method_getImplementation(sendEventMethod);
      if (gOriginalSendEventIMP != (IMP)SXSwizzledSendEvent) {
        method_setImplementation(sendEventMethod, (IMP)SXSwizzledSendEvent);
      }
    }
  });
}

- (nullable NSString *)resolveFrameworkPathWithConfiguration:(SXEngineConfiguration *)config {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableArray<NSString *> *candidates = [NSMutableArray array];

  if (config.frameworkPath.length > 0) {
    [candidates addObject:config.frameworkPath];
  }

  NSString *privateFrameworks = [[NSBundle mainBundle] privateFrameworksPath];
  if (privateFrameworks.length > 0) {
    [candidates addObject:[privateFrameworks
                              stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"]];
  }

  // Fallback relative to libSafariumBrowserCore.dylib location (e.g. BrowserCore/build -> ../third_party/cef/Release).
  Dl_info dlInfo;
  if (dladdr((const void *)&SXRelativeLuminanceSRGB, &dlInfo) && dlInfo.dli_fname) {
    NSString *dylibPath = [NSString stringWithUTF8String:dlInfo.dli_fname];
    NSString *buildDir = [dylibPath stringByDeletingLastPathComponent];
    NSString *browserCoreDir = [buildDir stringByDeletingLastPathComponent];
    [candidates addObject:[browserCoreDir
                              stringByAppendingPathComponent:@"third_party/cef/Release/Chromium Embedded Framework.framework"]];
    [candidates addObject:[browserCoreDir
                              stringByAppendingPathComponent:@"third_party/custom-chromium/Chromium Embedded Framework.framework"]];
  }

  for (NSString *candidate in candidates) {
    NSString *binary =
        [candidate stringByAppendingPathComponent:@"Chromium Embedded Framework"];
    if ([fm fileExistsAtPath:binary]) {
      return candidate;
    }
  }
  return nil;
}

- (BOOL)initializeWithConfiguration:(nullable SXEngineConfiguration *)configuration
                              error:(NSError * _Nullable * _Nullable)error {
  if (self.initialized) {
    return YES;
  }

  [SXEngineRuntime installApplicationProtocolHooks];

  SXEngineConfiguration *config =
      configuration ?: [SXEngineConfiguration defaultConfiguration];

  NSString *frameworkPath = [self resolveFrameworkPathWithConfiguration:config];
  if (!frameworkPath) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.safarium.BrowserCore"
                                   code:1001
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Chromium Embedded Framework.framework not found."
                               }];
    }
    return NO;
  }

  NSString *frameworkBinary =
      [frameworkPath stringByAppendingPathComponent:@"Chromium Embedded Framework"];
  setenv("SAFARIUM_CEF_FRAMEWORK_BINARY", frameworkBinary.UTF8String, 1);

  if (!_cefLoaded) {
    if (!cef_load_library(frameworkBinary.UTF8String)) {
      if (error) {
        *error = [NSError errorWithDomain:@"com.safarium.BrowserCore"
                                     code:1002
                                 userInfo:@{
                                   NSLocalizedDescriptionKey :
                                       [NSString stringWithFormat:@"Failed to load CEF framework at %@",
                                                                  frameworkBinary]
                                 }];
      }
      return NO;
    }
    _cefLoaded = YES;
  }

  // Ensure persistent profile directory exists.
  NSString *profileDir = config.userDataDir;
  if (profileDir.length == 0) {
    profileDir = [SXEngineConfiguration defaultConfiguration].userDataDir;
  }
  [[NSFileManager defaultManager] createDirectoryAtPath:profileDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  self.profileDirectory = profileDir;
  [[SXExtensionManager sharedManager] configureWithProfileDirectory:profileDir];

  CefSettings settings;
  settings.external_message_pump = true;
  settings.windowless_rendering_enabled = false;
  settings.persist_session_cookies = true;

  // Remote debugging is strictly opt-in (off by default for privacy and anti-guardrail hygiene).
  // Activated via `chrome://inspect/#remote-debugging` (`Safarium.Pref.RemoteDebuggingEnabled`),
  // explicit `SXEngineConfiguration.remoteDebuggingPort`, or `SAFARIUM_REMOTE_DEBUGGING_PORT`.
  NSInteger resolvedDebugPort = 0;
  const char *envDebugPort = getenv("SAFARIUM_REMOTE_DEBUGGING_PORT");
  if (envDebugPort && envDebugPort[0] != '\0') {
    NSInteger parsed = (NSInteger)strtol(envDebugPort, NULL, 10);
    if (parsed >= 1024 && parsed <= 65535) {
      resolvedDebugPort = parsed;
    }
  } else if (config.remoteDebuggingPort >= 1024 && config.remoteDebuggingPort <= 65535) {
    resolvedDebugPort = config.remoteDebuggingPort;
  } else {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud boolForKey:@"Safarium.Pref.RemoteDebuggingEnabled"]) {
      NSInteger savedPort = [ud integerForKey:@"Safarium.Pref.RemoteDebuggingPort"];
      if (savedPort < 1024 || savedPort > 65535) {
        savedPort = 9222;
      }
      resolvedDebugPort = savedPort;
    }
  }
  settings.remote_debugging_port = (int)resolvedDebugPort;
  self.activeRemoteDebuggingPort = resolvedDebugPort;
  const char *cefDebug = getenv("SAFARIUM_CEF_DEBUG");
  settings.log_severity = (cefDebug && strcmp(cefDebug, "1") == 0)
                              ? LOGSEVERITY_INFO
                              : LOGSEVERITY_WARNING;

  SXApplyPendingSiteStorageClear(profileDir);
  CefString(&settings.root_cache_path).FromString(profileDir.UTF8String);
  CefString(&settings.cache_path).FromString(profileDir.UTF8String);
  CefString(&settings.framework_dir_path).FromString(frameworkPath.UTF8String);

  NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
  BOOL isInsideAppBundle = [bundlePath hasSuffix:@".app"];
  if (isInsideAppBundle) {
    CefString(&settings.main_bundle_path).FromString(bundlePath.UTF8String);
  }

  // Only override browser_subprocess_path if explicitly requested or if running
  // outside a standard macOS .app bundle with Contents/Frameworks/<AppName> Helper.app.
  NSString *execName =
      [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleExecutable"]
          ?: @"Safarium";
  NSString *expectedHelperName =
      [NSString stringWithFormat:@"%@ Helper.app", execName];
  NSString *bundledHelperApp = [[[NSBundle mainBundle] privateFrameworksPath]
      stringByAppendingPathComponent:expectedHelperName];
  BOOL hasBundledHelpers =
      isInsideAppBundle &&
      [[NSFileManager defaultManager] fileExistsAtPath:bundledHelperApp];

  if (config.helperExecutablePath.length > 0) {
    CefString(&settings.browser_subprocess_path)
        .FromString(config.helperExecutablePath.UTF8String);
  } else if (!hasBundledHelpers) {
    Dl_info dlInfo;
    if (dladdr((const void *)&SXRelativeLuminanceSRGB, &dlInfo) && dlInfo.dli_fname) {
      NSString *buildDir = [[NSString stringWithUTF8String:dlInfo.dli_fname]
          stringByDeletingLastPathComponent];
      NSString *devHelper = [buildDir
          stringByAppendingPathComponent:@"helpers/Safarium Helper.app/Contents/MacOS/Safarium Helper"];
      if ([[NSFileManager defaultManager] fileExistsAtPath:devHelper]) {
        CefString(&settings.browser_subprocess_path)
            .FromString(devHelper.UTF8String);
      }
    }
  }

  // Enable Chromium's macOS OS sandbox by default whenever bundled helpers and libcef_sandbox.dylib
  // are present inside a .app bundle. Allow explicit opt-out via SAFARIUM_DISABLE_SANDBOX=1 for
  // unbundled development or debugging runs.
  NSString *sandboxLibPath = [frameworkPath stringByAppendingPathComponent:@"Libraries/libcef_sandbox.dylib"];
  BOOL hasSandboxLib = [[NSFileManager defaultManager] fileExistsAtPath:sandboxLibPath];
  const char *disableSandbox = getenv("SAFARIUM_DISABLE_SANDBOX");
  BOOL sandboxDisabled = (disableSandbox && strcmp(disableSandbox, "1") == 0);
  BOOL useSandbox = hasBundledHelpers && hasSandboxLib && !sandboxDisabled;
  settings.no_sandbox = useSandbox ? false : true;

  if (config.locale.length > 0) {
    CefString(&settings.locale).FromString(config.locale.UTF8String);
  }

  // Forward actual process argv so macOS launch args are preserved cleanly.
  NSArray<NSString *> *procArgs = [[NSProcessInfo processInfo] arguments];
  std::vector<std::string> argStorage;
  std::vector<char *> argvPtrs;
  argStorage.reserve(procArgs.count);
  argvPtrs.reserve(procArgs.count);
  for (NSString *arg in procArgs) {
    argStorage.push_back(arg.UTF8String);
  }
  for (auto &s : argStorage) {
    argvPtrs.push_back(s.data());
  }

  CefMainArgs mainArgs((int)argvPtrs.size(), argvPtrs.data());
  _app = new SXBrowserApp();

  // Populate initial privacy snapshot on main thread before any network/renderer work runs.
  sx::privacy::SXPrivacyEngine::Shared().InitializeDefaultsFromUserDefaults();

  if (!CefInitialize(mainArgs, settings, _app, nullptr)) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.safarium.BrowserCore"
                                   code:1003
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"CefInitialize failed (check profile lock or helper bundles)."
                               }];
    }
    return NO;
  }

  self.initialized = YES;
  [self installScrollPhaseMonitorIfNeeded];
  [self scheduleMessagePumpWorkWithDelayMs:0];
  return YES;
}

- (void)installScrollPhaseMonitorIfNeeded {
  // Elastic scrolling & trackpad scroll monitoring are owned natively by SafariShell's ElasticScrollEngine.
}

- (BOOL)isContextInitialized {
  return _contextInitialized;
}

- (nullable NSDictionary<NSString *, id> *)cachedPreferencesCopy {
  std::lock_guard<std::mutex> lock(_prefsMutex);
  return _latestPreferences;
}

- (void)markContextInitialized {
  _contextInitialized = YES;
  CefRefPtr<CefRequestContext> globalCtx = CefRequestContext::GetGlobalContext();
  NSDictionary<NSString *, id> *prefs = [self cachedPreferencesCopy];
  if (globalCtx) {
    CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
        ^(CefRefPtr<CefRequestContext> ctx) {
          SXApplyPreferencesDictionaryToContext(ctx, prefs, false);
        },
        globalCtx)));
  }
  for (SXBrowserTab *tab in [self.mutableTabs copy]) {
    [tab createChromiumBrowserIfNeeded];
  }
}

- (void)notifyNavigationBurst {
  _navigationBurstUntil = CACurrentMediaTime() + 0.65;
  [self scheduleMessagePumpWorkWithDelayMs:0];
}

- (void)scheduleMessagePumpWorkOnMainWithDelayMs:(int64_t)delayMs {
  if (!self.initialized) {
    return;
  }
  if (delayMs <= 0) {
    if (_isPumping) {
      _reentrancyDetected = YES;
      return;
    }
    if (_immediatePumpPending) {
      return;
    }
    _immediatePumpPending = YES;
    [self.pumpTimer invalidate];
    self.pumpTimer = nil;
    __weak SXEngineRuntime *weakSelf = self;
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
      SXEngineRuntime *strongSelf = weakSelf;
      if (!strongSelf) return;
      strongSelf->_immediatePumpPending = NO;
      [strongSelf pumpMessageLoopWork];
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
    return;
  }

  // Do not overwrite an already-pending immediate pump with a delayed timer.
  if (_immediatePumpPending) {
    return;
  }

  [self.pumpTimer invalidate];
  self.pumpTimer = nil;

  NSTimeInterval interval = MIN((double)delayMs / 1000.0, 1.0);
  __weak SXEngineRuntime *weakSelf = self;
  self.pumpTimer = [NSTimer timerWithTimeInterval:interval
                                          repeats:NO
                                            block:^(NSTimer * _Nonnull timer) {
                                              SXEngineRuntime *strongSelf = weakSelf;
                                              if (!strongSelf) return;
                                              if (strongSelf.pumpTimer == timer) {
                                                strongSelf.pumpTimer = nil;
                                              }
                                              [strongSelf pumpMessageLoopWork];
                                            }];
  [[NSRunLoop mainRunLoop] addTimer:self.pumpTimer forMode:NSRunLoopCommonModes];
}

- (void)scheduleMessagePumpWorkWithDelayMs:(int64_t)delayMs {
  if (NSThread.isMainThread) {
    [self scheduleMessagePumpWorkOnMainWithDelayMs:delayMs];
  } else {
    __weak SXEngineRuntime *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf scheduleMessagePumpWorkOnMainWithDelayMs:delayMs];
    });
  }
}

- (void)pumpMessageLoopWork {
  if (!self.initialized) {
    return;
  }
  if (_isPumping) {
    _reentrancyDetected = YES;
    return;
  }

  [self.pumpTimer invalidate];
  self.pumpTimer = nil;

  _isPumping = YES;
  _reentrancyDetected = NO;
  CefDoMessageLoopWork();
  _isPumping = NO;

  if (_reentrancyDetected) {
    _reentrancyDetected = NO;
    [self scheduleMessagePumpWorkWithDelayMs:0];
  } else if (!self.pumpTimer && !_immediatePumpPending) {
    // Tick at 8ms (120Hz ProMotion) during active navigation bursts, relaxing to 33ms when idle.
    int64_t heartbeatMs = (CACurrentMediaTime() < _navigationBurstUntil) ? 8 : 33;
    [self scheduleMessagePumpWorkWithDelayMs:heartbeatMs];
  }
}

- (nullable SXBrowserTab *)createTabWithInitialURL:(nullable NSURL *)initialURL
                                        parentView:(nullable NSView *)parentView
                                          delegate:(nullable id<SXBrowserTabDelegate>)delegate {
  return [self createTabWithInitialURL:initialURL
                            parentView:parentView
                              delegate:delegate
                             incognito:NO];
}

- (nullable SXBrowserTab *)createTabWithInitialURL:(nullable NSURL *)initialURL
                                        parentView:(nullable NSView *)parentView
                                          delegate:(nullable id<SXBrowserTabDelegate>)delegate
                                         incognito:(BOOL)incognito {
  if (!self.initialized) {
    return nil;
  }
  SXBrowserTab *tab = [[SXBrowserTab alloc] initWithRuntime:self
                                                 initialURL:initialURL
                                                 parentView:parentView
                                                   delegate:delegate
                                                  incognito:incognito];
  [self.mutableTabs addObject:tab];
  [tab createChromiumBrowserIfNeeded];
  return tab;
}

- (CefRefPtr<CefRequestContext>)sharedIncognitoRequestContext {
  if (!_incognitoRequestContext) {
    class SXIncognitoRequestContextHandler : public CefRequestContextHandler {
     public:
      explicit SXIncognitoRequestContextHandler(SXEngineRuntime *rt) : runtime_(rt) {}
      void OnRequestContextInitialized(CefRefPtr<CefRequestContext> request_context) override {
        SXEngineRuntime *rt = runtime_;
        NSDictionary<NSString *, id> *prefs = rt ? [rt cachedPreferencesCopy] : nil;
        SXApplyPreferencesDictionaryToContext(request_context, prefs, true);
      }
     private:
      __weak SXEngineRuntime *runtime_;
      IMPLEMENT_REFCOUNTING(SXIncognitoRequestContextHandler);
    };

    CefRequestContextSettings ctxSettings;
    // Empty cache_path creates a true in-memory Chromium Off-The-Record / Incognito context
    // with isolated cookies, storage, and zero disk persistence.
    CefString(&ctxSettings.cache_path).FromString("");
    ctxSettings.persist_session_cookies = 0;
    _incognitoRequestContext =
        CefRequestContext::CreateContext(ctxSettings, new SXIncognitoRequestContextHandler(self));
  }
  return _incognitoRequestContext;
}

- (void)resetIncognitoSession {
  _incognitoRequestContext = nullptr;
  sx::privacy::SXPrivacyEngine::Shared().ResetIncognitoState();
}

- (NSArray<SXBrowserTab *> *)activeTabs {
  return [self.mutableTabs copy];
}

- (BOOL)isRemoteDebuggingActive {
  return self.activeRemoteDebuggingPort >= 1024 && self.activeRemoteDebuggingPort <= 65535;
}

- (nullable NSString *)devToolsActivePortFilePath {
  if (self.profileDirectory.length == 0) {
    return nil;
  }
  return [self.profileDirectory stringByAppendingPathComponent:@"DevToolsActivePort"];
}

- (nullable NSString *)remoteDebuggingWebSocketURL {
  if (!self.isRemoteDebuggingActive) {
    return nil;
  }
  NSString *portFile = self.devToolsActivePortFilePath;
  if (portFile.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:portFile]) {
    NSString *contents = [NSString stringWithContentsOfFile:portFile
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    if (contents.length > 0) {
      NSMutableArray<NSString *> *lines = [NSMutableArray array];
      for (NSString *raw in [contents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) {
          [lines addObject:trimmed];
        }
      }
      if (lines.count >= 2) {
        NSInteger filePort = [lines[0] integerValue];
        NSString *wsPath = lines[1];
        if (filePort >= 1024 && filePort <= 65535 && [wsPath hasPrefix:@"/"]) {
          return [NSString stringWithFormat:@"ws://127.0.0.1:%ld%@", (long)filePort, wsPath];
        }
      }
    }
  }
  return [NSString stringWithFormat:@"ws://127.0.0.1:%ld", (long)self.activeRemoteDebuggingPort];
}

- (void)openDevToolsForRemoteWebSocketURL:(NSString *)wsURL {
  if (!self.initialized || !_contextInitialized || wsURL.length == 0) {
    return;
  }
  NSString *trimmed = [wsURL stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (trimmed.length == 0) {
    return;
  }
  NSString *inspectorURL = nil;
  if ([trimmed hasPrefix:@"devtools://"] || [trimmed hasPrefix:@"http://"] || [trimmed hasPrefix:@"https://"]) {
    inspectorURL = trimmed;
  } else if ([trimmed hasPrefix:@"wss://"]) {
    NSString *stripped = [trimmed substringFromIndex:6];
    inspectorURL = [NSString stringWithFormat:@"devtools://devtools/bundled/inspector.html?wss=%@", stripped];
  } else if ([trimmed hasPrefix:@"ws://"]) {
    NSString *stripped = [trimmed substringFromIndex:5];
    inspectorURL = [NSString stringWithFormat:@"devtools://devtools/bundled/inspector.html?ws=%@", stripped];
  } else {
    inspectorURL = [NSString stringWithFormat:@"devtools://devtools/bundled/inspector.html?ws=%@", trimmed];
  }

  NSString *finalURL = [inspectorURL copy];
  dispatch_async(dispatch_get_main_queue(), ^{
    CefWindowInfo winInfo;
    winInfo.parent_view = nullptr;
    winInfo.runtime_style = CEF_RUNTIME_STYLE_CHROME;
    winInfo.bounds = CefRect(120, 120, 1100, 760);
    CefBrowserSettings browserSettings;
    CefBrowserHost::CreateBrowser(winInfo, nullptr, CefString(finalURL.UTF8String),
                                  browserSettings, nullptr, nullptr);
  });
}

- (void)tabDidClose:(SXBrowserTab *)tab {
  [self.mutableTabs removeObject:tab];
}

- (void)noteBrowserCreated {
  _liveBrowserCount.fetch_add(1, std::memory_order_acq_rel);
}

- (void)noteBrowserClosed {
  int prev = _liveBrowserCount.fetch_sub(1, std::memory_order_acq_rel);
  if (prev <= 0) {
    _liveBrowserCount.store(0, std::memory_order_release);
  }
}

- (NSInteger)liveBrowserCount {
  return (NSInteger)_liveBrowserCount.load(std::memory_order_acquire);
}

- (void)registerDownloadCallback:(CefRefPtr<CefDownloadItemCallback>)callback
                   forDownloadID:(uint32_t)downloadID {
  std::lock_guard<std::mutex> lock(_downloadMutex);
  _downloads[downloadID] = callback;
}

- (void)unregisterDownloadCallbackForDownloadID:(uint32_t)downloadID {
  std::lock_guard<std::mutex> lock(_downloadMutex);
  _downloads.erase(downloadID);
}

- (void)cancelDownloadWithID:(uint32_t)downloadID {
  CefRefPtr<CefDownloadItemCallback> cb;
  {
    std::lock_guard<std::mutex> lock(_downloadMutex);
    auto it = _downloads.find(downloadID);
    if (it != _downloads.end()) {
      cb = it->second;
      _downloads.erase(it);
    }
  }
  if (cb) {
    cb->Cancel();
  }
}

- (void)pauseDownloadWithID:(uint32_t)downloadID {
  CefRefPtr<CefDownloadItemCallback> cb;
  {
    std::lock_guard<std::mutex> lock(_downloadMutex);
    auto it = _downloads.find(downloadID);
    if (it != _downloads.end()) {
      cb = it->second;
    }
  }
  if (cb) {
    cb->Pause();
  }
}

- (BOOL)resumeDownloadWithID:(uint32_t)downloadID {
  CefRefPtr<CefDownloadItemCallback> cb;
  {
    std::lock_guard<std::mutex> lock(_downloadMutex);
    auto it = _downloads.find(downloadID);
    if (it != _downloads.end()) {
      cb = it->second;
    }
  }
  if (cb) {
    cb->Resume();
    return YES;
  }
  return NO;
}

- (void)applyPreferences:(NSDictionary<NSString *, id> *)preferences {
  if (!preferences.count) return;
  NSDictionary *prefsCopy = [preferences copy];
  {
    std::lock_guard<std::mutex> lock(_prefsMutex);
    _latestPreferences = prefsCopy;
  }
  if (!self.initialized) return;
  CefRefPtr<CefRequestContext> globalCtx = CefRequestContext::GetGlobalContext();
  CefRefPtr<CefRequestContext> incognitoCtx = _incognitoRequestContext;

  CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
      ^(CefRefPtr<CefRequestContext> gCtx, CefRefPtr<CefRequestContext> iCtx) {
        SXApplyPreferencesDictionaryToContext(gCtx, prefsCopy, false);
        SXApplyPreferencesDictionaryToContext(iCtx, prefsCopy, true);
      },
      globalCtx, incognitoCtx)));
}

- (void)clearWebsiteDataWithCompletion:(nullable void (^)(BOOL success))completion {
  NSString *profileDir = self.profileDirectory;
  CefRefPtr<CefRequestContext> globalCtx = CefRequestContext::GetGlobalContext();

  class SXClearDataTask : public CefTask {
   public:
    explicit SXClearDataTask(void (^block)(void)) : block_([block copy]) {}
    void Execute() override {
      if (block_) block_();
    }
   private:
    void (^block_)(void);
    IMPLEMENT_REFCOUNTING(SXClearDataTask);
  };

  CefPostTask(TID_UI, new SXClearDataTask(^{
    CefRefPtr<CefCookieManager> cm = globalCtx ? globalCtx->GetCookieManager(nullptr) : nullptr;
    if (cm) {
      cm->DeleteCookies(CefString(), CefString(), nullptr);
      cm->FlushStore(nullptr);
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      if (profileDir.length > 0) {
        NSFileManager *fm = [NSFileManager defaultManager];
        // Chromium keeps Local Storage / IndexedDB / Session Storage open (leveldb) while running, so deleting them
        // now would be racy and the browser would just re-flush them. Mark them for removal before the next launch.
        [@"1" writeToFile:[profileDir stringByAppendingPathComponent:@"ClearSiteStorageOnLaunch"]
               atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSArray<NSString *> *subPaths = @[
          @"Default/Cache",
          @"Default/Code Cache",
          @"Default/GPUCache",
          @"Default/Service Worker/CacheStorage",
          @"Cache"
        ];
        for (NSString *rel in subPaths) {
          NSString *full = [profileDir stringByAppendingPathComponent:rel];
          if ([fm fileExistsAtPath:full]) {
            [fm removeItemAtPath:full error:nil];
          }
        }
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) {
          completion(YES);
        }
      });
    });
  }));
}

- (void)dispatchPrivacyEvent:(SXPrivacyEvent *)event forTab:(nullable SXBrowserTab *)tab {
  if (!event) return;
  if (tab) {
    [tab handlePrivacyEvent:event];
  }
  [[NSNotificationCenter defaultCenter]
      postNotificationName:SXEngineRuntimeDidRecordPrivacyEventNotification
                    object:self
                  userInfo:@{@"event" : event}];
}

- (void)syncPrivacyPolicy:(NSDictionary<NSString *, id> *)policy {
  auto snap = sx::privacy::SXPrivacyEngine::Shared().UpdatePolicyFromDictionary(policy ?: @{});
  CefRefPtr<CefDictionaryValue> normalCfg = SXBuildPrivacyConfigUpdateDictionary(false);
  CefRefPtr<CefDictionaryValue> privateCfg = SXBuildPrivacyConfigUpdateDictionary(true);

  for (SXBrowserTab *tab in [self.mutableTabs copy]) {
    [tab sendPrivacyConfigUpdateDictionary:tab.isPrivateBrowsing ? privateCfg : normalCfg];
  }

  if (!self.initialized) return;
  CefRefPtr<CefRequestContext> globalCtx = CefRequestContext::GetGlobalContext();
  CefRefPtr<CefRequestContext> incognitoCtx = _incognitoRequestContext;

  CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
      [](CefRefPtr<CefRequestContext> gCtx,
         CefRefPtr<CefRequestContext> iCtx,
         std::shared_ptr<const sx::privacy::PolicySnapshot> s) {
        SXApplyPrivacySnapshotToContext(gCtx, s, false);
        SXApplyPrivacySnapshotToContext(iCtx, s, true);
      },
      globalCtx, incognitoCtx, snap)));
}

- (void)allowInsecureHTTPForHost:(NSString *)host {
  if (host.length == 0 || !host.UTF8String) return;
  std::string normTarget = sx::privacy::NormalizeHost(host.UTF8String);
  if (normTarget.empty()) return;

  bool matchedPrivate = false;
  bool matchedNormal = false;
  for (SXBrowserTab *tab in [self.mutableTabs copy]) {
    NSString *secHost = tab.connectionSecurityHost ?: tab.currentURL.host;
    if (secHost.UTF8String && sx::privacy::NormalizeHost(secHost.UTF8String) == normTarget) {
      if ([tab isPrivateBrowsing]) {
        matchedPrivate = true;
      } else {
        matchedNormal = true;
      }
    }
  }
  if (matchedPrivate && !matchedNormal) {
    sx::privacy::SXPrivacyEngine::Shared().AllowInsecureHTTPForHost(normTarget, true);
  } else if (matchedPrivate && matchedNormal) {
    sx::privacy::SXPrivacyEngine::Shared().AllowInsecureHTTPForHost(normTarget, true);
    sx::privacy::SXPrivacyEngine::Shared().AllowInsecureHTTPForHost(normTarget, false);
  } else {
    sx::privacy::SXPrivacyEngine::Shared().AllowInsecureHTTPForHost(normTarget, false);
  }
}

- (void)fetchWebsiteDataRecordsWithCompletion:(void (^)(NSArray<SXWebsiteDataRecord *> *records))completion {
  if (!completion) return;
  void (^completionCopy)(NSArray<SXWebsiteDataRecord *> *) = [completion copy];
  if (!self.initialized) {
    dispatch_async(dispatch_get_main_queue(), ^{
      completionCopy(@[]);
    });
    return;
  }

  class SXWebsiteDataFetchVisitor : public CefCookieVisitor {
   public:
    explicit SXWebsiteDataFetchVisitor(void (^cb)(NSArray<SXWebsiteDataRecord *> *))
        : cb_([cb copy]) {}

    ~SXWebsiteDataFetchVisitor() override {
      Finish();
    }

    bool Visit(const CefCookie& cookie,
               int count,
               int total,
               bool& deleteCookie) override {
      (void)count;
      (void)total;
      deleteCookie = false;
      std::string domain = sx::privacy::ToLowerASCII(CefString(&cookie.domain).ToString());
      while (!domain.empty() && domain.front() == '.') {
        domain.erase(domain.begin());
      }
      if (!domain.empty()) {
        counts_[domain] += 1;
      }
      return true;
    }

    void Finish() {
      if (finished_.exchange(true)) return;
      @autoreleasepool {
        NSMutableArray<SXWebsiteDataRecord *> *records = [NSMutableArray arrayWithCapacity:counts_.size()];
        for (const auto& kv : counts_) {
          NSString *dom = [NSString stringWithUTF8String:kv.first.c_str()];
          if (dom.length > 0) {
            [records addObject:[[SXWebsiteDataRecord alloc] initWithDomain:dom
                                                               cookieCount:kv.second
                                                                hasCookies:(kv.second > 0)
                                                                  hasCache:NO]];
          }
        }
        [records sortUsingComparator:^NSComparisonResult(SXWebsiteDataRecord *a, SXWebsiteDataRecord *b) {
          return [a.domain caseInsensitiveCompare:b.domain];
        }];
        NSArray<SXWebsiteDataRecord *> *result = [records copy];
        void (^cb)(NSArray<SXWebsiteDataRecord *> *) = cb_;
        dispatch_async(dispatch_get_main_queue(), ^{
          if (cb) cb(result);
        });
      }
    }

   private:
    std::unordered_map<std::string, NSInteger> counts_;
    void (^cb_)(NSArray<SXWebsiteDataRecord *> *);
    std::atomic<bool> finished_{false};
    IMPLEMENT_REFCOUNTING(SXWebsiteDataFetchVisitor);
  };

  CefRefPtr<CefRequestContext> globalCtx = CefRequestContext::GetGlobalContext();
  CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
      ^(CefRefPtr<CefRequestContext> ctx) {
        CefRefPtr<CefCookieManager> cm = ctx ? ctx->GetCookieManager(nullptr) : nullptr;
        if (!cm) {
          dispatch_async(dispatch_get_main_queue(), ^{
            completionCopy(@[]);
          });
          return;
        }
        CefRefPtr<SXWebsiteDataFetchVisitor> visitor = new SXWebsiteDataFetchVisitor(completionCopy);
        if (!cm->VisitAllCookies(visitor)) {
          visitor->Finish();
        }
      },
      globalCtx)));
}

- (void)removeWebsiteDataForDomains:(NSArray<NSString *> *)domains
                         completion:(nullable void (^)(BOOL success))completion {
  void (^completionCopy)(BOOL) = [completion copy];
  if (!self.initialized || domains.count == 0) {
    if (completionCopy) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completionCopy(YES);
      });
    }
    return;
  }

  std::unordered_set<std::string> targetDomains;
  for (NSString *raw in domains) {
    if (![raw isKindOfClass:[NSString class]] || !raw.UTF8String) continue;
    std::string d = sx::privacy::ToLowerASCII(raw.UTF8String);
    while (!d.empty() && d.front() == '.') {
      d.erase(d.begin());
    }
    if (!d.empty()) {
      targetDomains.insert(std::move(d));
    }
  }
  if (targetDomains.empty()) {
    if (completionCopy) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completionCopy(YES);
      });
    }
    return;
  }

  class SXFlushCookiesCallback : public CefCompletionCallback {
   public:
    explicit SXFlushCookiesCallback(void (^cb)(BOOL), bool ok)
        : cb_([cb copy]), ok_(ok) {}
    void OnComplete() override {
      if (cb_) {
        void (^cb)(BOOL) = cb_;
        bool ok = ok_;
        dispatch_async(dispatch_get_main_queue(), ^{
          cb(ok ? YES : NO);
        });
      }
    }
   private:
    void (^cb_)(BOOL);
    bool ok_;
    IMPLEMENT_REFCOUNTING(SXFlushCookiesCallback);
  };

  class SXRemoveDomainCookiesVisitor : public CefCookieVisitor {
   public:
    SXRemoveDomainCookiesVisitor(CefRefPtr<CefCookieManager> cm,
                                 std::unordered_set<std::string> targets,
                                 void (^cb)(BOOL))
        : cm_(cm), targets_(std::move(targets)), cb_([cb copy]) {}

    ~SXRemoveDomainCookiesVisitor() override {
      Finish(true);
    }

    bool Visit(const CefCookie& cookie,
               int count,
               int total,
               bool& deleteCookie) override {
      (void)count;
      (void)total;
      std::string domain = sx::privacy::ToLowerASCII(CefString(&cookie.domain).ToString());
      while (!domain.empty() && domain.front() == '.') {
        domain.erase(domain.begin());
      }
      bool match = false;
      std::string_view probe(domain);
      while (!probe.empty()) {
        if (targets_.count(std::string(probe)) > 0) {
          match = true;
          break;
        }
        size_t dot = probe.find('.');
        if (dot == std::string_view::npos) break;
        probe.remove_prefix(dot + 1);
      }
      deleteCookie = match;
      return true;
    }

    void Finish(bool ok) {
      if (finished_.exchange(true)) return;
      if (cm_) {
        if (!cm_->FlushStore(new SXFlushCookiesCallback(cb_, ok))) {
          if (cb_) {
            void (^cb)(BOOL) = cb_;
            dispatch_async(dispatch_get_main_queue(), ^{
              cb(NO);
            });
          }
        }
      } else if (cb_) {
        void (^cb)(BOOL) = cb_;
        dispatch_async(dispatch_get_main_queue(), ^{
          cb(ok ? YES : NO);
        });
      }
    }

   private:
    CefRefPtr<CefCookieManager> cm_;
    std::unordered_set<std::string> targets_;
    void (^cb_)(BOOL);
    std::atomic<bool> finished_{false};
    IMPLEMENT_REFCOUNTING(SXRemoveDomainCookiesVisitor);
  };

  CefRefPtr<CefRequestContext> globalCtx = CefRequestContext::GetGlobalContext();
  CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
      ^(CefRefPtr<CefRequestContext> ctx) {
        CefRefPtr<CefCookieManager> cm = ctx ? ctx->GetCookieManager(nullptr) : nullptr;
        if (!cm) {
          if (completionCopy) {
            dispatch_async(dispatch_get_main_queue(), ^{
              completionCopy(NO);
            });
          }
          return;
        }
        for (const auto& d : targetDomains) {
          cm->DeleteCookies(CefString("https://" + d + "/"), CefString(), nullptr);
          cm->DeleteCookies(CefString("http://" + d + "/"), CefString(), nullptr);
        }
        CefRefPtr<SXRemoveDomainCookiesVisitor> visitor =
            new SXRemoveDomainCookiesVisitor(cm, targetDomains, completionCopy);
        if (!cm->VisitAllCookies(visitor)) {
          visitor->Finish(false);
        }
      },
      globalCtx)));
}

#pragma mark Chrome Web Store MV3 Extensions

- (NSArray<NSString *> *)startupExtensionDirectories {
  return [[SXExtensionManager sharedManager] startupExtensionDirectories];
}

- (BOOL)isChromeWebStoreExtensionInstalled:(NSString *)storeID {
  return [[SXExtensionManager sharedManager] isStoreIDInstalled:storeID];
}

- (void)notifyExtensionsUpdated {
  NSArray<SXExtensionItem *> *list = [self installedExtensions];
  if ([self.extensionDelegate respondsToSelector:@selector(engineRuntime:didUpdateExtensions:)]) {
    [self.extensionDelegate engineRuntime:self didUpdateExtensions:list];
  }
  [[NSNotificationCenter defaultCenter]
      postNotificationName:SXEngineRuntimeDidUpdateExtensionsNotification
                    object:self
                  userInfo:@{@"extensions" : list}];
}

- (NSArray<SXExtensionItem *> *)installedExtensions {
  return [[SXExtensionManager sharedManager] installedExtensions];
}

- (void)loadUnpackedExtensionAtPath:(NSString *)directoryPath
                         completion:(nullable void (^)(SXExtensionItem * _Nullable,
                                                       NSError * _Nullable))completion {
  [[SXExtensionManager sharedManager] loadUnpackedExtensionAtPath:directoryPath
                                                       completion:completion];
}

- (void)installExtensionFromCRXAtPath:(NSString *)crxPath
                           completion:(nullable void (^)(SXExtensionItem * _Nullable,
                                                         NSError * _Nullable))completion {
  [[SXExtensionManager sharedManager] installExtensionFromCRXAtPath:crxPath
                                                         completion:completion];
}

- (void)installExtensionFromChromeWebStoreID:(NSString *)storeID
                                  completion:(nullable void (^)(SXExtensionItem * _Nullable,
                                                                NSError * _Nullable))completion {
  [[SXExtensionManager sharedManager] installExtensionFromChromeWebStoreID:storeID
                                                                completion:completion];
}

- (void)uninstallExtensionWithID:(NSString *)extensionID
                      completion:(nullable void (^)(BOOL, NSError * _Nullable))completion {
  [[SXExtensionManager sharedManager] uninstallExtensionWithID:extensionID
                                                    completion:completion];
}

- (void)setExtensionWithID:(NSString *)extensionID
                   enabled:(BOOL)enabled
                completion:(nullable void (^)(BOOL, NSError * _Nullable))completion {
  [[SXExtensionManager sharedManager] setExtensionWithID:extensionID
                                                 enabled:enabled
                                              completion:completion];
}

- (void)setExtensionWithID:(NSString *)extensionID
            allowInPrivate:(BOOL)allowInPrivate
                completion:(nullable void (^)(BOOL, NSError * _Nullable))completion {
  [[SXExtensionManager sharedManager] setExtensionWithID:extensionID
                                          allowInPrivate:allowInPrivate
                                              completion:completion];
}

- (void)clearStorageForExtensionWithID:(NSString *)extensionID
                            completion:(nullable void (^)(BOOL, NSError * _Nullable))completion {
  [[SXExtensionManager sharedManager] clearStorageForExtensionWithID:extensionID
                                                          completion:completion];
}

- (nullable NSView *)createExtensionPopupViewForExtensionID:(NSString *)extensionID
                                                      width:(CGFloat)width
                                                     height:(CGFloat)height
                                                 parentView:(nullable NSView *)parentView {
  return [[SXExtensionManager sharedManager] createPopupViewForExtensionID:extensionID
                                                                     width:width
                                                                    height:height
                                                                parentView:parentView];
}

- (void)closeExtensionPopupForExtensionID:(nullable NSString *)extensionID {
  [[SXExtensionManager sharedManager] closePopupForExtensionID:extensionID];
}

- (NSArray<SXExtensionContextMenuItem *> *)contextMenuItemsForExtensionID:(NSString *)extensionID {
  return [[SXExtensionManager sharedManager] contextMenuItemsForExtensionID:extensionID];
}

- (void)triggerContextMenuItemWithID:(NSString *)menuItemID
                      forExtensionID:(NSString *)extensionID
                             pageURL:(nullable NSURL *)pageURL {
  [[SXExtensionManager sharedManager] triggerContextMenuItemWithID:menuItemID
                                                    forExtensionID:extensionID
                                                           pageURL:pageURL];
}

- (void)postNewTabRequestForURL:(NSURL *)url {
  if (!url) {
    return;
  }
  dispatch_block_t work = ^{
    // Close any open extension popup when an extension opens an options page or new tab.
    [[SXExtensionManager sharedManager] closeAllPopups];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:SXEngineRuntimeRequestNewTabNotification
                      object:self
                    userInfo:@{@"url" : url}];
  };
  if (NSThread.isMainThread) {
    work();
  } else {
    dispatch_async(dispatch_get_main_queue(), work);
  }
}

- (void)postNewWindowRequestForURL:(NSURL *)url {
  if (!url) {
    return;
  }
  dispatch_block_t work = ^{
    [[SXExtensionManager sharedManager] closeAllPopups];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:SXEngineRuntimeRequestNewWindowNotification
                      object:self
                    userInfo:@{@"url" : url}];
  };
  if (NSThread.isMainThread) {
    work();
  } else {
    dispatch_async(dispatch_get_main_queue(), work);
  }
}

/// SAFARIUM_QUIT_DEBUG=1: timestamps for each quit phase on stderr (where the time goes when quitting is slow).
static void SXQuitLog(const char *step) {
  static const bool on = getenv("SAFARIUM_QUIT_DEBUG") != nullptr;
  if (!on) return;
  fprintf(stderr, "[Quit] %.3f %s\n", CFAbsoluteTimeGetCurrent(), step);
  fflush(stderr);
}

- (void)shutdown {
  if (!self.initialized) {
    return;
  }
  SXQuitLog("shutdown begin");
  // Persist cookies now: if a wedged browser makes us skip CefShutdown below, nothing recent is lost.
  if (CefRefPtr<CefCookieManager> cookies = CefCookieManager::GetGlobalManager(nullptr)) {
    cookies->FlushStore(nullptr);
  }

  [self.pumpTimer invalidate];
  self.pumpTimer = nil;
  if (self.scrollPhaseMonitor) {
    [NSEvent removeMonitor:self.scrollPhaseMonitor];
    self.scrollPhaseMonitor = nil;
  }

  // Cancel and drop any tracked download callbacks before closing browsers.
  {
    std::lock_guard<std::mutex> lock(_downloadMutex);
    _downloads.clear();
  }

  // Initiate forced close on every open tab, then drop strong tab references so no
  // CefRefPtr<SXBrowserClient> or host NSView stays pinned across shutdown.
  {
    NSArray<SXBrowserTab *> *tabs = [self.mutableTabs copy];
    for (SXBrowserTab *tab in tabs) {
      [tab closeTab];
    }
  }

  // Shut down extension popups, popout windows, and hidden admin loader browsers.
  SXQuitLog("tabs closing requested");
  [[SXExtensionManager sharedManager] shutdown];
  SXQuitLog("extension manager shut down");

  // Release any off-the-record CefRequestContext before CefShutdown so CEF never hits
  // a live-object DCHECK on exit.
  _incognitoRequestContext = nullptr;

  // Pump the CEF message loop + NSRunLoop until EVERY tracked CefBrowser has completed OnBeforeClose (exits as
  // soon as liveBrowserCount reaches 0). The ceiling was 2.5 s: a busy page (e.g. Reddit) can take longer than
  // that to acknowledge a forced close, and the app sat in this loop for the whole ceiling on every quit. 1 s is
  // ample for normal pages; past it CefShutdown is skipped below exactly as before.
  for (int i = 0; i < 100 && (self.mutableTabs.count > 0 || [self liveBrowserCount] > 0); ++i) {
    CefDoMessageLoopWork();
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }

  SXQuitLog([[NSString stringWithFormat:@"browsers closed wait done (live=%ld tabs=%lu)", (long)[self liveBrowserCount],
                                         (unsigned long)self.mutableTabs.count] UTF8String]);
  for (SXBrowserTab *t in [self.mutableTabs copy]) {
    SXQuitLog([[NSString stringWithFormat:@"  still open: %@", t.currentURL.absoluteString ?: @"(nil)"] UTF8String]);
  }
  // Drain a few extra iterations so deferred UI-thread browser teardown tasks complete cleanly.
  for (int i = 0; i < 5; ++i) {
    CefDoMessageLoopWork();
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
  }

  [self.mutableTabs removeAllObjects];
  self.initialized = NO;
  _contextInitialized = NO;

  // Only invoke CefShutdown() when every CefBrowser has cleanly reached OnBeforeClose;
  // calling CefShutdown() with a wedged browser still alive triggers a fatal CEF SIGTRAP.
  if ([self liveBrowserCount] <= 0) {
    SXQuitLog("CefShutdown begin");
    CefShutdown();
    SXQuitLog("CefShutdown end");
    _app = nullptr;
    if (_cefLoaded) {
      cef_unload_library();
      _cefLoaded = NO;
    }
  } else {
    fprintf(stderr, "[BrowserCore] Skipping CefShutdown with %ld live browser(s) remaining after timeout\n",
            (long)[self liveBrowserCount]);
    fflush(stderr);
    _app = nullptr;
  }
}

@end
