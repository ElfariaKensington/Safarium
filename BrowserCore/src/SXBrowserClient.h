// SXBrowserClient.h
// Per-tab CefClient handling lifecycle, display, load, favicon, downloads,
// direct compositor surface readback, and renderer telemetry IPC.

#pragma once

#import "SafariumEngineBridge.h"
#import <Foundation/Foundation.h>

#include "include/cef_client.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_display_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_focus_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_resource_request_handler.h"

#include <atomic>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>

@class SXBrowserTab;

class SXBrowserClient : public CefClient,
                        public CefLifeSpanHandler,
                        public CefDisplayHandler,
                        public CefLoadHandler,
                        public CefContextMenuHandler,
                        public CefDownloadHandler,
                        public CefFocusHandler,
                        public CefJSDialogHandler,
                        public CefKeyboardHandler,
                        public CefPermissionHandler,
                        public CefRequestHandler,
                        public CefResourceRequestHandler,
                        public CefCookieAccessFilter,
                        public CefDevToolsMessageObserver {
 public:
  explicit SXBrowserClient(SXBrowserTab* tab);
  ~SXBrowserClient() override;

  void DetachTab();

  // Direct read-only Chromium compositor surface readback (CopyFromSurface) without
  // CDP `clip` or `DeviceEmulationParams` mutation, remote debugging, or Runtime.enable.
  void CaptureSurfaceForTopEdgeSample(
      std::function<void(const std::string& imageBytes)> callback);

  void CaptureFullSnapshotPNG(
      double widthPoints,
      double heightPoints,
      std::function<void(const std::string& pngBytes)> callback);

  // Full-resolution, lossless capture of the page as it is on screen right now, jumped to the front of the
  // capture queue. Used as the freeze frame that covers Chromium's view swap during a navigation.
  void CaptureFreezeFramePNG(std::function<void(const std::string& pngBytes)> callback,
                             bool priority = true);

  // Fast, low-overhead JPEG surface capture for periodic RAM-cached Tab Overview previews.
  // Never passes `clip` or `scale != 1.0` so Chromium's viewport scale is never mutated.
  void CapturePreviewSnapshotJPEG(
      std::function<void(const std::string& jpegBytes)> callback);

  // Visual-viewport pinch scale control via Chromium compositor (Emulation.setPageScaleFactor).
  void SetPageScaleFactor(double scale);
  void ResetPageScaleFactor();

  // Thread-safe state mirrored from UI thread for TID_IO resource filtering.
  void SetDevToolsOpen(bool open) { devtools_open_.store(open, std::memory_order_relaxed); }

  // CefClient:
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override;

  // CefLifeSpanHandler:
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
                     bool* no_javascript_access) override;
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;

  // CefDisplayHandler:
  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override;
  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString& title) override;
  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                          const std::vector<CefString>& icon_urls) override;
  void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser,
                               double progress) override;

  // CefLoadHandler:
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool isLoading,
                            bool canGoBack,
                            bool canGoForward) override;
  void OnLoadStart(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   TransitionType transition_type) override;
  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int httpStatusCode) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString& errorText,
                   const CefString& failedUrl) override;

  // CefContextMenuHandler:
  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override;
  bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser,
                            CefRefPtr<CefFrame> frame,
                            CefRefPtr<CefContextMenuParams> params,
                            int command_id,
                            EventFlags event_flags) override;

  // CefDownloadHandler:
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDownloadItem> download_item,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override;
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override;

  // CefFocusHandler:
  bool OnSetFocus(CefRefPtr<CefBrowser> browser, FocusSource source) override;

  // CefKeyboardHandler:
  bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser,
                     const CefKeyEvent& event,
                     CefEventHandle os_event,
                     bool* is_keyboard_shortcut) override;

  // CefPermissionHandler:
  bool OnRequestMediaAccessPermission(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      const CefString& requesting_origin,
      uint32_t requested_permissions,
      CefRefPtr<CefMediaAccessCallback> callback) override;
  bool OnShowPermissionPrompt(
      CefRefPtr<CefBrowser> browser,
      uint64_t prompt_id,
      const CefString& requesting_origin,
      uint32_t requested_permissions,
      CefRefPtr<CefPermissionPromptCallback> callback) override;

  // CefRequestHandler:
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override;
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,
      bool is_navigation,
      bool is_download,
      const CefString& request_initiator,
      bool& disable_default_handling) override;
  bool OnCertificateError(CefRefPtr<CefBrowser> browser,
                          cef_errorcode_t cert_error,
                          const CefString& request_url,
                          CefRefPtr<CefSSLInfo> ssl_info,
                          CefRefPtr<CefCallback> callback) override;
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        const CefString& target_url,
                        WindowOpenDisposition target_disposition,
                        bool user_gesture) override;

  // CefResourceRequestHandler:
  CefRefPtr<CefCookieAccessFilter> GetCookieAccessFilter(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request) override;
  bool OnResourceResponse(CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefFrame> frame,
                          CefRefPtr<CefRequest> request,
                          CefRefPtr<CefResponse> response) override;
  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request,
                                   CefRefPtr<CefCallback> callback) override;
  CefRefPtr<CefResourceHandler> GetResourceHandler(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request) override;
  void OnResourceRedirect(CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefFrame> frame,
                          CefRefPtr<CefRequest> request,
                          CefRefPtr<CefResponse> response,
                          CefString& new_url) override;

  // CefCookieAccessFilter:
  bool CanSendCookie(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     CefRefPtr<CefRequest> request,
                     const CefCookie& cookie) override;
  bool CanSaveCookie(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     CefRefPtr<CefRequest> request,
                     CefRefPtr<CefResponse> response,
                     const CefCookie& cookie) override;

  // CefJSDialogHandler:
  bool OnJSDialog(CefRefPtr<CefBrowser> browser,
                  const CefString& origin_url,
                  JSDialogType dialog_type,
                  const CefString& message_text,
                  const CefString& default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback,
                  bool& suppress_message) override;
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                            const CefString& message_text,
                            bool is_reload,
                            CefRefPtr<CefJSDialogCallback> callback) override;

  // CefDevToolsMessageObserver:
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                              int message_id,
                              bool success,
                              const void* result,
                              size_t result_size) override;
  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser> browser) override;

 private:
  struct PendingCapture {
    CefRefPtr<CefDictionaryValue> params;
    std::function<void(const std::string&)> callback;
  };

  void EnsureDevToolsObserverRegistered(CefRefPtr<CefBrowser> browser);
  void ScheduleDevToolsDetachIfIdle();
  void ExecuteCaptureRequest(CefRefPtr<CefDictionaryValue> params,
                             std::function<void(const std::string& pngBytes)> callback,
                             bool priority = false);
  void StartNextCaptureIfIdle();
  void TimeoutCaptureIfStillInFlight(int reqId);

  __weak SXBrowserTab* tab_ = nil;
  mutable std::mutex tab_mutex_;
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<CefRegistration> devtools_registration_;

  std::mutex pending_mutex_;
  std::atomic<int> next_devtools_id_{100};
  std::atomic<bool> is_incognito_{false};
  std::atomic<bool> devtools_open_{false};
  std::string force_save_dialog_url_;
  std::unordered_map<uint32_t, std::string> pending_save_dialog_downloads_;
  std::unordered_set<uint32_t> started_download_ids_;
  std::unordered_map<int, std::pair<std::string, std::string>> ext_menu_commands_;
  std::mutex css_cache_mutex_;
  std::string cached_css_path_;
  double cached_css_mtime_ = 0.0;
  std::string cached_css_json_arr_;
  int inflight_capture_id_ = 0;
  std::function<void(const std::string&)> inflight_capture_callback_;
  std::deque<PendingCapture> capture_queue_;

  std::mutex nav_privacy_mutex_;
  std::string committed_main_url_;
  std::string last_cert_error_url_;
  std::string suppressed_fallback_error_url_;
  std::string upgraded_committed_url_;
  std::unordered_map<std::string, std::string> pending_upgraded_urls_;
  std::unordered_set<std::string> reported_cookie_blocks_;
  std::unordered_set<std::string> bounce_redirector_hosts_;

  SXBrowserTab* RetainTab() const;
  void EmitPrivacyEventOnMainThread(const std::string& event_type,
                                    const std::string& page_host,
                                    const std::string& tracker_host,
                                    const std::string& entity_domain,
                                    const std::string& owner_name,
                                    const std::string& category,
                                    const std::string& detail,
                                    NSInteger count);
  void UpdateConnectionSecurityForMainURL(const std::string& url,
                                          SXConnectionSecurityState* explicit_state = nullptr);
  std::string ResolveCurrentPageURL(CefRefPtr<CefBrowser> browser, CefRefPtr<CefRequest> request);
  bool EvaluateCookieAccess(CefRefPtr<CefBrowser> browser,
                            CefRefPtr<CefFrame> frame,
                            CefRefPtr<CefRequest> request,
                            CefRefPtr<CefResponse> response,
                            bool is_save);

  IMPLEMENT_REFCOUNTING(SXBrowserClient);
};
