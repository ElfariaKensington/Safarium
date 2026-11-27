// SafariumEngineBridge.h
// Objective-C public bridge between SafariShell (Swift + AppKit) and BrowserCore (Chromium / CEF Chrome Runtime).
// Pure Objective-C / AppKit header — safe to import directly from Swift bridging headers or module maps.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#ifndef SX_EXPORT
#define SX_EXPORT __attribute__((visibility("default")))
#endif

NS_ASSUME_NONNULL_BEGIN

@class SXBrowserTab;
@class SXDownloadItem;
@class SXExtensionItem;
@class SXPrivacyEvent;
@class SXWebsiteDataRecord;
@class SXEngineRuntime;

extern SX_EXPORT NSNotificationName const SXEngineRuntimeDidUpdateExtensionsNotification;
/// Posted on the main thread when an open extension popup's rendered DOM content size changes.
/// userInfo keys: `"extensionID"` (NSString), `"width"` (NSNumber CGFloat), `"height"` (NSNumber CGFloat).
extern SX_EXPORT NSNotificationName const SXExtensionPopupPreferredSizeDidChangeNotification;
/// Posted on the main thread when Chromium (e.g. an extension popup, options page, or
/// service worker) requests opening a URL in a new native Safarium tab.
/// userInfo keys: `"url"` (NSURL).
extern SX_EXPORT NSNotificationName const SXEngineRuntimeRequestNewTabNotification;
extern SX_EXPORT NSNotificationName const SXEngineRuntimeRequestNewWindowNotification;
/// Posted on the main thread whenever BrowserCore records a privacy event.
/// userInfo key: `"event"` (`SXPrivacyEvent *`).
extern SX_EXPORT NSNotificationName const SXEngineRuntimeDidRecordPrivacyEventNotification;

typedef NS_ENUM(NSInteger, SXScrollPhase) {
  SXScrollPhaseBegan = 0,
  SXScrollPhaseEnded = 1,
  SXScrollPhaseMomentumBegan = 2,
  SXScrollPhaseMomentumEnded = 3,
};

typedef NS_ENUM(NSInteger, SXConnectionSecurityState) {
  SXConnectionSecurityStateInternal = 0,
  SXConnectionSecurityStateSecureHTTPS = 1,
  SXConnectionSecurityStateUpgradedHTTPS = 2,
  SXConnectionSecurityStateInsecureHTTP = 3,
  SXConnectionSecurityStateCertificateError = 4,
};

#pragma mark - Configuration

/// Configuration for initializing the real Chromium (`chrome/` layer) engine runtime.
SX_EXPORT
@interface SXEngineConfiguration : NSObject

/// Persistent Chromium profile / user-data directory.
/// Defaults to `~/Library/Application Support/Safarium/Profile`.
@property (nonatomic, copy) NSString *userDataDir;

/// Optional override path to `Chromium Embedded Framework.framework` (or custom Chromium `.framework`).
/// When nil, auto-discovers from the main app bundle (`Contents/Frameworks/`) or `BrowserCore/third_party/cef/Release/`.
@property (nonatomic, copy, nullable) NSString *frameworkPath;

/// Optional override path to the Chromium Helper executable (`Safarium Helper.app/Contents/MacOS/Safarium Helper`).
/// When nil, auto-discovers from `Contents/Frameworks/` or `BrowserCore/build/`.
@property (nonatomic, copy, nullable) NSString *helperExecutablePath;

/// Optional custom locale (e.g. "en-US"). Defaults to system locale.
@property (nonatomic, copy, nullable) NSString *locale;

/// Initial homepage URL when creating a tab without a URL. Defaults to `about:blank`.
@property (nonatomic, strong) NSURL *defaultNewTabURL;

/// Optional Chrome DevTools Protocol (CDP) remote debugging port (1024..65535).
/// Defaults to 0 (disabled unless enabled via `Safarium.Pref.RemoteDebuggingEnabled` or `SAFARIUM_REMOTE_DEBUGGING_PORT`).
@property (nonatomic, assign) NSInteger remoteDebuggingPort;

/// Creates a configuration with standard Safarium defaults (persistent profile, Chrome runtime, anti-bot clean).
+ (instancetype)defaultConfiguration;

@end

#pragma mark - Downloads

/// Represents a Chromium download tracked by Safarium (Phase 2/3 Downloads pill & popover).
SX_EXPORT
@interface SXDownloadItem : NSObject

@property (nonatomic, readonly) uint32_t downloadID;
@property (nonatomic, readonly, copy) NSString *suggestedFileName;
@property (nonatomic, readonly, copy, nullable) NSString *fullPath;
@property (nonatomic, readonly, strong, nullable) NSURL *url;
@property (nonatomic, readonly) int64_t totalBytes;
@property (nonatomic, readonly) int64_t receivedBytes;
@property (nonatomic, readonly) int32_t percentComplete;
@property (nonatomic, readonly, getter=isInProgress) BOOL inProgress;
@property (nonatomic, readonly, getter=isComplete) BOOL complete;
@property (nonatomic, readonly, getter=isCanceled) BOOL canceled;
@property (nonatomic, readonly, getter=isPaused) BOOL paused;

@end

#pragma mark - Chrome MV3 Extensions

/// Represents a live `chrome.contextMenus` item registered by an installed Chromium MV3 extension.
SX_EXPORT
@interface SXExtensionContextMenuItem : NSObject

@property (nonatomic, readonly, copy) NSString *itemID;
@property (nonatomic, readonly, copy, nullable) NSString *parentID;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, getter=isSeparator) BOOL separator;
@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly, getter=isChecked) BOOL checked;
@property (nonatomic, readonly, copy) NSArray<SXExtensionContextMenuItem *> *children;

@end

/// Represents an installed Chromium MV3 extension exposed to SafariShell's Liquid Glass toolbar.
SX_EXPORT
@interface SXExtensionItem : NSObject

/// Chromium 32-character runtime extension ID (used in `chrome-extension://<extensionID>/...`).
@property (nonatomic, readonly, copy) NSString *extensionID;
/// Original Chrome Web Store 32-character store ID (when installed from chromewebstore.google.com).
@property (nonatomic, readonly, copy, nullable) NSString *storeID;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *version;
@property (nonatomic, readonly, copy, nullable) NSString *extensionDescription;
@property (nonatomic, readonly, strong, nullable) NSImage *icon;
@property (nonatomic, readonly, copy, nullable) NSString *badgeText;
@property (nonatomic, readonly, strong, nullable) NSColor *badgeColor;
/// `chrome-extension://<extensionID>/<default_popup>` URL when the extension defines an action popup.
@property (nonatomic, readonly, strong, nullable) NSURL *popupURL;
@property (nonatomic, readonly, copy) NSString *installPath;
@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly) BOOL allowInPrivate;

@end

/// Delegate notified on the main thread whenever installed Chromium extensions change.
@protocol SXEngineExtensionDelegate <NSObject>
@optional
- (void)engineRuntime:(SXEngineRuntime *)runtime
   didUpdateExtensions:(NSArray<SXExtensionItem *> *)extensions;
@end

/// Represents a privacy protection event recorded by BrowserCore (tracker, cookie, link tracking, HTTPS upgrade, fingerprinting, bounce tracking, or page visit).
SX_EXPORT
@interface SXPrivacyEvent : NSObject

@property (nonatomic, readonly, copy) NSString *eventType; // "trackerBlocked","cookieBlocked","trackingParamStripped","httpsUpgraded","fingerprintBlocked","bounceTrackerMitigated","pageVisited"
@property (nonatomic, readonly, copy) NSString *pageHost;
@property (nonatomic, readonly, copy) NSString *trackerHost;
@property (nonatomic, readonly, copy) NSString *entityDomain;
@property (nonatomic, readonly, copy) NSString *ownerName;
@property (nonatomic, readonly, copy) NSString *category; // "advertising","analytics","social","fingerprinting","cryptomining","sessionReplay","dataBroker","emailTracking","cookie","linkTracking","httpsUpgrade","bounceTracking","other"
@property (nonatomic, readonly, copy) NSString *detail;
@property (nonatomic, readonly) NSInteger count;
@property (nonatomic, readonly) BOOL isPrivate;
@property (nonatomic, readonly) NSTimeInterval timestamp;

@end

/// Represents per-website stored cookie/cache data returned by `fetchWebsiteDataRecordsWithCompletion:`.
SX_EXPORT
@interface SXWebsiteDataRecord : NSObject

@property (nonatomic, readonly, copy) NSString *domain;
@property (nonatomic, readonly) NSInteger cookieCount;
@property (nonatomic, readonly) BOOL hasCookies;
@property (nonatomic, readonly) BOOL hasCache;

@end

#pragma mark - Tab Delegate

/// Delegate callbacks delivered on the main thread for a Chromium browser tab.
@protocol SXBrowserTabDelegate <NSObject>
@optional

- (void)browserTab:(SXBrowserTab *)tab didChangeURL:(NSURL *)url;
- (void)browserTab:(SXBrowserTab *)tab didChangeTitle:(NSString *)title;
- (void)browserTab:(SXBrowserTab *)tab
    didChangeLoadingState:(BOOL)isLoading
                canGoBack:(BOOL)canGoBack
             canGoForward:(BOOL)canGoForward;
- (void)browserTab:(SXBrowserTab *)tab didUpdateProgress:(double)progress;
- (void)browserTab:(SXBrowserTab *)tab didUpdateFavicon:(nullable NSImage *)favicon;
- (void)browserTab:(SXBrowserTab *)tab
    didFailLoadURL:(NSURL *)failedURL
         errorCode:(NSInteger)errorCode
         errorText:(NSString *)errorText;

/// Fired when the top 2–4pt rendered compositor surface strip is sampled.
/// Strictly reflects rendered pixels (ignores `<meta name="theme-color">`).
/// `relativeLuminance` is WCAG relative luminance in [0.0, 1.0].
- (void)browserTab:(SXBrowserTab *)tab
    didSampleTopEdgeColor:(NSColor *)color
        relativeLuminance:(double)relativeLuminance;

/// Fired when a webpage's docked fixed/sticky top header bar is detected (non-nil sRGB color)
/// or disappears (nil). Used to tint the frosted toolbar and ramp its blur gradient cleanly into the bar.
- (void)browserTab:(SXBrowserTab *)tab
    didUpdateFixedHeaderColor:(nullable NSColor *)color;

/// Fired when a standard `<video controls>` with a direct playable URL updates its viewport rect/visibility
/// so the host window can overlay a true native AppKit `AVPlayerView`.
- (void)browserTab:(SXBrowserTab *)tab
    didUpdateNativeVideoID:(NSString *)videoID
                    srcURL:(NSString *)srcURL
                      rect:(NSRect)rect
                   visible:(BOOL)visible
                  autoplay:(BOOL)autoplay;

/// Fired when renderer detects password/autofill focus/save, Sign in with Apple, or a WebAuthn passkey create/get request.
- (void)browserTab:(SXBrowserTab *)tab
    didReceiveAuthEventJSON:(NSString *)jsonString;

/// Fired when an opener-preserving Sign in with Apple / OAuth child popup is opened, navigates, or closes.
- (void)browserTab:(SXBrowserTab *)tab didOpenAuthPopupWithURL:(NSURL *)url;
- (void)browserTab:(SXBrowserTab *)tab didUpdateAuthPopupURL:(NSURL *)url;
- (void)browserTabDidCloseAuthPopup:(SXBrowserTab *)tab;

/// Telemetry hooks for Phase 2/3 scroll, background extension bleed, and pinch-to-overview.
- (void)browserTab:(SXBrowserTab *)tab
    didUpdateScrollY:(CGFloat)scrollY
       contentHeight:(CGFloat)contentHeight;
- (void)browserTab:(SXBrowserTab *)tab
    didUpdatePageScale:(CGFloat)pageScale
            isPinching:(BOOL)isPinching;

/// Fired continuously during Safari-style rubber-band overscroll past the top (>0) or bottom (<0) edge.
/// `overscrollY` is the rubber-banded displacement in points; `armed` is YES when past the 64pt pull trigger.
- (void)browserTab:(SXBrowserTab *)tab
    didUpdateOverscrollY:(CGFloat)overscrollY
                   armed:(BOOL)armed;

/// Fired when the user releases an armed pull-to-refresh gesture (or high-momentum top overshoot).
- (void)browserTabDidTriggerPullToRefresh:(SXBrowserTab *)tab
    NS_SWIFT_NAME(browserTabDidTriggerPullToRefresh(_:));

/// Download lifecycle hooks for Phase 2/3 Downloads toolbar button.
- (void)browserTab:(SXBrowserTab *)tab didStartDownload:(SXDownloadItem *)download;
- (void)browserTab:(SXBrowserTab *)tab didUpdateDownload:(SXDownloadItem *)download;

/// Popup / target=_blank request. Return a newly created tab or nil to let Safarium open it in the current tab/new tab.
- (nullable SXBrowserTab *)browserTab:(SXBrowserTab *)tab
                  requestNewTabWithURL:(NSURL *)url
                           userGesture:(BOOL)userGesture;

/// Fired when the user presses Cmd+Left / Cmd+Right on a non-editable region of the webpage.
- (void)browserTabDidRequestNavigateBack:(SXBrowserTab *)tab;
- (void)browserTabDidRequestNavigateForward:(SXBrowserTab *)tab;

/// Fired on the main thread when BrowserCore enforces a privacy protection or records a page visit.
- (void)browserTab:(SXBrowserTab *)tab didRecordPrivacyEvent:(SXPrivacyEvent *)event;

/// Fired on the main thread when Chromium's navigation history entry IDs change.
- (void)browserTab:(SXBrowserTab *)tab
    didUpdateNavigationEntryIDs:(NSInteger)currentID
                     previousID:(NSInteger)previousID
                         nextID:(NSInteger)nextID
                  validEntryIDs:(NSArray<NSNumber *> *)validIDs;

/// Fired on the main thread when a settled JPEG navigation snapshot is captured for `entryID`.
- (void)browserTab:(SXBrowserTab *)tab
    didUpdateNavigationSnapshotData:(NSData *)jpegData
                            entryID:(NSInteger)entryID
                        logicalSize:(NSSize)logicalSize
                       backingScale:(CGFloat)backingScale
                    backgroundColor:(nullable NSColor *)backgroundColor;

/// Fired on the main thread when the destination document is visually ready (BFCache pageshow or first paint).
- (void)browserTab:(SXBrowserTab *)tab
    didBecomeVisuallyReadyForNavigation:(BOOL)fromBFCache;

/// Fired on the main thread when the main frame's connection security state changes.
- (void)browserTab:(SXBrowserTab *)tab
    didUpdateConnectionSecurity:(SXConnectionSecurityState)state
                           host:(NSString *)host;

- (void)browserTabDidClose:(SXBrowserTab *)tab;

@end

#pragma mark - Browser Tab

/// A single Chromium web contents tab hosting `RenderWidgetHostViewCocoa` inside an AppKit `NSView`.
SX_EXPORT
@interface SXBrowserTab : NSObject

@property (nonatomic, readonly, copy) NSString *tabIdentifier;
@property (nonatomic, weak, nullable) id<SXBrowserTabDelegate> delegate;

/// The AppKit container view hosting Chromium's `RenderWidgetHostViewCocoa` (no Chrome toolbar/chrome UI).
@property (nonatomic, readonly, strong) NSView *contentView;

/// Pre-allocated AppKit container view hosting opener-preserving Sign in with Apple / OAuth popup WebContents.
@property (nonatomic, readonly, strong) NSView *authPopupContainerView;
@property (nonatomic, readonly) BOOL hasActiveAuthPopup;
@property (nonatomic, readonly, strong, nullable) NSURL *activeAuthPopupURL;

@property (nonatomic, readonly, strong, nullable) NSURL *currentURL;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, getter=isLoading) BOOL loading;
@property (nonatomic, readonly) double estimatedProgress;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly, strong, nullable) NSImage *favicon;
@property (nonatomic, readonly) SXConnectionSecurityState connectionSecurityState;
@property (nonatomic, readonly, copy, nullable) NSString *connectionSecurityHost;

/// Telemetry properties updated continuously from Chromium compositor / page metrics.
@property (nonatomic, readonly) CGFloat scrollY;
@property (nonatomic, readonly) CGFloat contentHeight;
@property (nonatomic, readonly) CGFloat viewportHeight;
@property (nonatomic, readonly) BOOL canInnerScrollUp;
@property (nonatomic, readonly) BOOL canInnerScrollDown;
@property (nonatomic, readonly) BOOL canScrollLeft;
@property (nonatomic, readonly) BOOL canScrollRight;
@property (nonatomic, readonly) BOOL pageConsumesPinchZoom;
@property (nonatomic, readonly) CGFloat pageScale;
@property (nonatomic, readonly) BOOL isScrolledToTop;
@property (nonatomic, readonly) CGFloat overscrollY;
@property (nonatomic, readonly, getter=isPullToRefreshArmed) BOOL pullToRefreshArmed;

/// Most recently captured preview or Retina snapshot of this tab (updated periodically in RAM while active and cleared on close).
@property (nonatomic, readonly, strong, nullable) NSImage *cachedSnapshot;

/// Pauses periodic background preview snapshot captures (e.g. while Tab Overview is open or animating).
@property (nonatomic, assign, getter=isPreviewSnapshotPaused) BOOL previewSnapshotPaused;

/// Monotonic Chromium navigation entry IDs for exact history-indexed swipe snapshots (0 when unavailable).
@property (nonatomic, readonly) NSInteger currentNavigationEntryID;
@property (nonatomic, readonly) NSInteger previousNavigationEntryID;
@property (nonatomic, readonly) NSInteger nextNavigationEntryID;
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *validNavigationEntryIDs;

/// Last reported page background color (used for resize-safe swipe underlay fill).
@property (nonatomic, readonly, strong, nullable) NSColor *pageBackgroundColor;

/// Most recently sampled top-edge color from rendered surface pixels (nil until first sample).
@property (nonatomic, readonly, strong, nullable) NSColor *lastSampledTopEdgeColor;

/// Active docked fixed/sticky top header bar color if the page currently has one (nil otherwise).
@property (nonatomic, readonly, strong, nullable) NSColor *fixedHeaderColor;

/// Enables automatic top-edge 2–4pt surface sampling on load completion, layout, and scroll settle. Defaults to YES.
@property (nonatomic, assign) BOOL automaticTopEdgeSamplingEnabled;

/// Top-edge strip height in points used for surface color sampling (clamped to 2.0–4.0pt). Defaults to 3.0pt.
@property (nonatomic, assign) CGFloat topEdgeSampleHeightPoints;

#pragma mark View Attachment & Lifecycle

/// Attaches `contentView` into `parentView` with full-bleed autoresizing constraints.
- (void)attachToParentView:(NSView *)parentView;

/// Detaches `contentView` from its current superview without destroying the Chromium WebContents.
- (void)detachFromParentView;

/// Marks this tab active/visible or background/hidden, synchronizing RenderWidgetHostViewCocoa
/// frame, visibility, screen info, and AppKit firstResponder focus so multi-tab input never stalls.
- (void)setTabActive:(BOOL)active;

/// Explicitly focuses Chromium's RenderWidgetHostViewCocoa and sets keyboard focus to web content.
- (void)focusWebContent;

/// Closes the underlying Chromium browser tab and releases resources.
- (void)closeTab;

#pragma mark Navigation

- (void)loadURL:(NSURL *)url;
- (void)loadURLString:(NSString *)urlString;
/// Prewarms DNS and TLS/QUIC sockets inside Chromium's NetworkContext for `url`'s origin
/// (no-op in Private Browsing or for non-HTTP(S) schemes).
- (void)prewarmOrigin:(NSURL *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)reloadIgnoringCache;
- (void)stopLoading;
/// Opens Chromium DevTools / Web Inspector for this tab.
- (void)showDevTools;
/// Evaluates a JavaScript snippet in the main frame.
/// Pixel-exact, full-resolution copy (IOSurfaceRef) of what this tab's web view shows: the active tab's page as it
/// is on screen now (nil while it has changed since the last copy), or a background tab's page as it last appeared.
/// Same copy that covers navigations and tab switches; use it for thumbnails so they match the screen exactly.
@property (nonatomic, readonly, nullable) id currentFrameSurface;
/// Size in points the surface covers (the web view's bounds when it was taken).
@property (nonatomic, readonly) NSSize currentFrameSize;
/// A layer that shows this tab's web content LIVE (videos and animations keep playing), mirroring Chromium's
/// GPU-composited layer with no copying. Its bounds are the web view's size in points and its sublayers are laid
/// out top-down; scale it with a transform to draw it smaller. Nil when the tab isn't rendering (hidden tabs are
/// not drawn by Chromium) or during a navigation. Stops updating if Chromium replaces its view (navigation).
- (nullable CALayer *)makeLiveContentMirrorLayer;
/// Takes a fresh exact copy now (~80-100 ms) and hands it back on the main thread (nil if the tab isn't on screen).
- (void)refreshCurrentFrameWithCompletion:(void (^)(id _Nullable surface, NSSize size))completion;

/// How far the page is inset below Safarium's toolbar (the web view runs behind the toolbar). Default 48.
/// Applied before the first paint of every document; changing it updates the current page too.
@property (nonatomic) CGFloat topContentInset;
- (void)executeJavaScript:(NSString *)script;
/// Evaluates a JavaScript snippet across the main frame and all subframes (and any active auth popup).
- (void)executeJavaScriptInAllFrames:(NSString *)script;
/// Evaluates a JavaScript snippet across all frames of the active Sign in with Apple / OAuth popup.
- (void)executeJavaScriptInAuthPopup:(NSString *)script;
/// Closes any active Sign in with Apple / OAuth child popup cleanly.
- (void)closeAuthPopup;
/// Opens the native print sheet for the current webpage.
- (void)printPage;
/// Exports the current webpage directly to a PDF file at `filePath`.
- (void)exportToPDFAtPath:(NSString *)filePath
               completion:(nullable void (^)(BOOL success))completion;
/// Retrieves the live serialized HTML source of the main frame without re-fetching from the network
/// and without triggering Chromium's download manager. Completion runs on the main thread.
- (void)getPageSourceWithCompletion:(void (^)(NSString * _Nullable htmlSource))completion;
/// Presents a native macOS NSSavePanel (sheet on `window`, or modal if nil) allowing the user to save
/// the current webpage as Page Source (.html) or PDF (.pdf) directly to disk without triggering
/// Chromium download events or download bar animations.
- (void)savePageWithPanelForWindow:(nullable NSWindow *)window
                        completion:(nullable void (^)(BOOL saved, NSURL * _Nullable savedURL))completion;
/// Mutes or unmutes audio playback for this tab.
- (void)setAudioMuted:(BOOL)muted;
- (BOOL)isAudioMuted;

#pragma mark Top-Edge Surface Color Sampling

/// Samples a thin 2–4pt strip at the top edge of the rendered Chromium compositor surface (strictly ignoring `<meta name="theme-color">`).
/// Completion is invoked on the main thread with the averaged sRGB `NSColor` and WCAG relative luminance [0, 1].
- (void)sampleTopEdgeColorWithStripHeightPoints:(CGFloat)stripHeightPoints
                                     completion:(void (^)(NSColor * _Nullable color, double relativeLuminance))completion;

#pragma mark Zoom, Pinch Scale, Downloads, Find, Snapshot

/// Layout zoom (Cmd+ / Cmd- / Cmd0).
- (void)setPageZoomFactor:(double)zoomFactor;
- (double)pageZoomFactor;

/// Programmatic visual-viewport scale setter (prefer native trackpad pinch handled
/// directly by Chromium's 120fps RenderWidgetHostViewCocoa compositor).
- (void)setPageScale:(CGFloat)scale;

/// Legacy no-op kept for ABI compatibility: live trackpad pinch-to-zoom is handled
/// natively at 120fps by Chromium's RenderWidgetHostViewCocoa without CDP interception.
- (CGFloat)applyPinchMagnification:(CGFloat)magnification
                           atPoint:(NSPoint)viewPoint
                        isPinching:(BOOL)isPinching;

/// Resets visual-viewport pinch scale back to 1.0 (e.g. for Cmd+0).
- (void)resetPageScale;

/// Applies Safari-style sub-1.0 rubber-band overshoot scale on the web content layer
/// when closing a pinch past 100% (`scale` in ~[0.78, 1.0]).
- (void)setPageOvershootScale:(CGFloat)scale;
- (void)setPageOvershootScale:(CGFloat)scale anchorPoint:(NSPoint)anchorPoint;

/// Releases page overshoot scale with a critically damped spring (`W = 16`, ~0.35s) back to 1.0.
- (void)endPageOvershoot;

/// Forwards macOS trackpad scroll gesture phases into the renderer's Safari rubber-band state machine.
/// (`SXEngineRuntime` also forwards these automatically for visible tabs.)
- (void)notifyScrollPhase:(SXScrollPhase)phase
    NS_SWIFT_NAME(notifyScrollPhase(_:));

/// Marks whether a scroll gesture or elastic rubber-band spring is actively running so
/// top-edge color readbacks never stall the GPU compositor mid-bounce.
- (void)setScrollInteractionActive:(BOOL)active;

/// Resets any active rubber-band overscroll offset back to 0 (e.g. after reload finishes).
- (void)resetOverscroll;

/// Initiates a real Chromium file download for `url` into `~/Downloads/` without blocking dialogs,
/// delivering progress callbacks via `SXBrowserTabDelegate`.
- (void)startDownloadAtURL:(NSURL *)url;

- (void)findText:(NSString *)searchText
         forward:(BOOL)forward
       matchCase:(BOOL)matchCase
        findNext:(BOOL)findNext;
- (void)stopFindingAndClearSelection:(BOOL)clearSelection;

/// Captures a crisp Retina snapshot of the rendered tab surface (for Tab Overview cards).
/// If the tab is currently hidden, returns `cachedSnapshot` if available.
- (void)captureSnapshotWithCompletion:(void (^)(NSImage * _Nullable image))completion;

@end

#pragma mark - Engine Runtime

/// Singleton runtime managing the Chromium (`chrome/` layer) lifecycle inside Safarium.
SX_EXPORT
@interface SXEngineRuntime : NSObject

+ (instancetype)sharedRuntime;

@property (nonatomic, readonly, getter=isInitialized) BOOL initialized;
@property (nonatomic, readonly, copy) NSString *chromiumVersion;
@property (nonatomic, readonly, copy) NSString *userAgent;
@property (nonatomic, readonly, copy) NSString *profileDirectory;
/// Active Chrome DevTools Protocol (CDP) remote debugging port for this session, or 0 when disabled.
@property (nonatomic, readonly) NSInteger activeRemoteDebuggingPort;
/// True when the Chromium remote debugging server is actively listening for this session.
@property (nonatomic, readonly, getter=isRemoteDebuggingActive) BOOL remoteDebuggingActive;
/// Path to `<profileDirectory>/DevToolsActivePort` written by Chromium when remote debugging is active.
@property (nonatomic, readonly, copy, nullable) NSString *devToolsActivePortFilePath;
/// Live browser-level CDP WebSocket URL (e.g. `ws://127.0.0.1:9222/devtools/browser/<guid>`) read from `DevToolsActivePort`.
@property (nonatomic, readonly, copy, nullable) NSString *remoteDebuggingWebSocketURL;

/// Opens a Chromium DevTools inspector window attached to a remote CDP target WebSocket URL
/// (e.g. `ws://127.0.0.1:9222/devtools/page/...` or `ws://127.0.0.1:9229/...`).
- (void)openDevToolsForRemoteWebSocketURL:(NSString *)wsURL;

/// Installs macOS `CrAppProtocol` (`isHandlingSendEvent` / `setHandlingSendEvent:`) hooks on `NSApp`
/// so Chromium's event loop integrates seamlessly with any Swift/AppKit `NSApplication`.
/// Call before `[NSApplication sharedApplication]` starts running, or `initializeWithConfiguration:error:` will install it automatically.
+ (void)installApplicationProtocolHooks;

/// Initializes the Chromium `chrome/` runtime (persistent profile, no automation/webdriver flags, Chrome browser layer).
/// Must be called on the main thread before creating tabs.
- (BOOL)initializeWithConfiguration:(nullable SXEngineConfiguration *)configuration
                              error:(NSError * _Nullable * _Nullable)error;

/// Shuts down all open tabs and cleanly flushes the Chromium profile to disk.
/// Call from `applicationWillTerminate:`.
- (void)shutdown;

/// Pumps pending Chromium message loop work (automatically driven by an internal run-loop observer/timer;
/// callers may also invoke manually if desired).
- (void)pumpMessageLoopWork;

/// Creates a new Chromium tab (`RenderWidgetHostViewCocoa` without Chrome toolbar/window chrome)
/// attached to `parentView` (if non-nil) and begins loading `initialURL` (if non-nil).
- (nullable SXBrowserTab *)createTabWithInitialURL:(nullable NSURL *)initialURL
                                        parentView:(nullable NSView *)parentView
                                          delegate:(nullable id<SXBrowserTabDelegate>)delegate;

/// Creates a new Chromium tab in either the persistent profile (`incognito == NO`) or an isolated
/// in-memory Off-The-Record / Incognito `CefRequestContext` (`incognito == YES`).
- (nullable SXBrowserTab *)createTabWithInitialURL:(nullable NSURL *)initialURL
                                        parentView:(nullable NSView *)parentView
                                          delegate:(nullable id<SXBrowserTabDelegate>)delegate
                                         incognito:(BOOL)incognito;

/// Drops the shared in-memory Incognito `CefRequestContext` (called when the last Private Window closes)
/// so cookies, storage, and session data are completely wiped before the next Private Window opens.
- (void)resetIncognitoSession;

/// Returns all currently active tabs.
- (NSArray<SXBrowserTab *> *)activeTabs;

/// Cancels an active download by ID.
- (void)cancelDownloadWithID:(uint32_t)downloadID;
/// Pauses an active download by ID.
- (void)pauseDownloadWithID:(uint32_t)downloadID;
/// Resumes a paused download by ID. Returns YES if a resumable callback existed.
- (BOOL)resumeDownloadWithID:(uint32_t)downloadID;

/// Applies live Chromium profile preferences (JavaScript, Safe Browsing, cookies, min font size,
/// default encoding, downloads, autofill, developer mode) to the running request context.
- (void)applyPreferences:(NSDictionary<NSString *, id> *)preferences;

/// Clears stored website cookies and browser storage across the profile.
- (void)clearWebsiteDataWithCompletion:(nullable void (^)(BOOL success))completion;

/// Atomically updates BrowserCore's privacy policy and broadcasts renderer config updates to active tabs.
- (void)syncPrivacyPolicy:(NSDictionary<NSString *, id> *)policy;

/// Inspects stored website cookies per domain on the persistent profile.
- (void)fetchWebsiteDataRecordsWithCompletion:(void (^)(NSArray<SXWebsiteDataRecord *> *records))completion;

/// Deletes stored cookies for the specified domains and flushes the cookie store.
- (void)removeWebsiteDataForDomains:(NSArray<NSString *> *)domains
                         completion:(nullable void (^)(BOOL success))completion;

/// Allows insecure HTTP for `host` in this session without auto-upgrading to HTTPS.
- (void)allowInsecureHTTPForHost:(NSString *)host;

#pragma mark Chrome Web Store MV3 Extensions

/// Delegate notified on the main thread whenever extensions are installed, uninstalled, or updated.
@property (nonatomic, weak, nullable) id<SXEngineExtensionDelegate> extensionDelegate;

/// Returns all currently installed MV3 extensions in the persistent Safarium profile.
- (NSArray<SXExtensionItem *> *)installedExtensions;

/// Loads an unpacked MV3 extension folder into persistent storage and live Chromium ExtensionSystem.
- (void)loadUnpackedExtensionAtPath:(NSString *)directoryPath
                         completion:(nullable void (^)(SXExtensionItem * _Nullable item,
                                                       NSError * _Nullable error))completion;

/// Unpacks and installs a local `.crx` (CRX3/CRX2) or `.zip` extension into persistent storage and live Chromium.
- (void)installExtensionFromCRXAtPath:(NSString *)crxPath
                           completion:(nullable void (^)(SXExtensionItem * _Nullable item,
                                                         NSError * _Nullable error))completion;

/// Downloads and installs a real MV3 extension from Chrome Web Store by its 32-character store ID
/// into persistent storage and live Chromium ExtensionSystem.
- (void)installExtensionFromChromeWebStoreID:(NSString *)storeID
                                  completion:(nullable void (^)(SXExtensionItem * _Nullable item,
                                                                NSError * _Nullable error))completion;

/// Uninstalls an extension by runtime `extensionID` or Chrome Web Store `storeID`.
- (void)uninstallExtensionWithID:(NSString *)extensionID
                      completion:(nullable void (^)(BOOL success,
                                                    NSError * _Nullable error))completion;

/// Enables or disables an installed extension live in Chromium and persists the state.
- (void)setExtensionWithID:(NSString *)extensionID
                   enabled:(BOOL)enabled
                completion:(nullable void (^)(BOOL success,
                                              NSError * _Nullable error))completion;

/// Updates whether an installed extension is allowed to run in Private / Incognito windows.
- (void)setExtensionWithID:(NSString *)extensionID
            allowInPrivate:(BOOL)allowInPrivate
                completion:(nullable void (^)(BOOL success,
                                              NSError * _Nullable error))completion;

/// Clears persisted extension storage (chrome.storage / IndexedDB) and reloads the extension.
- (void)clearStorageForExtensionWithID:(NSString *)extensionID
                            completion:(nullable void (^)(BOOL success,
                                                          NSError * _Nullable error))completion;

/// Creates an AppKit `NSView` rendering the real Chromium `chrome-extension://<id>/<popup.html>`
/// page inside `parentView` (if non-nil) for hosting inside a native Liquid Glass popover/panel.
- (nullable NSView *)createExtensionPopupViewForExtensionID:(NSString *)extensionID
                                                      width:(CGFloat)width
                                                     height:(CGFloat)height
                                                 parentView:(nullable NSView *)parentView;

/// Closes an active extension popup view for `extensionID` (or all active popups if nil).
- (void)closeExtensionPopupForExtensionID:(nullable NSString *)extensionID;

/// Returns the live `chrome.contextMenus` hierarchy registered by `extensionID`.
- (NSArray<SXExtensionContextMenuItem *> *)contextMenuItemsForExtensionID:(NSString *)extensionID;

/// Triggers a live `chrome.contextMenus.onClicked` callback in `extensionID`'s service worker.
- (void)triggerContextMenuItemWithID:(NSString *)menuItemID
                      forExtensionID:(NSString *)extensionID
                             pageURL:(nullable NSURL *)pageURL;

@end

NS_ASSUME_NONNULL_END
