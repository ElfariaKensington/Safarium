// SXApp.mm
// Browser-process CefApp implementation with strict anti-guardrail compliance
// and native AppKit message-pump integration.

#import "SXApp.h"
#import "SXInternal.h"
#import "SXMediaTranscodeServer.h"
#import "SXPrivacyEngine.h"

#include "include/base/cef_callback.h"
#include "include/cef_client.h"
#include "include/cef_display_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_helpers.h"

#import <AppKit/AppKit.h>
#include <mutex>
#include <unordered_set>

namespace {

static void SXHideRogueWindow(CefRefPtr<CefBrowser> browser) {
  if (!browser || !browser->GetHost()) return;
  NSView *v = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
  if (v && v.window) {
    NSWindow *w = v.window;
    [w setAlphaValue:0.0];
    [w orderOut:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (w.isVisible) {
        [w setAlphaValue:0.0];
        [w orderOut:nil];
      }
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
      if (url) {
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
    if (!browser) return;
    std::lock_guard<std::mutex> lock(mu_);
    forwarded_ids_.erase(browser->GetIdentifier());
  }

 private:
  std::mutex mu_;
  std::unordered_set<int> forwarded_ids_;
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
  // Allow native AppKit NSGlassEffectView video HUD buttons to call HTMLMediaElement.play() reliably.
  command_line->AppendSwitchWithValue("autoplay-policy", "no-user-gesture-required");

  // Enforce Safari-grade process-per-tab / strict site & origin isolation so each website
  // (e.g. reddit.com, google.com) runs in its own dedicated OS renderer process in Activity Monitor.
  command_line->AppendSwitch("site-per-process");
  command_line->AppendSwitch("origin-keyed-processes-by-default");

  // Keep Chromium BackForwardCache + PaintHolding (same-origin AND cross-origin) + Prerender2 active
  // for zero-flash Back/Forward, Speculation Rules prerender/prefetch, and link navigations,
  // and enable ThirdPartyStoragePartitioning + PartitionedCookies.
  command_line->AppendSwitchWithValue("enable-features", "BackForwardCache:enable_same_site/true/all_extensions_allowed/true/TimeToLiveInBackForwardCacheInSeconds/600,BackForwardCacheMemoryControls,AllowPageWithIDBConnectionInBFCache,PaintHolding,PaintHoldingCrossOrigin,Prerender2,WebAuthenticationPasskeys,WebAuthenticationMacPlatformAuthenticator,ThirdPartyStoragePartitioning,PartitionedCookies");

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
