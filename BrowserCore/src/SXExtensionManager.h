// SXExtensionManager.h
// Manages persistent Chromium MV3 extensions (Chrome Web Store CRX3, unpacked, .crx/.zip),
// live hot-loading via Chromium 156 Extensions.loadUnpacked/uninstall, and real
// chrome-extension:// popup NSViews.

#pragma once

#import "SafariumEngineBridge.h"
#include "include/cef_browser.h"

NS_ASSUME_NONNULL_BEGIN

@interface SXExtensionManager : NSObject

+ (instancetype)sharedManager;

/// Configures persistent storage under `<profileDir>/SafariumExtensions/`.
/// Must be called before `CefInitialize` so `startupExtensionDirectories` is populated.
- (void)configureWithProfileDirectory:(NSString *)profileDirectory;

/// Returns comma-joinable absolute paths of all enabled extensions to pass via `--load-extension`.
- (NSArray<NSString *> *)startupExtensionDirectories;

/// Returns current list of installed extensions with resolved icons, localized names, and `chrome-extension://` popup URLs.
- (NSArray<SXExtensionItem *> *)installedExtensions;

- (nullable SXExtensionItem *)extensionWithIDOrStoreID:(NSString *)identifier;
- (BOOL)isStoreIDInstalled:(NSString *)storeID;
- (BOOL)isStoreIDBusy:(NSString *)storeID;

- (void)loadUnpackedExtensionAtPath:(NSString *)directoryPath
                         completion:(nullable void (^)(SXExtensionItem * _Nullable item,
                                                       NSError * _Nullable error))completion;

- (void)installExtensionFromCRXAtPath:(NSString *)crxPath
                           completion:(nullable void (^)(SXExtensionItem * _Nullable item,
                                                         NSError * _Nullable error))completion;

- (void)installExtensionFromChromeWebStoreID:(NSString *)storeID
                                  completion:(nullable void (^)(SXExtensionItem * _Nullable item,
                                                                NSError * _Nullable error))completion;

- (void)uninstallExtensionWithID:(NSString *)extensionID
                      completion:(nullable void (^)(BOOL success,
                                                    NSError * _Nullable error))completion;

- (void)setExtensionWithID:(NSString *)extensionID
                   enabled:(BOOL)enabled
                completion:(nullable void (^)(BOOL success,
                                              NSError * _Nullable error))completion;

- (void)setExtensionWithID:(NSString *)extensionID
            allowInPrivate:(BOOL)allowInPrivate
                completion:(nullable void (^)(BOOL success,
                                              NSError * _Nullable error))completion;

- (void)clearStorageForExtensionWithID:(NSString *)extensionID
                            completion:(nullable void (^)(BOOL success,
                                                          NSError * _Nullable error))completion;

- (nullable NSView *)createPopupViewForExtensionID:(NSString *)extensionID
                                             width:(CGFloat)width
                                            height:(CGFloat)height
                                        parentView:(nullable NSView *)parentView;

- (void)closePopupForExtensionID:(nullable NSString *)extensionID;
- (void)closeAllPopups;
- (void)openPopoutWindowForExtensionID:(NSString *)extensionID
                                   url:(NSURL *)url
                                 width:(CGFloat)width
                                height:(CGFloat)height
                                  left:(CGFloat)left
                                   top:(CGFloat)top;
- (void)closePopoutWindow:(NSWindow *)window;
- (void)closeAllPopoutWindows;
- (void)shutdown;

/// Registers a live CefBrowser used to execute Chromium `Extensions.loadUnpacked` / `Extensions.uninstall`.
- (void)registerActiveBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)unregisterActiveBrowser:(CefRefPtr<CefBrowser>)browser;

/// Notifies the extension manager when the active visible tab changes so per-tab badges refresh immediately.
- (void)notifyActiveTabChanged;

/// Returns live `chrome.contextMenus` items registered by `extensionID`.
- (NSArray<SXExtensionContextMenuItem *> *)contextMenuItemsForExtensionID:(NSString *)extensionID;

/// Dispatches a `chrome.contextMenus.onClicked` event to `extensionID`'s service worker.
- (void)triggerContextMenuItemWithID:(NSString *)menuItemID
                      forExtensionID:(NSString *)extensionID
                             pageURL:(nullable NSURL *)pageURL;

@end

NS_ASSUME_NONNULL_END
