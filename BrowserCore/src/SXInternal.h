// SXInternal.h
// Private Objective-C++ declarations shared across BrowserCore implementation files.

#pragma once

#import "SafariumEngineBridge.h"

#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_download_handler.h"

#include <functional>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SXDevToolsDockMode) {
  SXDevToolsDockBottom = 0,
  SXDevToolsDockLeft = 1,
  SXDevToolsDockRight = 2,
  SXDevToolsDockSeparate = 3,
};


@interface SXPrivacyEvent (Internal)
- (instancetype)initWithEventType:(NSString *)eventType
                         pageHost:(NSString *)pageHost
                      trackerHost:(NSString *)trackerHost
                     entityDomain:(NSString *)entityDomain
                        ownerName:(NSString *)ownerName
                         category:(NSString *)category
                           detail:(NSString *)detail
                            count:(NSInteger)count
                        isPrivate:(BOOL)isPrivate
                        timestamp:(NSTimeInterval)timestamp;
@end

@interface SXWebsiteDataRecord (Internal)
- (instancetype)initWithDomain:(NSString *)domain
                   cookieCount:(NSInteger)cookieCount
                    hasCookies:(BOOL)hasCookies
                      hasCache:(BOOL)hasCache;
@end

@interface SXDownloadItem (Internal)
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
                            paused:(BOOL)paused;
@end

class SXBrowserClient;

@interface SXBrowserTab (Internal)
- (instancetype)initWithRuntime:(SXEngineRuntime *)runtime
                     initialURL:(nullable NSURL *)initialURL
                     parentView:(nullable NSView *)parentView
                       delegate:(nullable id<SXBrowserTabDelegate>)delegate;

- (void)createChromiumBrowserIfNeeded;
- (void)handleBrowserCreated:(CefRefPtr<CefBrowser>)browser;
- (void)handleBrowserClosing;
- (void)handleBrowserClosed;

- (void)handleURLChanged:(NSURL *)url;
- (void)handleTitleChanged:(NSString *)title;
- (void)handleLoadingStateChanged:(BOOL)isLoading
                        canGoBack:(BOOL)canGoBack
                     canGoForward:(BOOL)canGoForward;
- (void)handleProgressChanged:(double)progress;
- (void)handleFaviconLoaded:(nullable NSImage *)favicon;
- (void)handleFaviconLoaded:(nullable NSImage *)favicon forGeneration:(NSUInteger)generation;
- (NSUInteger)currentFaviconGeneration;
- (void)handleMainFrameLoadStart;
- (void)handleMainFrameNavigationWillStart;
- (void)handleMainFrameResponseReceived;
- (void)handleMainFrameLoadEnd:(int)httpStatusCode;
- (void)handleMainFrameLoadError:(NSInteger)errorCode
                       errorText:(NSString *)errorText
                       failedURL:(NSURL *)failedURL;
- (void)handleSpaceScrollDirection:(int)direction isRepeat:(BOOL)isRepeat;
- (void)handleKeyboardNavigateBack;
- (void)handleKeyboardNavigateForward;
- (void)handleTelemetryScrollY:(CGFloat)scrollY
                 contentHeight:(CGFloat)contentHeight
                     pageScale:(CGFloat)pageScale
                    isPinching:(BOOL)isPinching
                viewportHeight:(CGFloat)viewportHeight
              canInnerScrollUp:(BOOL)canInnerScrollUp
            canInnerScrollDown:(BOOL)canInnerScrollDown
                 canScrollLeft:(BOOL)canScrollLeft
                canScrollRight:(BOOL)canScrollRight
         pageConsumesPinchZoom:(BOOL)pageConsumesPinchZoom;
- (void)handleOverscrollY:(CGFloat)overscrollY armed:(BOOL)armed;
- (void)handlePullToRefreshTriggered;
- (void)handleFixedHeaderColor:(nullable NSColor *)color;
- (void)handlePageBackgroundColor:(NSColor *)color;
- (void)handleNavigationEntriesCurrentID:(NSInteger)currentID
                              previousID:(NSInteger)previousID
                                  nextID:(NSInteger)nextID
                           validEntryIDs:(NSArray<NSNumber *> *)validIDs;
- (void)handleNavigationVisuallyReadyFromBFCache:(BOOL)fromBFCache;
- (void)handleScriptTraverseNavigation;
- (void)handleNativeVideoID:(NSString *)videoID
                     srcURL:(NSString *)srcURL
                       rect:(NSRect)rect
                    visible:(BOOL)visible
                   autoplay:(BOOL)autoplay;
- (void)handleAuthEventJSON:(NSString *)jsonString;
- (BOOL)hasRecentAppleSignInIntent;
- (CefRefPtr<CefClient>)prepareAuthPopupClientWithInitialURL:(nullable NSURL *)url;
- (void)handleAuthPopupBrowserCreated:(CefRefPtr<CefBrowser>)browser;
- (void)handleAuthPopupURLChanged:(NSURL *)url;
- (void)handleAuthPopupClosed:(CefRefPtr<CefBrowser>)browser;
- (void)handleDownloadStarted:(SXDownloadItem *)item;
- (void)handleDownloadUpdated:(SXDownloadItem *)item;
- (nullable SXBrowserTab *)handlePopupRequestURL:(NSURL *)url
                                     userGesture:(BOOL)userGesture;
- (void)handleHostViewVisibilityChanged:(BOOL)hidden;
- (void)handleHostViewFrameChanged;
- (int)chromiumBrowserIdentifier;
- (void)showDevToolsAtPoint:(NSPoint)point;
- (void)closeDevTools;
- (void)handleDevToolsClosed;
- (void)syncDockedDevToolsWindowFrame;
- (void)setDevToolsDockMode:(SXDevToolsDockMode)mode;
- (BOOL)isPrivateBrowsing;
- (void)handlePrivacyEvent:(SXPrivacyEvent *)event;
- (void)handleConnectionSecurityState:(SXConnectionSecurityState)state host:(NSString *)host;
- (void)sendPrivacyConfigUpdateDictionary:(CefRefPtr<CefDictionaryValue>)configDict;
@end

@interface SXExtensionContextMenuItem (Internal)
- (instancetype)initWithItemID:(NSString *)itemID
                      parentID:(nullable NSString *)parentID
                         title:(NSString *)title
                     separator:(BOOL)separator
                       enabled:(BOOL)enabled
                       checked:(BOOL)checked
                      children:(NSArray<SXExtensionContextMenuItem *> *)children;
@end

@interface SXExtensionItem (Internal)
- (instancetype)initWithExtensionID:(NSString *)extensionID
                            storeID:(nullable NSString *)storeID
                               name:(NSString *)name
                            version:(NSString *)version
               extensionDescription:(nullable NSString *)extensionDescription
                               icon:(nullable NSImage *)icon
                          badgeText:(nullable NSString *)badgeText
                         badgeColor:(nullable NSColor *)badgeColor
                           popupURL:(nullable NSURL *)popupURL
                        installPath:(NSString *)installPath
                            enabled:(BOOL)enabled
                     allowInPrivate:(BOOL)allowInPrivate;
@end

@interface SXEngineRuntime (Internal)
- (BOOL)isContextInitialized;
- (void)markContextInitialized;
- (void)scheduleMessagePumpWorkWithDelayMs:(int64_t)delayMs;
- (void)registerDownloadCallback:(CefRefPtr<CefDownloadItemCallback>)callback
                   forDownloadID:(uint32_t)downloadID;
- (void)unregisterDownloadCallbackForDownloadID:(uint32_t)downloadID;
- (void)tabDidClose:(SXBrowserTab *)tab;
- (void)noteBrowserCreated;
- (void)noteBrowserClosed;
- (NSInteger)liveBrowserCount;
- (NSArray<NSString *> *)startupExtensionDirectories;
- (void)notifyExtensionsUpdated;
- (void)postNewTabRequestForURL:(NSURL *)url;
- (void)postNewWindowRequestForURL:(NSURL *)url;
- (BOOL)isChromeWebStoreExtensionInstalled:(NSString *)storeID;
- (void)dispatchPrivacyEvent:(SXPrivacyEvent *)event forTab:(nullable SXBrowserTab *)tab;
@end

CefRefPtr<CefDictionaryValue> SXBuildPrivacyExtraInfoDictionary(bool isPrivate);
CefRefPtr<CefDictionaryValue> SXBuildPrivacyConfigUpdateDictionary(bool isPrivate = false);

NS_ASSUME_NONNULL_END
