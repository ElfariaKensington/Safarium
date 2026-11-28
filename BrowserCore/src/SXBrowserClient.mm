// SXBrowserClient.mm
// Per-tab CefClient implementation for Safarium BrowserCore.

#import "SXBrowserClient.h"
#import "SXExtensionManager.h"
#import "SXInternal.h"
#import "SXMediaTranscodeServer.h"
#import "SXPrivacyEngine.h"

#include "include/base/cef_callback.h"
#include "include/cef_image.h"
#include "include/cef_parser.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_helpers.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <cstring>
#include <vector>

@interface SXVideoMenuTarget : NSObject
@property (nonatomic, assign) double rate;
@property (nonatomic, assign) BOOL isStatsToggle;
@property (nonatomic, copy) void (^onPick)(double rate, BOOL isStatsToggle);
- (void)picked:(id)sender;
@end

@implementation SXVideoMenuTarget
- (void)picked:(id)sender {
  (void)sender;
  if (self.onPick) {
    self.onPick(self.rate, self.isStatsToggle);
  }
}
@end

namespace {

NSString* NSStringFromCefString(const CefString& str) {
  std::string utf8 = str.ToString();
  return [NSString stringWithUTF8String:utf8.c_str()] ?: @"";
}

SXDownloadItem* BuildDownloadItem(CefRefPtr<CefDownloadItem> item,
                                  const CefString& overrideSuggestedName,
                                  NSString* _Nullable overrideFullPath) {
  NSString* suggested = overrideSuggestedName.empty()
                            ? NSStringFromCefString(item->GetSuggestedFileName())
                            : NSStringFromCefString(overrideSuggestedName);
  NSString* fullPath = overrideFullPath;
  if (!fullPath && !item->GetFullPath().empty()) {
    fullPath = NSStringFromCefString(item->GetFullPath());
  }
  if (suggested.length == 0 && fullPath.length > 0) {
    suggested = [fullPath lastPathComponent];
  }
  NSString* urlString = NSStringFromCefString(item->GetURL());
  NSURL* url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
  if (suggested.length == 0 && url.lastPathComponent.length > 0 && ![url.lastPathComponent isEqualToString:@"/"]) {
    suggested = url.lastPathComponent;
  }

  int64_t totalBytes = item->GetTotalBytes();
  int64_t receivedBytes = item->GetReceivedBytes();
  int32_t pct = item->GetPercentComplete();
  if (pct < 0 && totalBytes > 0) {
    pct = (int32_t)std::min<int64_t>(100, (receivedBytes * 100) / totalBytes);
  }
  BOOL isComplete = item->IsComplete() ? YES : NO;
  BOOL isPaused = item->IsPaused() ? YES : NO;
  BOOL isCanceled = (!isComplete && !isPaused && (item->IsCanceled() || item->IsInterrupted())) ? YES : NO;
  BOOL isInProgress = (item->IsInProgress() && !isPaused && !isCanceled && !isComplete) ? YES : NO;
  if (isComplete) {
    pct = 100;
  }

  return [[SXDownloadItem alloc] initWithDownloadID:item->GetId()
                                  suggestedFileName:suggested
                                           fullPath:fullPath
                                                url:url
                                         totalBytes:totalBytes
                                      receivedBytes:receivedBytes
                                    percentComplete:pct
                                         inProgress:isInProgress
                                           complete:isComplete
                                           canceled:isCanceled
                                             paused:isPaused];
}

static NSString* NormalizedHostFromURLString(NSString* urlStr) {
  NSURL* url = urlStr.length > 0 ? [NSURL URLWithString:urlStr] : nil;
  NSString* host = url.host.lowercaseString;
  if (host.length == 0) return @"";
  if ([host hasPrefix:@"www."]) {
    host = [host substringFromIndex:4];
  }
  return host;
}

static NSInteger SitePolicyIndexForCategory(NSString* category, NSString* host, NSInteger defaultIdx) {
  NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
  if (host.length > 0) {
    NSString* hostKey = [NSString stringWithFormat:@"Safarium.SitePolicy.%@.%@", category, host];
    if ([ud objectForKey:hostKey] != nil) {
      return [ud integerForKey:hostKey];
    }
  }
  NSString* globalKey = [NSString stringWithFormat:@"Safarium.SiteDefault.%@", category];
  if ([ud objectForKey:globalKey] != nil) {
    return [ud integerForKey:globalKey];
  }
  return defaultIdx;
}

NSString* UniqueDownloadPath(NSString* suggestedName) {
  NSString* sanitized = [suggestedName lastPathComponent];
  if (sanitized.length == 0) {
    sanitized = @"download";
  }
  NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
  NSInteger dlMode = [ud objectForKey:@"Safarium.Pref.DownloadLocation"] ? [ud integerForKey:@"Safarium.Pref.DownloadLocation"] : 0;
  NSString* downloadsDir = nil;
  if (dlMode == 1) {
    downloadsDir = [NSSearchPathForDirectoriesInDomains(NSDesktopDirectory, NSUserDomainMask, YES) firstObject];
  } else if (dlMode == 3) {
    NSString* custom = [ud stringForKey:@"Safarium.Pref.CustomDownloadDir"];
    if (custom.length > 0) {
      downloadsDir = custom;
    }
  }
  if (!downloadsDir) {
    downloadsDir = [NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES) firstObject];
  }
  if (!downloadsDir) {
    downloadsDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
  }
  NSFileManager* fm = [NSFileManager defaultManager];
  [fm createDirectoryAtPath:downloadsDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];

  NSString* baseName = [sanitized stringByDeletingPathExtension];
  NSString* ext = [sanitized pathExtension];
  NSString* candidate = [downloadsDir stringByAppendingPathComponent:sanitized];
  NSUInteger suffix = 1;
  while ([fm fileExistsAtPath:candidate]) {
    NSString* nextName = ext.length > 0
                             ? [NSString stringWithFormat:@"%@ (%lu).%@", baseName,
                                                          (unsigned long)suffix, ext]
                             : [NSString stringWithFormat:@"%@ (%lu)", baseName,
                                                          (unsigned long)suffix];
    candidate = [downloadsDir stringByAppendingPathComponent:nextName];
    suffix++;
  }
  return candidate;
}

class SXFaviconDownloadCallback : public CefDownloadImageCallback {
 public:
  SXFaviconDownloadCallback(SXBrowserTab* tab,
                            CefRefPtr<CefBrowser> browser,
                            std::vector<CefString> urls,
                            size_t index,
                            NSUInteger generation)
      : tab_(tab),
        browser_(browser),
        urls_(std::move(urls)),
        index_(index),
        generation_(generation) {}

  void OnDownloadImageFinished(const CefString& image_url,
                               int http_status_code,
                               CefRefPtr<CefImage> image) override {
    SXBrowserTab* strongTab = tab_;
    if (!strongTab) {
      return;
    }

    auto tryNextCandidate = [&]() {
      if (browser_ && browser_->GetHost() && index_ + 1 < urls_.size()) {
        size_t nextIdx = index_ + 1;
        browser_->GetHost()->DownloadImage(
            urls_[nextIdx], true, 64, false,
            new SXFaviconDownloadCallback(strongTab, browser_, urls_, nextIdx, generation_));
      }
    };

    if (!image || image->IsEmpty()) {
      tryNextCandidate();
      return;
    }
    int pixelW = 0;
    int pixelH = 0;
    CefRefPtr<CefBinaryValue> png = image->GetAsPNG(2.0f, true, pixelW, pixelH);
    if (!png || png->GetSize() == 0) {
      png = image->GetAsPNG(1.0f, true, pixelW, pixelH);
    }
    if (!png || png->GetSize() == 0) {
      tryNextCandidate();
      return;
    }
    std::vector<uint8_t> bytes(png->GetSize());
    png->GetData(bytes.data(), bytes.size(), 0);
    NSData* data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
    NSImage* nsImage = [[NSImage alloc] initWithData:data];
    if (!nsImage) {
      tryNextCandidate();
      return;
    }
    NSUInteger gen = generation_;
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongTab handleFaviconLoaded:nsImage forGeneration:gen];
    });
  }

 private:
  __weak SXBrowserTab* tab_;
  CefRefPtr<CefBrowser> browser_;
  std::vector<CefString> urls_;
  size_t index_;
  NSUInteger generation_;
  IMPLEMENT_REFCOUNTING(SXFaviconDownloadCallback);
};

class SXSurrogateJSResourceHandler : public CefResourceHandler {
 public:
  explicit SXSurrogateJSResourceHandler(const char* scriptBody)
      : body_(scriptBody ? scriptBody : "") {}

  bool Open(CefRefPtr<CefRequest> request,
            bool& handle_request,
            CefRefPtr<CefCallback> callback) override {
    (void)request;
    (void)callback;
    handle_request = true;
    return true;
  }

  void GetResponseHeaders(CefRefPtr<CefResponse> response,
                          int64_t& response_length,
                          CefString& redirectUrl) override {
    (void)redirectUrl;
    if (response) {
      response->SetStatus(200);
      response->SetStatusText("OK");
      response->SetMimeType("application/javascript");
      CefResponse::HeaderMap headers;
      headers.emplace("Content-Type", "application/javascript; charset=utf-8");
      headers.emplace("Access-Control-Allow-Origin", "*");
      headers.emplace("Cross-Origin-Resource-Policy", "cross-origin");
      headers.emplace("Cache-Control", "no-store");
      response->SetHeaderMap(headers);
    }
    response_length = static_cast<int64_t>(body_.size());
  }

  bool Read(void* data_out,
            int bytes_to_read,
            int& bytes_read,
            CefRefPtr<CefResourceReadCallback> callback) override {
    (void)callback;
    if (!data_out || bytes_to_read <= 0 || offset_ >= body_.size()) {
      bytes_read = 0;
      return false;
    }
    size_t remaining = body_.size() - offset_;
    size_t to_copy = std::min(static_cast<size_t>(bytes_to_read), remaining);
    std::memcpy(data_out, body_.data() + offset_, to_copy);
    offset_ += to_copy;
    bytes_read = static_cast<int>(to_copy);
    return true;
  }

  void Cancel() override {}

 private:
  std::string body_;
  size_t offset_ = 0;
  IMPLEMENT_REFCOUNTING(SXSurrogateJSResourceHandler);
};

NSString* NSStringFromStdString(const std::string& s) {
  if (s.empty()) return @"";
  return [NSString stringWithUTF8String:s.c_str()] ?: @"";
}

std::string JoinCSV(const std::vector<std::string>& items) {
  std::string out;
  for (size_t i = 0; i < items.size(); ++i) {
    if (i > 0) out.push_back(',');
    out.append(items[i]);
  }
  return out;
}

bool IsUpgradeFallbackErrorCode(cef_errorcode_t errorCode) {
  if (errorCode == ERR_NONE || errorCode == ERR_ABORTED ||
      errorCode == ERR_NAME_NOT_RESOLVED || errorCode == ERR_INTERNET_DISCONNECTED) {
    return false;
  }
  int code = static_cast<int>(errorCode);
  return (code <= -100 && code >= -299) || (code <= -500 && code >= -599);
}

bool IsCertificateErrorCode(cef_errorcode_t errorCode) {
  int code = static_cast<int>(errorCode);
  return (code <= -200 && code >= -299);
}

class SXNavigationEntryVisitor : public CefNavigationEntryVisitor {
 public:
  SXNavigationEntryVisitor() = default;

  bool Visit(CefRefPtr<CefNavigationEntry> entry,
             bool current,
             int index,
             int total) override {
    (void)total;
    if (!entry || !entry->IsValid()) {
      return true;
    }
    // Stable, collision-resistant positive key per Chromium NavigationController slot:
    // - Distinct `index` separates repeated visits to the same URL at different stack depths.
    // - `GetOriginalURL()` + `GetURL()` change whenever a truncated forward slot is replaced
    //   or an SPA `pushState`/`replaceState` commits a new route, while remaining stable on reload.
    std::string orig = entry->GetOriginalURL().ToString();
    std::string url = entry->GetURL().ToString();
    uint64_t h = 14695981039346656037ULL;
    auto mix = [&](const void* data, size_t len) {
      const uint8_t* p = static_cast<const uint8_t*>(data);
      for (size_t i = 0; i < len; ++i) {
        h ^= static_cast<uint64_t>(p[i]);
        h *= 1099511628211ULL;
      }
    };
    int32_t idx32 = static_cast<int32_t>(index);
    mix(&idx32, sizeof(idx32));
    mix(orig.data(), orig.size());
    const uint8_t sep = 0x1F;
    mix(&sep, 1);
    mix(url.data(), url.size());
    NSInteger entryID = static_cast<NSInteger>((h & 0x3FFFFFFFFFFFFFFFULL) | 1ULL);
    entries_.push_back(entryID);
    if (current) {
      current_pos_ = static_cast<int>(entries_.size()) - 1;
    }
    return true;
  }

  void DispatchToTab(SXBrowserTab* tab) const {
    if (!tab || entries_.empty()) {
      return;
    }
    NSInteger curID = (current_pos_ >= 0 && current_pos_ < static_cast<int>(entries_.size()))
                          ? entries_[current_pos_]
                          : 0;
    NSInteger prevID = (current_pos_ > 0) ? entries_[current_pos_ - 1] : 0;
    NSInteger nextID = (current_pos_ >= 0 && current_pos_ + 1 < static_cast<int>(entries_.size()))
                           ? entries_[current_pos_ + 1]
                           : 0;
    NSMutableArray<NSNumber*>* validIDs = [NSMutableArray arrayWithCapacity:entries_.size()];
    for (NSInteger eid : entries_) {
      [validIDs addObject:@(eid)];
    }
    NSArray<NSNumber*>* immutableIDs = [validIDs copy];
    dispatch_async(dispatch_get_main_queue(), ^{
      [tab handleNavigationEntriesCurrentID:curID
                                 previousID:prevID
                                     nextID:nextID
                              validEntryIDs:immutableIDs];
    });
  }

 private:
  std::vector<NSInteger> entries_;
  int current_pos_ = -1;
  IMPLEMENT_REFCOUNTING(SXNavigationEntryVisitor);
};

void EmitNavigationEntryIDs(CefRefPtr<CefBrowser> browser, SXBrowserTab* strongTab) {
  if (!browser || !browser->GetHost() || !strongTab) {
    return;
  }
  CefRefPtr<SXNavigationEntryVisitor> visitor = new SXNavigationEntryVisitor();
  browser->GetHost()->GetNavigationEntries(visitor, false);
  visitor->DispatchToTab(strongTab);
}

}  // namespace

SXBrowserClient::SXBrowserClient(SXBrowserTab* tab)
    : tab_(tab),
      is_incognito_(tab ? ([tab isPrivateBrowsing] ? true : false) : false) {}

SXBrowserClient::~SXBrowserClient() {
  DetachTab();
}

SXBrowserTab* SXBrowserClient::RetainTab() const {
  std::lock_guard<std::mutex> lock(tab_mutex_);
  return tab_;
}

void SXBrowserClient::DetachTab() {
  {
    std::lock_guard<std::mutex> lock(tab_mutex_);
    tab_ = nil;
  }
  std::function<void(const std::string&)> inflight;
  std::deque<PendingCapture> queued;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    inflight_capture_id_ = 0;
    inflight.swap(inflight_capture_callback_);
    queued.swap(capture_queue_);
  }
  if (inflight) {
    inflight(std::string());
  }
  for (auto& item : queued) {
    if (item.callback) {
      item.callback(std::string());
    }
  }
  devtools_registration_ = nullptr;
}

void SXBrowserClient::EnsureDevToolsObserverRegistered(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  if (!devtools_registration_ && browser && browser->GetHost()) {
    devtools_registration_ = browser->GetHost()->AddDevToolsMessageObserver(this);
  }
}

void SXBrowserClient::ScheduleDevToolsDetachIfIdle() {
  CEF_REQUIRE_UI_THREAD();
  if (!devtools_registration_) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    if (inflight_capture_id_ != 0 || !capture_queue_.empty()) {
      return;
    }
  }
  // Detach the internal DevTools observer immediately once all captures complete so Chromium's
  // BackForwardCache is never evicted by a lingering DevTools session during Back/Forward navigation.
  devtools_registration_ = nullptr;
}

void SXBrowserClient::ExecuteCaptureRequest(
    CefRefPtr<CefDictionaryValue> params,
    std::function<void(const std::string& pngBytes)> callback,
    bool priority) {
  if (!CefCurrentlyOn(TID_UI)) {
    CefRefPtr<SXBrowserClient> selfRef(this);
    CefPostTask(TID_UI,
                CefCreateClosureTask(base::BindOnce(
                    &SXBrowserClient::ExecuteCaptureRequest, selfRef, params,
                    std::move(callback), priority)));
    return;
  }

  if (!browser_ || !browser_->GetHost()) {
    if (callback) {
      callback(std::string());
    }
    return;
  }

  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    if (priority) {
      capture_queue_.push_front(PendingCapture{params, std::move(callback)});
    } else {
      capture_queue_.push_back(PendingCapture{params, std::move(callback)});
    }
  }
  StartNextCaptureIfIdle();
}

void SXBrowserClient::StartNextCaptureIfIdle() {
  CEF_REQUIRE_UI_THREAD();
  if (!browser_ || !browser_->GetHost()) {
    return;
  }

  PendingCapture next;
  int reqId = 0;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    if (inflight_capture_id_ != 0 || capture_queue_.empty()) {
      return;
    }
    next = std::move(capture_queue_.front());
    capture_queue_.pop_front();
    reqId = next_devtools_id_.fetch_add(1);
    inflight_capture_id_ = reqId;
    inflight_capture_callback_ = std::move(next.callback);
  }

  EnsureDevToolsObserverRegistered(browser_);

  // Calls Chromium's native RenderWidgetHostView::CopyFromSurface directly
  // on the GPU compositor IOSurface, serialized 1-at-a-time per tab so clipped
  // 3pt top-edge strips NEVER collide with full-viewport Tab Overview snapshots.
  int assigned = browser_->GetHost()->ExecuteDevToolsMethod(
      reqId, "Page.captureScreenshot", next.params);
  if (assigned == 0) {
    TimeoutCaptureIfStillInFlight(reqId);
    return;
  }
  // Safety timeout (2.0s) so a failed/discarded page capture can never wedge the queue.
  CefRefPtr<SXBrowserClient> selfRef(this);
  CefPostDelayedTask(TID_UI,
                     CefCreateClosureTask(base::BindOnce(
                         &SXBrowserClient::TimeoutCaptureIfStillInFlight,
                         selfRef, reqId)),
                     2000);
}

void SXBrowserClient::TimeoutCaptureIfStillInFlight(int reqId) {
  CEF_REQUIRE_UI_THREAD();
  std::function<void(const std::string&)> timedOutCb;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    if (inflight_capture_id_ != reqId) {
      return;
    }
    inflight_capture_id_ = 0;
    timedOutCb.swap(inflight_capture_callback_);
  }
  if (timedOutCb) {
    timedOutCb(std::string());
  }
  StartNextCaptureIfIdle();
  ScheduleDevToolsDetachIfIdle();
}

void SXBrowserClient::CaptureSurfaceForTopEdgeSample(
    std::function<void(const std::string& imageBytes)> callback) {
  // IMPORTANT: NEVER pass `clip` or `scale != 1.0` to Page.captureScreenshot!
  // In Chromium 156, `clip.scale != 1.0` mutates RenderWidgetHostImpl::EnableDeviceEmulation
  // which can permanently leave a tab stuck at 0.5x viewport scale.
  // Use low JPEG quality (25) for fast 3px strip color averaging with minimal GPU/IPC overhead.
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("format", "jpeg");
  params->SetInt("quality", 25);
  params->SetBool("fromSurface", true);
  params->SetBool("captureBeyondViewport", false);
  ExecuteCaptureRequest(params, std::move(callback));
}

void SXBrowserClient::CaptureFullSnapshotPNG(
    double widthPoints,
    double heightPoints,
    std::function<void(const std::string& pngBytes)> callback) {
  (void)widthPoints;
  (void)heightPoints;
  // Capture the exact rendered GPU compositor viewport surface with zero extra
  // margins, padding, or temporary viewport metric overrides.
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("format", "png");
  params->SetBool("fromSurface", true);
  params->SetBool("captureBeyondViewport", false);
  ExecuteCaptureRequest(params, std::move(callback));
}

void SXBrowserClient::CaptureFreezeFramePNG(
    std::function<void(const std::string& pngBytes)> callback,
    bool priority) {
  // Lossless so the frozen frame is pixel-identical to the live page it replaces; optimizeForSpeed picks
  // Chromium's fast PNG encoder (~2x faster than the default level, still exact pixels).
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("format", "png");
  params->SetBool("optimizeForSpeed", true);
  params->SetBool("fromSurface", true);
  params->SetBool("captureBeyondViewport", false);
  ExecuteCaptureRequest(params, std::move(callback), priority);
}

void SXBrowserClient::CapturePreviewSnapshotJPEG(
    std::function<void(const std::string& jpegBytes)> callback) {
  // Low-overhead JPEG capture for periodic Tab Overview RAM previews.
  // Omitting `clip` and `scale` keeps Chromium's read-only CopyFromSurface path with ZERO viewport mutation.
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("format", "jpeg");
  params->SetInt("quality", 60);
  params->SetBool("fromSurface", true);
  params->SetBool("captureBeyondViewport", false);
  ExecuteCaptureRequest(params, std::move(callback));
}

void SXBrowserClient::SetPageScaleFactor(double scale) {
  if (!CefCurrentlyOn(TID_UI)) {
    CefRefPtr<SXBrowserClient> selfRef(this);
    CefPostTask(TID_UI,
                CefCreateClosureTask(base::BindOnce(
                    &SXBrowserClient::SetPageScaleFactor, selfRef, scale)));
    return;
  }
  if (!browser_ || !browser_->GetHost()) {
    return;
  }
  double clamped = std::max(1.0, std::min(4.0, scale));
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetDouble("pageScaleFactor", clamped);
  int reqId = next_devtools_id_.fetch_add(1);
  browser_->GetHost()->ExecuteDevToolsMethod(
      reqId, "Emulation.setPageScaleFactor", params);
}

void SXBrowserClient::ResetPageScaleFactor() {
  if (!CefCurrentlyOn(TID_UI)) {
    CefRefPtr<SXBrowserClient> selfRef(this);
    CefPostTask(TID_UI,
                CefCreateClosureTask(base::BindOnce(
                    &SXBrowserClient::ResetPageScaleFactor, selfRef)));
    return;
  }
  if (!browser_ || !browser_->GetHost()) {
    return;
  }
  int reqId = next_devtools_id_.fetch_add(1);
  browser_->GetHost()->ExecuteDevToolsMethod(
      reqId, "Emulation.resetPageScaleFactor", nullptr);
  ScheduleDevToolsDetachIfIdle();
}

#pragma mark - CefClient IPC

bool SXBrowserClient::OnProcessMessageReceived(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefProcessId source_process,
    CefRefPtr<CefProcessMessage> message) {
  CEF_REQUIRE_UI_THREAD();
  if (!message) {
    return false;
  }
  const std::string name = message->GetName().ToString();
  SXBrowserTab* strongTab = RetainTab();
  if (!strongTab) {
    return false;
  }

  if (name == "sx.telemetry") {
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    if (!args || args->GetSize() < 4) {
      return true;
    }
    CGFloat scrollY = (CGFloat)args->GetDouble(0);
    CGFloat contentHeight = (CGFloat)args->GetDouble(1);
    CGFloat pageScale = (CGFloat)args->GetDouble(2);
    BOOL isPinching = args->GetBool(3) ? YES : NO;
    CGFloat viewportHeight = (args->GetSize() >= 5) ? (CGFloat)args->GetDouble(4) : 0.0;
    BOOL canInnerScrollUp = (args->GetSize() >= 6) ? (args->GetBool(5) ? YES : NO) : NO;
    BOOL canInnerScrollDown = (args->GetSize() >= 7) ? (args->GetBool(6) ? YES : NO) : NO;
    BOOL canScrollLeft = (args->GetSize() >= 8) ? (args->GetBool(7) ? YES : NO) : NO;
    BOOL canScrollRight = (args->GetSize() >= 9) ? (args->GetBool(8) ? YES : NO) : NO;
    BOOL pageConsumesPinchZoom = (args->GetSize() >= 10) ? (args->GetBool(9) ? YES : NO) : NO;

    dispatch_async(dispatch_get_main_queue(), ^{
      [strongTab handleTelemetryScrollY:scrollY
                          contentHeight:contentHeight
                              pageScale:pageScale
                             isPinching:isPinching
                         viewportHeight:viewportHeight
                       canInnerScrollUp:canInnerScrollUp
                     canInnerScrollDown:canInnerScrollDown
                          canScrollLeft:canScrollLeft
                         canScrollRight:canScrollRight
                  pageConsumesPinchZoom:pageConsumesPinchZoom];
    });
    return true;
  }

  if (name == "sx.fixed_header") {
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    if (!args || args->GetSize() < 4) {
      return true;
    }
    BOOL hasFixed = args->GetBool(0) ? YES : NO;
    double r = args->GetDouble(1);
    double g = args->GetDouble(2);
    double b = args->GetDouble(3);
    double a = args->GetSize() >= 5 ? args->GetDouble(4) : 1.0;
    NSColor* fixedColor = hasFixed
        ? [NSColor colorWithSRGBRed:std::max(0.0, std::min(1.0, r))
                              green:std::max(0.0, std::min(1.0, g))
                               blue:std::max(0.0, std::min(1.0, b))
                              alpha:std::max(0.0, std::min(1.0, a))]
        : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongTab handleFixedHeaderColor:fixedColor];
    });
    return true;
  }

  if (name == "sx.page_bg") {
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    if (!args || args->GetSize() < 3) {
      return true;
    }
    double r = std::max(0.0, std::min(1.0, args->GetDouble(0)));
    double g = std::max(0.0, std::min(1.0, args->GetDouble(1)));
    double b = std::max(0.0, std::min(1.0, args->GetDouble(2)));
    NSColor* bgColor = [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongTab handlePageBackgroundColor:bgColor];
    });
    return true;
  }

  if (name == "sx.nav_ready") {
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    BOOL fromBFCache = (args && args->GetSize() >= 1 && args->GetBool(0)) ? YES : NO;
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongTab handleNavigationVisuallyReadyFromBFCache:fromBFCache];
    });
    return true;
  }

  if (name == "sx.nav_traverse") {
    if ([NSThread isMainThread]) {
      [strongTab handleScriptTraverseNavigation];
    } else {
      dispatch_async(dispatch_get_main_queue(), ^{
        [strongTab handleScriptTraverseNavigation];
      });
    }
    return true;
  }

  if (name == "sx.native_video") {
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    if (!args || args->GetSize() < 8) {
      return true;
    }
    std::string idStr = args->GetString(0).ToString();
    std::string srcStr = args->GetString(1).ToString();
    if (idStr == "menu") {
      double vx = args->GetDouble(2);
      double vy = args->GetDouble(3);
      NSString* jsonStr = [NSString stringWithUTF8String:srcStr.c_str()] ?: @"{}";
      CefRefPtr<CefBrowser> targetBrowser = browser;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (!targetBrowser || !targetBrowser->GetHost()) return;
        NSView* hostView = (__bridge NSView*)targetBrowser->GetHost()->GetWindowHandle();
        if (!hostView) return;

        double curRate = 1.0;
        BOOL showStats = NO;
        NSData* data = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
        if (data) {
          NSDictionary* obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
          if ([obj isKindOfClass:[NSDictionary class]]) {
            if ([obj[@"rate"] isKindOfClass:[NSNumber class]]) curRate = [obj[@"rate"] doubleValue];
            if ([obj[@"showStats"] isKindOfClass:[NSNumber class]]) showStats = [obj[@"showStats"] boolValue];
          }
        }

        NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
        menu.autoenablesItems = NO;
        NSMutableArray<SXVideoMenuTarget*>* targets = [NSMutableArray array];

        if (@available(macOS 14.0, *)) {
          [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Playback Speed"]];
        } else {
          NSMenuItem* hdr = [[NSMenuItem alloc] initWithTitle:@"Playback Speed" action:nil keyEquivalent:@""];
          hdr.enabled = NO;
          [menu addItem:hdr];
        }

        NSArray<NSNumber*>* rates = @[ @0.5, @1.0, @1.25, @1.5, @2.0 ];
        NSArray<NSString*>* labels = @[ @"0.5\u00d7", @"1\u00d7", @"1.25\u00d7", @"1.5\u00d7", @"2\u00d7" ];
        for (NSUInteger i = 0; i < rates.count; ++i) {
          double r = [rates[i] doubleValue];
          SXVideoMenuTarget* t = [[SXVideoMenuTarget alloc] init];
          t.rate = r;
          t.isStatsToggle = NO;
          t.onPick = ^(double pickedRate, BOOL isStats) {
            (void)isStats;
            if (targetBrowser && targetBrowser->GetMainFrame()) {
              char js[160];
              snprintf(js, sizeof(js),
                       "window.__sxActiveVideoMenu && window.__sxActiveVideoMenu.setRate(%.3f);",
                       pickedRate);
              targetBrowser->GetMainFrame()->ExecuteJavaScript(js, "", 0);
            }
          };
          [targets addObject:t];
          NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:labels[i]
                                                        action:@selector(picked:)
                                                 keyEquivalent:@""];
          item.target = t;
          item.enabled = YES;
          item.state = (fabs(curRate - r) < 0.01) ? NSControlStateValueOn : NSControlStateValueOff;
          [menu addItem:item];
        }

        [menu addItem:[NSMenuItem separatorItem]];

        SXVideoMenuTarget* stTarget = [[SXVideoMenuTarget alloc] init];
        stTarget.isStatsToggle = YES;
        stTarget.onPick = ^(double pickedRate, BOOL isStats) {
          (void)pickedRate;
          (void)isStats;
          if (targetBrowser && targetBrowser->GetMainFrame()) {
            targetBrowser->GetMainFrame()->ExecuteJavaScript(
                "window.__sxActiveVideoMenu && window.__sxActiveVideoMenu.toggleStats();", "", 0);
          }
        };
        [targets addObject:stTarget];
        NSMenuItem* statsItem = [[NSMenuItem alloc]
            initWithTitle:(showStats ? @"Hide Media Statistics" : @"Show Media Statistics")
                   action:@selector(picked:)
            keyEquivalent:@""];
        statsItem.target = stTarget;
        statsItem.enabled = YES;
        [menu addItem:statsItem];

        CGFloat viewH = hostView.bounds.size.height;
        NSPoint pt = hostView.isFlipped ? NSMakePoint(vx, vy) : NSMakePoint(vx, viewH - vy);
        [menu popUpMenuPositioningItem:nil atLocation:pt inView:hostView];
        (void)targets;  // Keep targets alive until popUpMenuPositioningItem returns.
      });
      return true;
    }
    NSString* videoID = [NSString stringWithUTF8String:idStr.c_str()] ?: @"";
    NSString* srcURL = [NSString stringWithUTF8String:srcStr.c_str()] ?: @"";
    NSRect rect = NSMakeRect(args->GetDouble(2), args->GetDouble(3), args->GetDouble(4), args->GetDouble(5));
    BOOL visible = args->GetBool(6) ? YES : NO;
    BOOL autoplay = args->GetBool(7) ? YES : NO;
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongTab handleNativeVideoID:videoID
                              srcURL:srcURL
                                rect:rect
                             visible:visible
                            autoplay:autoplay];
    });
    return true;
  }

  if (name == "sx.auth_event") {
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    if (!args || args->GetSize() < 1) {
      return true;
    }
    std::string payload = args->GetString(0).ToString();
    NSString* jsonStr = [NSString stringWithUTF8String:payload.c_str()] ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongTab handleAuthEventJSON:jsonStr];
    });
    return true;
  }

  if (name == "sx.overscroll" || name == "sx.pull_refresh") {
    // Legacy renderer-side overscroll messages are intentionally ignored;
    // elastic scrolling & pull-to-refresh are owned natively in AppKit at 120Hz.
    return true;
  }

  if (name == "sx.space_scroll") {
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    int direction = (args && args->GetSize() >= 1) ? args->GetInt(0) : -1;
    BOOL isRepeat = (args && args->GetSize() >= 2 && args->GetBool(1)) ? YES : NO;
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongTab handleSpaceScrollDirection:direction isRepeat:isRepeat];
    });
    return true;
  }

  if (name == "sx.drag_img_info") {
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    double natW = (args && args->GetSize() >= 1) ? args->GetDouble(0) : 0.0;
    double natH = (args && args->GetSize() >= 2) ? args->GetDouble(1) : 0.0;
    double boxW = (args && args->GetSize() >= 3) ? args->GetDouble(2) : 0.0;
    double boxH = (args && args->GetSize() >= 4) ? args->GetDouble(3) : 0.0;
    std::string fitStr = (args && args->GetSize() >= 5) ? args->GetString(4).ToString() : "";
    NSString *objectFit = [NSString stringWithUTF8String:fitStr.c_str()] ?: @"";
    [strongTab handleDragImageInfoNaturalWidth:natW
                                 naturalHeight:natH
                                      boxWidth:boxW
                                     boxHeight:boxH
                                     objectFit:objectFit];
    return true;
  }

  if (name == "sx.ext_tab_create") {
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    if (args && args->GetSize() >= 1) {
      std::string urlStr = args->GetString(0).ToString();
      NSString *nsUrl = [NSString stringWithUTF8String:urlStr.c_str()];
      NSURL *url = nsUrl.length > 0 ? [NSURL URLWithString:nsUrl] : nil;
      if (url) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [[SXEngineRuntime sharedRuntime] postNewTabRequestForURL:url];
        });
      }
    }
    return true;
  }

  if (name == "sx.ext_tab_reload") {
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongTab reload];
    });
    return true;
  }

  if (name == "sx.ext_window_create") {
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    if (args && args->GetSize() >= 1) {
      std::string urlStr = args->GetString(0).ToString();
      NSString *nsUrl = [NSString stringWithUTF8String:urlStr.c_str()];
      NSURL *url = nsUrl.length > 0 ? [NSURL URLWithString:nsUrl] : nil;
      if (url) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [[SXEngineRuntime sharedRuntime] postNewTabRequestForURL:url];
        });
      }
    }
    return true;
  }

  if (name == "sx.cws_query") {
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    if (!args || args->GetSize() < 1) return true;
    NSString *storeID = NSStringFromCefString(args->GetString(0));
    CefRefPtr<CefBrowser> targetBrowser = browser;
    dispatch_async(dispatch_get_main_queue(), ^{
      BOOL installed = [[SXExtensionManager sharedManager] isStoreIDInstalled:storeID];
      BOOL busy = [[SXExtensionManager sharedManager] isStoreIDBusy:storeID];
      CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
          [](CefRefPtr<CefBrowser> b, std::string sid, bool inst, bool isBusy) {
            if (!b) return;
            CefRefPtr<CefFrame> f = b->GetMainFrame();
            if (!f || !f->IsValid()) return;
            CefRefPtr<CefProcessMessage> reply = CefProcessMessage::Create("sx.cws_state");
            CefRefPtr<CefListValue> rargs = reply->GetArgumentList();
            rargs->SetString(0, sid);
            rargs->SetBool(1, inst);
            rargs->SetBool(2, isBusy);
            rargs->SetString(3, "");
            f->SendProcessMessage(PID_RENDERER, reply);
          },
          targetBrowser, std::string(storeID.UTF8String), installed ? true : false, busy ? true : false)));
    });
    return true;
  }

  if (name == "sx.cws_install") {
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    if (!args || args->GetSize() < 1) return true;
    NSString *storeID = NSStringFromCefString(args->GetString(0));
    CefRefPtr<CefBrowser> targetBrowser = browser;
    dispatch_async(dispatch_get_main_queue(), ^{
      [[SXExtensionManager sharedManager]
          installExtensionFromChromeWebStoreID:storeID
                                    completion:^(SXExtensionItem * _Nullable item,
                                                 NSError * _Nullable error) {
                                      BOOL ok = (item != nil && error == nil);
                                      std::string errStr = error ? error.localizedDescription.UTF8String : "";
                                      CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
                                          [](CefRefPtr<CefBrowser> b, std::string sid, bool inst, std::string err) {
                                            if (!b) return;
                                            CefRefPtr<CefFrame> f = b->GetMainFrame();
                                            if (!f || !f->IsValid()) return;
                                            CefRefPtr<CefProcessMessage> reply = CefProcessMessage::Create("sx.cws_state");
                                            CefRefPtr<CefListValue> rargs = reply->GetArgumentList();
                                            rargs->SetString(0, sid);
                                            rargs->SetBool(1, inst);
                                            rargs->SetBool(2, false);
                                            rargs->SetString(3, err);
                                            f->SendProcessMessage(PID_RENDERER, reply);
                                          },
                                          targetBrowser, std::string(storeID.UTF8String), ok ? true : false, errStr)));
                                    }];
    });
    return true;
  }

  if (name == "sx.cws_uninstall") {
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    if (!args || args->GetSize() < 1) return true;
    NSString *storeID = NSStringFromCefString(args->GetString(0));
    CefRefPtr<CefBrowser> targetBrowser = browser;
    dispatch_async(dispatch_get_main_queue(), ^{
      [[SXExtensionManager sharedManager]
          uninstallExtensionWithID:storeID
                        completion:^(BOOL success, NSError * _Nullable error) {
                          BOOL stillInstalled = [[SXExtensionManager sharedManager] isStoreIDInstalled:storeID];
                          std::string errStr = error ? error.localizedDescription.UTF8String : "";
                          CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
                              [](CefRefPtr<CefBrowser> b, std::string sid, bool inst, std::string err) {
                                if (!b) return;
                                CefRefPtr<CefFrame> f = b->GetMainFrame();
                                if (!f || !f->IsValid()) return;
                                CefRefPtr<CefProcessMessage> reply = CefProcessMessage::Create("sx.cws_state");
                                CefRefPtr<CefListValue> rargs = reply->GetArgumentList();
                                rargs->SetString(0, sid);
                                rargs->SetBool(1, inst);
                                rargs->SetBool(2, false);
                                rargs->SetString(3, err);
                                f->SendProcessMessage(PID_RENDERER, reply);
                              },
                              targetBrowser, std::string(storeID.UTF8String), stillInstalled ? true : false, errStr)));
                        }];
    });
    return true;
  }

  if (name == "sx_privacy_request_config") {
    CefRefPtr<CefDictionaryValue> cfg =
        SXBuildPrivacyConfigUpdateDictionary(is_incognito_.load(std::memory_order_acquire));
    CefRefPtr<CefFrame> targetFrame = (frame && frame->IsValid()) ? frame : (browser ? browser->GetMainFrame() : nullptr);
    if (targetFrame && targetFrame->IsValid() && cfg) {
      CefRefPtr<CefProcessMessage> reply = CefProcessMessage::Create("sx_privacy_config_update");
      reply->GetArgumentList()->SetDictionary(0, cfg);
      targetFrame->SendProcessMessage(PID_RENDERER, reply);
    }
    return true;
  }

  if (name == "sx_privacy_fp_event") {
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    if (!args || args->GetSize() < 1) {
      return true;
    }
    std::string payload = args->GetString(0).ToString();
    @autoreleasepool {
      NSData* data = [NSData dataWithBytes:payload.data() length:payload.size()];
      id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
      if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary* dict = (NSDictionary*)obj;
        NSString* apiNS = [dict[@"api"] isKindOfClass:[NSString class]] ? dict[@"api"] : @"";
        NSString* pageHostNS = [dict[@"pageHost"] isKindOfClass:[NSString class]] ? dict[@"pageHost"] : @"";
        NSString* frameHostNS = [dict[@"frameHost"] isKindOfClass:[NSString class]] ? dict[@"frameHost"] : @"";

        std::string api = apiNS.UTF8String ? std::string(apiNS.UTF8String) : "";
        std::string pageHost;
        if (browser && browser->GetMainFrame()) {
          std::string mainUrl = browser->GetMainFrame()->GetURL().ToString();
          if (!mainUrl.empty()) {
            pageHost = sx::privacy::NormalizeHost(sx::privacy::ExtractHostFromURL(mainUrl));
          }
        }
        if (pageHost.empty()) {
          pageHost = sx::privacy::NormalizeHost(pageHostNS.UTF8String ?: "");
        }
        std::string frameHost = sx::privacy::NormalizeHost(frameHostNS.UTF8String ?: "");
        if (frameHost.empty()) frameHost = pageHost;

        auto tm = sx::privacy::SXPrivacyEngine::Shared().ClassifyTrackerHost(frameHost, 1, true);
        std::string entityDomain = tm.matched ? tm.entity_domain : sx::privacy::RegistrableDomain(frameHost);
        std::string ownerName = tm.matched ? tm.owner_name : entityDomain;

        EmitPrivacyEventOnMainThread("fingerprintBlocked",
                                     pageHost,
                                     frameHost,
                                     entityDomain,
                                     ownerName,
                                     "fingerprinting",
                                     api,
                                     1);
      }
    }
    return true;
  }

  return false;
}

void SXBrowserClient::EmitPrivacyEventOnMainThread(const std::string& event_type,
                                                   const std::string& page_host,
                                                   const std::string& tracker_host,
                                                   const std::string& entity_domain,
                                                   const std::string& owner_name,
                                                   const std::string& category,
                                                   const std::string& detail,
                                                   NSInteger count) {
  SXBrowserTab* strongTab = RetainTab();
  BOOL isPrivate = is_incognito_.load(std::memory_order_acquire) ? YES : NO;
  NSTimeInterval ts = [[NSDate date] timeIntervalSince1970];
  SXPrivacyEvent* event = [[SXPrivacyEvent alloc]
      initWithEventType:NSStringFromStdString(event_type)
               pageHost:NSStringFromStdString(page_host)
            trackerHost:NSStringFromStdString(tracker_host)
           entityDomain:NSStringFromStdString(entity_domain)
              ownerName:NSStringFromStdString(owner_name)
               category:NSStringFromStdString(category)
                 detail:NSStringFromStdString(detail)
                  count:count
              isPrivate:isPrivate
              timestamp:ts];
  dispatch_async(dispatch_get_main_queue(), ^{
    [[SXEngineRuntime sharedRuntime] dispatchPrivacyEvent:event forTab:strongTab];
  });
}

void SXBrowserClient::UpdateConnectionSecurityForMainURL(const std::string& url,
                                                         SXConnectionSecurityState* explicit_state) {
  std::string scheme = sx::privacy::ExtractSchemeFromURL(url);
  std::string host = sx::privacy::NormalizeHost(sx::privacy::ExtractHostFromURL(url));
  SXConnectionSecurityState state = SXConnectionSecurityStateInternal;

  if (explicit_state != nullptr) {
    state = *explicit_state;
  } else if (scheme == "https") {
    bool wasUpgraded = false;
    {
      std::lock_guard<std::mutex> lock(nav_privacy_mutex_);
      wasUpgraded = (!upgraded_committed_url_.empty() && upgraded_committed_url_ == url);
    }
    state = wasUpgraded ? SXConnectionSecurityStateUpgradedHTTPS : SXConnectionSecurityStateSecureHTTPS;
  } else if (scheme == "http") {
    state = SXConnectionSecurityStateInsecureHTTP;
  } else {
    state = SXConnectionSecurityStateInternal;
  }

  SXBrowserTab* strongTab = RetainTab();
  if (strongTab) {
    NSString* hostNS = NSStringFromStdString(host);
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongTab handleConnectionSecurityState:state host:hostNS];
    });
  }
}

std::string SXBrowserClient::ResolveCurrentPageURL(CefRefPtr<CefBrowser> browser,
                                                   CefRefPtr<CefRequest> request) {
  if (browser && browser->GetMainFrame()) {
    std::string mainUrl = browser->GetMainFrame()->GetURL().ToString();
    if (!mainUrl.empty() && mainUrl.rfind("chrome-error://", 0) != 0) {
      return mainUrl;
    }
  }
  if (request) {
    std::string fpc = request->GetFirstPartyForCookies().ToString();
    if (!fpc.empty()) {
      return fpc;
    }
  }
  {
    std::lock_guard<std::mutex> lock(nav_privacy_mutex_);
    if (!committed_main_url_.empty()) {
      return committed_main_url_;
    }
  }
  return "";
}

#pragma mark - CefLifeSpanHandler

namespace {

NSURL* SXURLFromCefTargetString(const CefString& target_url) {
  NSString* urlStr = NSStringFromCefString(target_url);
  if (urlStr.length == 0) return nil;
  NSURL* url = [NSURL URLWithString:urlStr];
  if (!url) {
    NSString* encoded = [urlStr stringByAddingPercentEncodingWithAllowedCharacters:
                                    [NSCharacterSet URLFragmentAllowedCharacterSet]];
    if (encoded.length > 0) {
      url = [NSURL URLWithString:encoded];
    }
  }
  return url;
}

}  // namespace

bool SXBrowserClient::OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                                       CefRefPtr<CefFrame> frame,
                                       const CefString& target_url,
                                       WindowOpenDisposition target_disposition,
                                       bool user_gesture) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  (void)frame;

  SXWindowOpenDisposition sxDisposition;
  switch (target_disposition) {
    case CEF_WOD_NEW_BACKGROUND_TAB:
      sxDisposition = SXWindowOpenDispositionNewBackgroundTab;
      break;
    case CEF_WOD_NEW_FOREGROUND_TAB:
      sxDisposition = SXWindowOpenDispositionNewForegroundTab;
      break;
    case CEF_WOD_NEW_WINDOW:
    case CEF_WOD_NEW_POPUP:
      sxDisposition = SXWindowOpenDispositionNewWindow;
      break;
    case CEF_WOD_OFF_THE_RECORD:
      sxDisposition = SXWindowOpenDispositionOffTheRecord;
      break;
    default:
      // Allow CEF_WOD_CURRENT_TAB / downloads to proceed through standard Chromium navigation.
      return false;
  }

  SXBrowserTab* strongTab = RetainTab();
  NSURL* url = SXURLFromCefTargetString(target_url);
  if (!strongTab || !url) {
    return true;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    (void)[strongTab handleOpenRequestURL:url
                              disposition:sxDisposition
                              userGesture:user_gesture ? YES : NO];
  });
  return true;
}

bool SXBrowserClient::OnBeforePopup(CefRefPtr<CefBrowser> browser,
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
                                    bool* no_javascript_access) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  (void)popup_id;
  (void)popupFeatures;
  (void)settings;
  (void)extra_info;
  NSString* urlStr = NSStringFromCefString(target_url);
  NSURL* url = SXURLFromCefTargetString(target_url);

  // Enforce per-website / default Pop-up Windows policy (0=Block and Notify, 1=Block, 2=Allow)
  // for non-user-gesture popups.
  if (!user_gesture && frame) {
    NSString* originHost = NormalizedHostFromURLString(NSStringFromCefString(frame->GetURL()));
    NSInteger popupPolicy = SitePolicyIndexForCategory(@"Pop-up Windows", originHost, 0);
    if (popupPolicy != 2) {
      return true;
    }
  }

  SXBrowserTab* strongTab = RetainTab();

  // Preserve `window.opener` (`response_mode=web_message` / AppleJS popup postMessage) for
  // Sign in with Apple popups (`appleid.apple.com` / `idmsa.apple.com`) by hosting a genuine
  // child CefBrowser inside `strongTab.authPopupContainerView` while SafariShell presents
  // Safari's native Touch ID modal sheet over the originating tab.
  if (strongTab) {
    NSString* targetHost = NormalizedHostFromURLString(urlStr);
    NSString* urlLower = urlStr.lowercaseString ?: @"";
    NSString* frameNameLower = NSStringFromCefString(target_frame_name).lowercaseString ?: @"";
    BOOL isAppleAuthHost =
        [targetHost isEqualToString:@"appleid.apple.com"] ||
        [targetHost hasSuffix:@".appleid.apple.com"] ||
        [targetHost isEqualToString:@"idmsa.apple.com"] ||
        [targetHost hasSuffix:@".idmsa.apple.com"];
    BOOL isBlankNamedApplePopup =
        ([urlStr isEqualToString:@"about:blank"] || urlStr.length == 0) &&
        ([frameNameLower containsString:@"appleid"] ||
         [frameNameLower containsString:@"apple-sign-in"] ||
         [frameNameLower containsString:@"apple_auth"] ||
         [frameNameLower containsString:@"signinwithapple"]);
    BOOL isAppleOAuthBrokerPopup =
        ([urlLower containsString:@"provider=apple"] ||
         [urlLower containsString:@"/auth/apple"] ||
         [urlLower containsString:@"/oauth/apple"]) &&
        (target_disposition == CEF_WOD_NEW_POPUP || popupFeatures.widthSet || popupFeatures.heightSet || user_gesture);
    BOOL isRecentAppleIntentPopup =
        user_gesture && [strongTab hasRecentAppleSignInIntent] &&
        (target_disposition == CEF_WOD_NEW_POPUP || popupFeatures.widthSet || popupFeatures.heightSet ||
         [urlStr isEqualToString:@"about:blank"] || urlStr.length == 0 || isAppleOAuthBrokerPopup);
    if (isAppleAuthHost || isBlankNamedApplePopup || isAppleOAuthBrokerPopup || isRecentAppleIntentPopup) {
      NSView* popupHost = strongTab.authPopupContainerView;
      NSRect pb = popupHost.bounds;
      if (pb.size.width < 100 || pb.size.height < 100) {
        pb = NSMakeRect(0, 0, 440, 500);
        popupHost.frame = pb;
      }
      CefRect cefBounds(0, 0, (int)std::round(pb.size.width), (int)std::round(pb.size.height));
      windowInfo.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(popupHost), cefBounds);
      NSURL* notifyURL = url ?: [NSURL URLWithString:@"about:blank"];
      client = [strongTab prepareAuthPopupClientWithInitialURL:notifyURL];
      extra_info = SXBuildPrivacyExtraInfoDictionary(is_incognito_.load(std::memory_order_acquire));
      if (no_javascript_access) {
        *no_javascript_access = false;
      }
      return false;
    }
  }

  if (strongTab && url) {
    SXWindowOpenDisposition sxDisposition = SXWindowOpenDispositionNewTabDefault;
    switch (target_disposition) {
      case CEF_WOD_NEW_BACKGROUND_TAB:
        sxDisposition = SXWindowOpenDispositionNewBackgroundTab;
        break;
      case CEF_WOD_NEW_WINDOW:
        sxDisposition = SXWindowOpenDispositionNewWindow;
        break;
      case CEF_WOD_OFF_THE_RECORD:
        sxDisposition = SXWindowOpenDispositionOffTheRecord;
        break;
      default:
        sxDisposition = SXWindowOpenDispositionNewTabDefault;
        break;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      BOOL handled = [strongTab handleOpenRequestURL:url
                                         disposition:sxDisposition
                                         userGesture:user_gesture ? YES : NO];
      if (!handled) {
        [strongTab loadURL:url];
      }
    });
  }
  // Cancel Chromium's default popup window so SafariShell owns all tabs & windows.
  return true;
}

void SXBrowserClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  [[SXEngineRuntime sharedRuntime] noteBrowserCreated];
  browser_ = browser;
  if (browser && browser->GetHost()) {
    CefRefPtr<CefRequestContext> ctx = browser->GetHost()->GetRequestContext();
    CefRefPtr<CefRequestContext> globalCtx = CefRequestContext::GetGlobalContext();
    bool incognito = (ctx && globalCtx && !ctx->IsSame(globalCtx));
    is_incognito_.store(incognito, std::memory_order_release);
  }
  [[SXExtensionManager sharedManager] registerActiveBrowser:browser];
  SXBrowserTab* strongTab = RetainTab();
  if (getenv("SAFARIUM_CEF_DEBUG")) {
    fprintf(stderr, "[BrowserCore] OnAfterCreated id=%d tab=%p\n",
            browser ? browser->GetIdentifier() : -1, (__bridge void *)strongTab);
    fflush(stderr);
  }
  if (strongTab) {
    [strongTab handleBrowserCreated:browser];
  }
}

bool SXBrowserClient::DoClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  SXBrowserTab* strongTab = RetainTab();
  if (strongTab) {
    [strongTab handleBrowserClosing];
  }
  // Detach CEF's child NSView from its parent NSWindow hierarchy so CEF NEVER sends
  // -[NSWindow performClose:] to Safarium's host NSWindow when closing a single tab.
  // Once detached (cefView.window == nil), return false so CEF destroys the browser
  // immediately and fires OnBeforeClose instead of leaking a half-closed browser until shutdown.
  bool stillAttachedToWindow = false;
  if (browser && browser->GetHost()) {
    NSView* cefView =
        CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    if (cefView && cefView.superview) {
      [cefView removeFromSuperview];
    }
    stillAttachedToWindow = (cefView && cefView.window != nil);
  }
  return stillAttachedToWindow;
}

void SXBrowserClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  [[SXEngineRuntime sharedRuntime] noteBrowserClosed];
  [[SXExtensionManager sharedManager] unregisterActiveBrowser:browser];
  devtools_registration_ = nullptr;
  browser_ = nullptr;
  pending_save_dialog_downloads_.clear();
  started_download_ids_.clear();

  SXBrowserTab* strongTab = RetainTab();
  DetachTab();
  if (strongTab) {
    if ([NSThread isMainThread]) {
      [strongTab handleBrowserClosed];
    } else {
      dispatch_async(dispatch_get_main_queue(), ^{
        [strongTab handleBrowserClosed];
      });
    }
  }
}

#pragma mark - CefDisplayHandler

void SXBrowserClient::OnAddressChange(CefRefPtr<CefBrowser> browser,
                                      CefRefPtr<CefFrame> frame,
                                      const CefString& url) {
  CEF_REQUIRE_UI_THREAD();
  if (!frame || !frame->IsMain()) {
    return;
  }
  NSString* urlStr = NSStringFromCefString(url);
  if ([urlStr hasPrefix:@"chrome-error://"]) {
    return;
  }
  // Preserve `view-source:` prefix when Chromium reports the underlying document URL.
  if (browser && browser->GetHost()) {
    CefRefPtr<CefNavigationEntry> nav = browser->GetHost()->GetVisibleNavigationEntry();
    if (nav && nav->IsValid()) {
      std::string displayStr = nav->GetDisplayURL().ToString();
      if (displayStr.rfind("view-source:", 0) == 0) {
        urlStr = [NSString stringWithUTF8String:displayStr.c_str()];
      } else {
        std::string origStr = nav->GetOriginalURL().ToString();
        if (origStr.rfind("view-source:", 0) == 0) {
          urlStr = [NSString stringWithUTF8String:origStr.c_str()];
        }
      }
    }
  }
  NSURL* nsURL = [NSURL URLWithString:urlStr];
  if (!nsURL) {
    return;
  }
  std::string urlUtf8 = urlStr.UTF8String ? std::string(urlStr.UTF8String) : "";
  bool skipSecurityUpdate = false;
  {
    std::lock_guard<std::mutex> lock(nav_privacy_mutex_);
    committed_main_url_ = urlUtf8;
    skipSecurityUpdate = (!last_cert_error_url_.empty() && last_cert_error_url_ == urlUtf8);
  }
  if (!skipSecurityUpdate) {
    UpdateConnectionSecurityForMainURL(urlUtf8);
  }
  SXBrowserTab* strongTab = RetainTab();
  if (strongTab) {
    EmitNavigationEntryIDs(browser, strongTab);
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongTab handleURLChanged:nsURL];
    });
  }
}

void SXBrowserClient::OnTitleChange(CefRefPtr<CefBrowser> browser,
                                    const CefString& title) {
  CEF_REQUIRE_UI_THREAD();
  NSString* titleStr = NSStringFromCefString(title);
  SXBrowserTab* strongTab = RetainTab();
  if (strongTab) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongTab handleTitleChanged:titleStr];
    });
  }
}

void SXBrowserClient::OnFaviconURLChange(
    CefRefPtr<CefBrowser> browser,
    const std::vector<CefString>& icon_urls) {
  CEF_REQUIRE_UI_THREAD();
  if (icon_urls.empty() || !browser || !browser->GetHost()) {
    return;
  }
  SXBrowserTab* strongTab = RetainTab();
  if (!strongTab) {
    return;
  }

  // Prefer crisp transparent tab icons (`.svg`, standard `icon`/`favicon` PNG/ICO)
  // ahead of opaque `apple-touch-icon` / `mask-icon` blobs.
  std::vector<CefString> ranked = icon_urls;
  auto scoreIconURL = [](const CefString& cefUrl) -> int {
    std::string u = cefUrl.ToString();
    for (char& ch : u) {
      if (ch >= 'A' && ch <= 'Z') ch = (char)(ch - 'A' + 'a');
    }
    int score = 50;
    if (u.find("apple-touch-icon") != std::string::npos ||
        u.find("touch-icon") != std::string::npos) {
      score -= 40;
    }
    if (u.find("mask-icon") != std::string::npos) {
      score -= 35;
    }
    if (u.find(".svg") != std::string::npos || u.find("image/svg") != std::string::npos) {
      score += 30;
    } else if (u.find(".png") != std::string::npos) {
      score += 20;
    } else if (u.find(".ico") != std::string::npos) {
      score += 12;
    }
    if (u.find("32x32") != std::string::npos || u.find("48x48") != std::string::npos ||
        u.find("64x64") != std::string::npos || u.find("32") != std::string::npos) {
      score += 10;
    }
    if (u.find("favicon") != std::string::npos) {
      score += 6;
    }
    return score;
  };
  std::stable_sort(ranked.begin(), ranked.end(),
                   [&](const CefString& a, const CefString& b) {
                     return scoreIconURL(a) > scoreIconURL(b);
                   });

  NSUInteger gen = [strongTab currentFaviconGeneration];
  browser->GetHost()->DownloadImage(
      ranked.front(), true, 64, false,
      new SXFaviconDownloadCallback(strongTab, browser, std::move(ranked), 0, gen));
}

void SXBrowserClient::OnLoadingProgressChange(CefRefPtr<CefBrowser> browser,
                                              double progress) {
  CEF_REQUIRE_UI_THREAD();
  SXBrowserTab* strongTab = RetainTab();
  if (strongTab) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongTab handleProgressChanged:progress];
    });
  }
}

#pragma mark - CefLoadHandler

void SXBrowserClient::OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                                           bool isLoading,
                                           bool canGoBack,
                                           bool canGoForward) {
  CEF_REQUIRE_UI_THREAD();
  if (getenv("SAFARIUM_CEF_DEBUG")) {
    fprintf(stderr, "[BrowserCore] OnLoadingStateChange loading=%d\n", isLoading ? 1 : 0);
    fflush(stderr);
  }
  SXBrowserTab* strongTab = RetainTab();
  if (strongTab) {
    EmitNavigationEntryIDs(browser, strongTab);
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongTab handleLoadingStateChanged:isLoading ? YES : NO
                                 canGoBack:canGoBack ? YES : NO
                              canGoForward:canGoForward ? YES : NO];
    });
  }
}

void SXBrowserClient::OnLoadStart(CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefFrame> frame,
                                  TransitionType transition_type) {
  CEF_REQUIRE_UI_THREAD();
  (void)transition_type;
  if (!frame) {
    return;
  }

  // Push latest privacy policy snapshot to every committed frame (main frame & OOPIF subframes).
  if (frame->IsValid()) {
    CefRefPtr<CefDictionaryValue> cfg =
        SXBuildPrivacyConfigUpdateDictionary(is_incognito_.load(std::memory_order_acquire));
    if (cfg) {
      CefRefPtr<CefProcessMessage> cfgMsg = CefProcessMessage::Create("sx_privacy_config_update");
      cfgMsg->GetArgumentList()->SetDictionary(0, cfg);
      frame->SendProcessMessage(PID_RENDERER, cfgMsg);
    }
  }

  if (!frame->IsMain()) {
    return;
  }
  std::string startUrl = frame->GetURL().ToString();
  if (startUrl.rfind("chrome-error://", 0) == 0) {
    return;
  }

  std::string normHost = sx::privacy::NormalizeHost(sx::privacy::ExtractHostFromURL(startUrl));
  bool committedUpgrade = false;
  {
    std::lock_guard<std::mutex> lock(nav_privacy_mutex_);
    committed_main_url_ = startUrl;
    last_cert_error_url_.clear();
    suppressed_fallback_error_url_.clear();
    reported_cookie_blocks_.clear();
    if (pending_upgraded_urls_.count(startUrl) > 0) {
      upgraded_committed_url_ = startUrl;
      committedUpgrade = true;
    } else {
      upgraded_committed_url_.clear();
    }
  }
  UpdateConnectionSecurityForMainURL(startUrl);

  if (committedUpgrade && !normHost.empty()) {
    std::string reg = sx::privacy::RegistrableDomain(normHost);
    EmitPrivacyEventOnMainThread("httpsUpgraded",
                                 normHost,
                                 normHost,
                                 reg,
                                 reg,
                                 "httpsUpgrade",
                                 "Upgraded HTTP to HTTPS",
                                 1);
  }

  std::string scheme = sx::privacy::ExtractSchemeFromURL(startUrl);
  if (scheme == "http" || scheme == "https") {
    if (!normHost.empty()) {
      EmitPrivacyEventOnMainThread("pageVisited",
                                   normHost,
                                   "",
                                   sx::privacy::RegistrableDomain(normHost),
                                   "",
                                   "other",
                                   "",
                                   1);
    }
  }

  SXBrowserTab* strongTab = RetainTab();
  if (strongTab) {
    if ([NSThread isMainThread]) {
      [strongTab handleMainFrameLoadStart];
    } else {
      dispatch_async(dispatch_get_main_queue(), ^{
        [strongTab handleMainFrameLoadStart];
      });
    }
  }
}

void SXBrowserClient::OnLoadEnd(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                int httpStatusCode) {
  CEF_REQUIRE_UI_THREAD();
  if (getenv("SAFARIUM_CEF_DEBUG")) {
    fprintf(stderr, "[BrowserCore] OnLoadEnd main=%d status=%d\n",
            (frame && frame->IsMain()) ? 1 : 0, httpStatusCode);
    fflush(stderr);
  }
  if (!frame || !frame->IsMain()) {
    return;
  }

  {
    std::lock_guard<std::mutex> lock(nav_privacy_mutex_);
    pending_upgraded_urls_.clear();
  }

  // Enforce per-page runtime preferences on main-frame load completion:
  // 1) Global Privacy Control (`navigator.globalPrivacyControl`)
  // 2) Websites -> Auto-Play policy (0=Allow All, 1=Stop Media with Sound, 2=Never Auto-Play)
  // 3) Advanced -> Custom CSS Style Sheet
  // 4) Advanced -> Press Tab to highlight each item on a webpage
  NSString* pageUrlStr = NSStringFromCefString(frame->GetURL());
  if ([pageUrlStr hasPrefix:@"chrome-error://"]) {
    // Erase Chromium's built-in "This site can't be reached" page completely so it can never be seen.
    frame->ExecuteJavaScript(
        "(function(){try{document.documentElement.innerHTML='<head></head><body style=\"margin:0;background:#F5F5F7;\"></body>';}catch(_){}})();",
        frame->GetURL(), 0);
    return;
  }
  if ([pageUrlStr hasPrefix:@"http://"] || [pageUrlStr hasPrefix:@"https://"]) {
    NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
    NSString* host = NormalizedHostFromURLString(pageUrlStr);
    NSMutableString* js = [NSMutableString string];

    NSInteger autoPlayPolicy = SitePolicyIndexForCategory(@"Auto-Play", host, 1);
    if (autoPlayPolicy == 1 || autoPlayPolicy == 2) {
      [js appendFormat:
        @"(function(){const mode=%ld;let interacted=false;"
        @"const mark=()=>{interacted=true;};"
        @"['pointerdown','keydown','click'].forEach(e=>window.addEventListener(e,mark,{capture:true,once:true,passive:true}));"
        @"const enforce=(m)=>{if(!m||interacted)return;if(mode===2){if(!m.paused)try{m.pause();}catch(_){}}else if(mode===1){if(!m.muted&&!m.paused){m.muted=true;}}};"
        @"document.querySelectorAll('video,audio').forEach(enforce);"
        @"window.addEventListener('play',e=>enforce(e.target),true);"
        @"})();",
        (long)autoPlayPolicy];
    }

    if ([ud integerForKey:@"Safarium.Pref.CustomStyleSheet"] == 1) {
      NSString* cssPath = [ud stringForKey:@"Safarium.Pref.CustomStyleSheetPath"];
      if (cssPath.length > 0) {
        std::string pathStd(cssPath.UTF8String);
        NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:cssPath error:nil];
        double mtime = [attrs.fileModificationDate timeIntervalSince1970];
        std::string jsonArrStd;
        {
          std::lock_guard<std::mutex> lock(css_cache_mutex_);
          if (cached_css_path_ == pathStd && cached_css_mtime_ == mtime && !cached_css_json_arr_.empty()) {
            jsonArrStd = cached_css_json_arr_;
          } else {
            NSString* css = [NSString stringWithContentsOfFile:cssPath encoding:NSUTF8StringEncoding error:nil];
            if (css.length > 0 && css.length < 512000) {
              NSData* jsonData = [NSJSONSerialization dataWithJSONObject:@[css] options:0 error:nil];
              if (jsonData) {
                jsonArrStd.assign((const char*)jsonData.bytes, jsonData.length);
              }
            }
            cached_css_path_ = pathStd;
            cached_css_mtime_ = mtime;
            cached_css_json_arr_ = jsonArrStd;
          }
        }
        if (!jsonArrStd.empty()) {
          NSString* jsonArr = [NSString stringWithUTF8String:jsonArrStd.c_str()];
          if (jsonArr.length > 0) {
            [js appendFormat:
              @"(function(){try{let s=document.getElementById('__sx_user_stylesheet__');if(!s){s=document.createElement('style');s.id='__sx_user_stylesheet__';(document.head||document.documentElement).appendChild(s);}s.textContent=(%@)[0];}catch(_){}})();",
              jsonArr];
          }
        }
      }
    }

    if ([ud boolForKey:@"Safarium.Pref.TabHighlightsAll"]) {
      [js appendString:
        @"(function(){try{document.querySelectorAll('a[href],button,input,select,textarea,summary,[role=\"button\"],[role=\"link\"]').forEach(el=>{if(!el.hasAttribute('tabindex'))el.setAttribute('tabindex','0');});}catch(_){}})();"];
    }

    if (js.length > 0) {
      frame->ExecuteJavaScript(CefString(js.UTF8String), frame->GetURL(), 0);
    }
  }

  SXBrowserTab* strongTab = RetainTab();
  if (strongTab) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongTab handleMainFrameLoadEnd:httpStatusCode];
    });
  }
}

void SXBrowserClient::OnLoadError(CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefFrame> frame,
                                  ErrorCode errorCode,
                                  const CefString& errorText,
                                  const CefString& failedUrl) {
  CEF_REQUIRE_UI_THREAD();
  if (!frame || !frame->IsMain() || errorCode == ERR_ABORTED) {
    return;
  }

  std::string failedUtf8 = failedUrl.ToString();
  {
    std::lock_guard<std::mutex> lock(nav_privacy_mutex_);
    if (!suppressed_fallback_error_url_.empty() && suppressed_fallback_error_url_ == failedUtf8) {
      suppressed_fallback_error_url_.clear();
      return;
    }
  }

  std::string scheme = sx::privacy::ExtractSchemeFromURL(failedUtf8);
  std::string normHost = sx::privacy::NormalizeHost(sx::privacy::ExtractHostFromURL(failedUtf8));

  if (scheme == "https" && !normHost.empty() && IsUpgradeFallbackErrorCode(errorCode)) {
    std::string fallbackHttpUrl;
    {
      std::lock_guard<std::mutex> lock(nav_privacy_mutex_);
      auto it = pending_upgraded_urls_.find(failedUtf8);
      if (it != pending_upgraded_urls_.end()) {
        fallbackHttpUrl = it->second;
        pending_upgraded_urls_.erase(it);
      }
    }
    if (!fallbackHttpUrl.empty()) {
      const bool isPrivate = is_incognito_.load(std::memory_order_acquire);
      sx::privacy::SXPrivacyEngine::Shared().AddSessionHTTPSFallbackHost(normHost, isPrivate);
      frame->LoadURL(CefString(fallbackHttpUrl));
      return;
    }
  }

  if (scheme == "https" && IsCertificateErrorCode(errorCode)) {
    {
      std::lock_guard<std::mutex> lock(nav_privacy_mutex_);
      last_cert_error_url_ = failedUtf8;
    }
    SXConnectionSecurityState certState = SXConnectionSecurityStateCertificateError;
    UpdateConnectionSecurityForMainURL(failedUtf8, &certState);
  }

  NSString* errText = NSStringFromCefString(errorText);
  NSString* urlStr = NSStringFromCefString(failedUrl);
  NSURL* url = [NSURL URLWithString:urlStr] ?: [NSURL URLWithString:@"about:blank"];
  NSInteger code = (NSInteger)errorCode;
  SXBrowserTab* strongTab = RetainTab();
  if (strongTab) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongTab handleMainFrameLoadError:code errorText:errText failedURL:url];
    });
  }
}

#pragma mark - CefDownloadHandler

#pragma mark - CefContextMenuHandler

namespace {

enum SXContextMenuID : int {
  kSXMenuBack = MENU_ID_USER_FIRST + 1,
  kSXMenuForward,
  kSXMenuReload,
  kSXMenuShowSource,
  kSXMenuSavePageAs,
  kSXMenuPrintPage,
  kSXMenuInspectElement,

  kSXMenuOpenLinkNewTab,
  kSXMenuOpenLinkNewWindow,
  kSXMenuDownloadLinkedFile,
  kSXMenuDownloadLinkedFileAs,
  kSXMenuCopyLink,
  kSXMenuShareLink,

  kSXMenuOpenImageNewTab,
  kSXMenuOpenImageNewWindow,
  kSXMenuSaveImageToDownloads,
  kSXMenuSaveImageAs,
  kSXMenuCopyImageAddress,
  kSXMenuCopyImage,
  kSXMenuShareImage,

  kSXMenuLookUp,
  kSXMenuSearchGoogle,
  kSXMenuCopySelection,
  kSXMenuCopyLinkWithHighlight,
  kSXMenuShareSelection,
  kSXMenuSpeechSubmenu,
  kSXMenuStartSpeaking,
  kSXMenuStopSpeaking,

  kSXMenuUndo,
  kSXMenuRedo,
  kSXMenuCut,
  kSXMenuPaste,
  kSXMenuPasteAndMatchStyle,
  kSXMenuSelectAll,

  kSXMenuExtensionBase = MENU_ID_USER_FIRST + 200
};

static NSSpeechSynthesizer* SXSharedSpeechSynthesizer() {
  static NSSpeechSynthesizer* synth = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    synth = [[NSSpeechSynthesizer alloc] initWithVoice:nil];
  });
  return synth;
}

static NSString* SXTruncatedSelectionForMenu(NSString* text) {
  NSString* trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  trimmed = [[trimmed componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
  if (trimmed.length > 28) {
    return [[trimmed substringToIndex:28] stringByAppendingString:@"…"];
  }
  return trimmed;
}

static void SXAppendExtensionSubmenuItems(
    CefRefPtr<CefMenuModel> targetMenu,
    NSArray<SXExtensionContextMenuItem*>* items,
    const std::string& extId,
    int& nextCmdId,
    std::unordered_map<int, std::pair<std::string, std::string>>& cmdMap) {
  for (SXExtensionContextMenuItem* item in items) {
    if (item.isSeparator) {
      targetMenu->AddSeparator();
      continue;
    }
    if (item.children.count > 0) {
      int subId = nextCmdId++;
      CefRefPtr<CefMenuModel> sub = targetMenu->AddSubMenu(subId, CefString(item.title.UTF8String));
      if (sub) {
        SXAppendExtensionSubmenuItems(sub, item.children, extId, nextCmdId, cmdMap);
      }
    } else {
      int cmdId = nextCmdId++;
      targetMenu->AddItem(cmdId, CefString(item.title.UTF8String));
      targetMenu->SetEnabled(cmdId, item.isEnabled);
      cmdMap[cmdId] = {extId, item.itemID.UTF8String};
    }
  }
}

static void SXShowSharePickerForItems(NSArray* shareItems, SXBrowserTab* tab, int x, int y) {
  if (!shareItems.count) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    NSView* view = tab ? tab.contentView : (NSApp.keyWindow.contentView);
    if (!view) return;
    CGFloat vy = view.isFlipped ? (CGFloat)y : (view.bounds.size.height - (CGFloat)y);
    NSRect rect = NSMakeRect((CGFloat)x, vy, 1, 1);
    NSSharingServicePicker* picker = [[NSSharingServicePicker alloc] initWithItems:shareItems];
    [picker showRelativeToRect:rect ofView:view preferredEdge:NSRectEdgeMinY];
  });
}

}  // namespace

void SXBrowserClient::OnBeforeContextMenu(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefContextMenuParams> params,
    CefRefPtr<CefMenuModel> model) {
  CEF_REQUIRE_UI_THREAD();
  if (!browser || !params || !model) return;

  ext_menu_commands_.clear();
  model->Clear();

  const bool isEditable = params->IsEditable();
  const CefString linkCef = params->GetLinkUrl();
  const bool hasLink = !linkCef.empty();
  const bool hasImage = (params->GetMediaType() == CM_MEDIATYPE_IMAGE) && !params->GetSourceUrl().empty();
  const CefString selCef = params->GetSelectionText();
  const bool hasSelection = !selCef.empty();
  const int editFlags = params->GetEditStateFlags();

  if (isEditable) {
    if (hasSelection) {
      NSString* selStr = SXTruncatedSelectionForMenu(NSStringFromCefString(selCef));
      if (selStr.length > 0) {
        model->AddItem(kSXMenuLookUp, CefString([[NSString stringWithFormat:@"Look Up “%@”", selStr] UTF8String]));
        model->AddItem(kSXMenuSearchGoogle, "Search with Google");
        model->AddSeparator();
      }
    }
    model->AddItem(kSXMenuUndo, "Undo");
    model->SetEnabled(kSXMenuUndo, (editFlags & CM_EDITFLAG_CAN_UNDO) != 0);
    model->AddItem(kSXMenuRedo, "Redo");
    model->SetEnabled(kSXMenuRedo, (editFlags & CM_EDITFLAG_CAN_REDO) != 0);
    model->AddSeparator();
    model->AddItem(kSXMenuCut, "Cut");
    model->SetEnabled(kSXMenuCut, (editFlags & CM_EDITFLAG_CAN_CUT) != 0);
    model->AddItem(kSXMenuCopySelection, "Copy");
    model->SetEnabled(kSXMenuCopySelection, (editFlags & CM_EDITFLAG_CAN_COPY) != 0);
    model->AddItem(kSXMenuPaste, "Paste");
    model->SetEnabled(kSXMenuPaste, (editFlags & CM_EDITFLAG_CAN_PASTE) != 0);
    model->AddItem(kSXMenuPasteAndMatchStyle, "Paste and Match Style");
    model->SetEnabled(kSXMenuPasteAndMatchStyle, (editFlags & CM_EDITFLAG_CAN_PASTE) != 0);
    model->AddItem(kSXMenuSelectAll, "Select All");
    model->SetEnabled(kSXMenuSelectAll, (editFlags & CM_EDITFLAG_CAN_SELECT_ALL) != 0);
  } else if (hasLink || hasImage) {
    if (hasLink) {
      model->AddItem(kSXMenuOpenLinkNewTab, "Open Link in New Tab");
      model->AddItem(kSXMenuOpenLinkNewWindow, "Open Link in New Window");
      model->AddSeparator();
      model->AddItem(kSXMenuDownloadLinkedFile, "Download Linked File");
      model->AddItem(kSXMenuDownloadLinkedFileAs, "Download Linked File As…");
      model->AddSeparator();
      model->AddItem(kSXMenuCopyLink, "Copy Link");
    }
    if (hasImage) {
      if (hasLink) model->AddSeparator();
      model->AddItem(kSXMenuOpenImageNewTab, "Open Image in New Tab");
      model->AddItem(kSXMenuOpenImageNewWindow, "Open Image in New Window");
      model->AddSeparator();
      model->AddItem(kSXMenuSaveImageToDownloads, "Save Image to “Downloads”");
      model->AddItem(kSXMenuSaveImageAs, "Save Image As…");
      model->AddSeparator();
      model->AddItem(kSXMenuCopyImageAddress, "Copy Image Address");
      model->AddItem(kSXMenuCopyImage, "Copy Image");
    }
    model->AddSeparator();
    model->AddItem(hasImage ? kSXMenuShareImage : kSXMenuShareLink, "Share…");
  } else if (hasSelection) {
    NSString* selStr = SXTruncatedSelectionForMenu(NSStringFromCefString(selCef));
    if (selStr.length > 0) {
      model->AddItem(kSXMenuLookUp, CefString([[NSString stringWithFormat:@"Look Up “%@”", selStr] UTF8String]));
      model->AddItem(kSXMenuSearchGoogle, "Search with Google");
      model->AddSeparator();
    }
    model->AddItem(kSXMenuCopySelection, "Copy");
    model->AddItem(kSXMenuCopyLinkWithHighlight, "Copy Link with Highlight");
    model->AddSeparator();
    model->AddItem(kSXMenuShareSelection, "Share…");
    model->AddSeparator();
    CefRefPtr<CefMenuModel> speechSub = model->AddSubMenu(kSXMenuSpeechSubmenu, "Speech");
    if (speechSub) {
      speechSub->AddItem(kSXMenuStartSpeaking, "Start Speaking");
      speechSub->AddItem(kSXMenuStopSpeaking, "Stop Speaking");
      speechSub->SetEnabled(kSXMenuStopSpeaking, [SXSharedSpeechSynthesizer() isSpeaking]);
    }
  } else {
    // Plain page background (matches native macOS Safari page context menu)
    model->AddItem(kSXMenuBack, "Back");
    model->SetEnabled(kSXMenuBack, browser->CanGoBack());
    if (browser->CanGoForward()) {
      model->AddItem(kSXMenuForward, "Forward");
    }
    model->AddItem(kSXMenuReload, "Reload Page");
    model->AddSeparator();
    model->AddItem(kSXMenuShowSource, "Show Page Source");
    model->AddItem(kSXMenuSavePageAs, "Save Page As…");
    model->AddSeparator();
    model->AddItem(kSXMenuPrintPage, "Print Page…");
  }

  // Append live installed extension context menus (e.g. Bitwarden, uBlock)
  NSArray<SXExtensionItem*>* extensions = [[SXExtensionManager sharedManager] installedExtensions];
  int nextExtCmd = kSXMenuExtensionBase;
  bool addedExtSep = false;
  for (SXExtensionItem* ext in extensions) {
    if (!ext.isEnabled) continue;
    NSArray<SXExtensionContextMenuItem*>* items =
        [[SXExtensionManager sharedManager] contextMenuItemsForExtensionID:ext.extensionID];
    if (!items.count) continue;
    if (!addedExtSep) {
      model->AddSeparator();
      addedExtSep = true;
    }
    int subId = nextExtCmd++;
    CefRefPtr<CefMenuModel> extSub = model->AddSubMenu(subId, CefString(ext.name.UTF8String));
    if (extSub) {
      SXAppendExtensionSubmenuItems(extSub, items, ext.extensionID.UTF8String, nextExtCmd, ext_menu_commands_);
    }
  }

  model->AddSeparator();
  model->AddItem(kSXMenuInspectElement, "Inspect Element");
}

bool SXBrowserClient::OnContextMenuCommand(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefContextMenuParams> params,
    int command_id,
    EventFlags event_flags) {
  CEF_REQUIRE_UI_THREAD();
  (void)event_flags;
  if (!browser || !params) return false;

  CefRefPtr<CefFrame> activeFrame = frame ? frame : browser->GetMainFrame();
  SXBrowserTab* strongTab = RetainTab();

  // Handle extension context menu items
  auto extIt = ext_menu_commands_.find(command_id);
  if (extIt != ext_menu_commands_.end()) {
    NSString* extID = [NSString stringWithUTF8String:extIt->second.first.c_str()];
    NSString* itemID = [NSString stringWithUTF8String:extIt->second.second.c_str()];
    NSString* pageURLStr = NSStringFromCefString(params->GetPageUrl());
    NSURL* pageURL = pageURLStr.length > 0 ? [NSURL URLWithString:pageURLStr] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
      [[SXExtensionManager sharedManager] triggerContextMenuItemWithID:itemID
                                                        forExtensionID:extID
                                                               pageURL:pageURL];
    });
    return true;
  }

  switch (command_id) {
    case kSXMenuBack:
      if (browser->CanGoBack()) browser->GoBack();
      return true;
    case kSXMenuForward:
      if (browser->CanGoForward()) browser->GoForward();
      return true;
    case kSXMenuReload:
      browser->Reload();
      return true;
    case kSXMenuShowSource:
      if (activeFrame) activeFrame->ViewSource();
      return true;
    case kSXMenuSavePageAs: {
      if (strongTab) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [strongTab savePageWithPanelForWindow:strongTab.contentView.window completion:nil];
        });
      }
      return true;
    }
    case kSXMenuPrintPage:
      if (browser->GetHost()) browser->GetHost()->Print();
      return true;
    case kSXMenuInspectElement: {
      if (strongTab) {
        NSPoint pt = NSMakePoint((CGFloat)params->GetXCoord(), (CGFloat)params->GetYCoord());
        dispatch_async(dispatch_get_main_queue(), ^{
          [strongTab showDevToolsAtPoint:pt];
        });
      }
      return true;
    }

    case kSXMenuOpenLinkNewTab: {
      NSString* linkStr = NSStringFromCefString(params->GetLinkUrl());
      NSURL* url = linkStr.length > 0 ? [NSURL URLWithString:linkStr] : nil;
      if (url) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [[SXEngineRuntime sharedRuntime] postNewTabRequestForURL:url];
        });
      }
      return true;
    }
    case kSXMenuOpenLinkNewWindow: {
      NSString* linkStr = NSStringFromCefString(params->GetLinkUrl());
      NSURL* url = linkStr.length > 0 ? [NSURL URLWithString:linkStr] : nil;
      if (url) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [[SXEngineRuntime sharedRuntime] postNewWindowRequestForURL:url];
        });
      }
      return true;
    }
    case kSXMenuDownloadLinkedFile: {
      std::string linkUrl = params->GetLinkUrl().ToString();
      if (!linkUrl.empty() && browser->GetHost()) {
        browser->GetHost()->StartDownload(CefString(linkUrl));
      }
      return true;
    }
    case kSXMenuDownloadLinkedFileAs: {
      std::string linkUrl = params->GetLinkUrl().ToString();
      if (!linkUrl.empty() && browser->GetHost()) {
        force_save_dialog_url_ = linkUrl;
        browser->GetHost()->StartDownload(CefString(linkUrl));
      }
      return true;
    }
    case kSXMenuCopyLink: {
      NSString* linkStr = NSStringFromCefString(params->GetLinkUrl());
      if (linkStr.length > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
          NSPasteboard* pb = [NSPasteboard generalPasteboard];
          [pb clearContents];
          [pb setString:linkStr forType:NSPasteboardTypeString];
          NSURL* u = [NSURL URLWithString:linkStr];
          if (u) [pb writeObjects:@[u]];
        });
      }
      return true;
    }
    case kSXMenuShareLink: {
      NSString* linkStr = NSStringFromCefString(params->GetLinkUrl());
      NSURL* u = linkStr.length > 0 ? [NSURL URLWithString:linkStr] : nil;
      if (u) SXShowSharePickerForItems(@[u], strongTab, params->GetXCoord(), params->GetYCoord());
      return true;
    }

    case kSXMenuOpenImageNewTab: {
      NSString* imgStr = NSStringFromCefString(params->GetSourceUrl());
      NSURL* url = imgStr.length > 0 ? [NSURL URLWithString:imgStr] : nil;
      if (url) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [[SXEngineRuntime sharedRuntime] postNewTabRequestForURL:url];
        });
      }
      return true;
    }
    case kSXMenuOpenImageNewWindow: {
      NSString* imgStr = NSStringFromCefString(params->GetSourceUrl());
      NSURL* url = imgStr.length > 0 ? [NSURL URLWithString:imgStr] : nil;
      if (url) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [[SXEngineRuntime sharedRuntime] postNewWindowRequestForURL:url];
        });
      }
      return true;
    }
    case kSXMenuSaveImageToDownloads: {
      std::string imgUrl = params->GetSourceUrl().ToString();
      if (!imgUrl.empty() && browser->GetHost()) {
        browser->GetHost()->StartDownload(CefString(imgUrl));
      }
      return true;
    }
    case kSXMenuSaveImageAs: {
      std::string imgUrl = params->GetSourceUrl().ToString();
      if (!imgUrl.empty() && browser->GetHost()) {
        force_save_dialog_url_ = imgUrl;
        browser->GetHost()->StartDownload(CefString(imgUrl));
      }
      return true;
    }
    case kSXMenuCopyImageAddress: {
      NSString* imgStr = NSStringFromCefString(params->GetSourceUrl());
      if (imgStr.length > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
          NSPasteboard* pb = [NSPasteboard generalPasteboard];
          [pb clearContents];
          [pb setString:imgStr forType:NSPasteboardTypeString];
        });
      }
      return true;
    }
    case kSXMenuCopyImage: {
      NSString* imgStr = NSStringFromCefString(params->GetSourceUrl());
      NSURL* url = imgStr.length > 0 ? [NSURL URLWithString:imgStr] : nil;
      if (url) {
        NSURLSessionDataTask* task = [[NSURLSession sharedSession]
            dataTaskWithURL:url
          completionHandler:^(NSData* data, NSURLResponse* resp, NSError* err) {
            (void)resp;
            if (err || !data.length) return;
            NSImage* img = [[NSImage alloc] initWithData:data];
            if (!img) return;
            dispatch_async(dispatch_get_main_queue(), ^{
              NSPasteboard* pb = [NSPasteboard generalPasteboard];
              [pb clearContents];
              [pb writeObjects:@[img]];
            });
          }];
        [task resume];
      }
      return true;
    }
    case kSXMenuShareImage: {
      NSString* imgStr = NSStringFromCefString(params->GetSourceUrl());
      NSURL* u = imgStr.length > 0 ? [NSURL URLWithString:imgStr] : nil;
      if (u) SXShowSharePickerForItems(@[u], strongTab, params->GetXCoord(), params->GetYCoord());
      return true;
    }

    case kSXMenuLookUp: {
      NSString* selStr = NSStringFromCefString(params->GetSelectionText());
      if (selStr.length > 0) {
        int x = params->GetXCoord();
        int y = params->GetYCoord();
        dispatch_async(dispatch_get_main_queue(), ^{
          NSView* view = strongTab ? strongTab.contentView : NSApp.keyWindow.contentView;
          if (!view) return;
          CGFloat vy = view.isFlipped ? (CGFloat)y : (view.bounds.size.height - (CGFloat)y);
          NSAttributedString* attr = [[NSAttributedString alloc] initWithString:selStr];
          [view showDefinitionForAttributedString:attr atPoint:NSMakePoint((CGFloat)x, vy)];
        });
      }
      return true;
    }
    case kSXMenuSearchGoogle: {
      NSString* selStr = NSStringFromCefString(params->GetSelectionText());
      NSString* encoded = [selStr stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
      if (encoded.length > 0) {
        NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.google.com/search?q=%@", encoded]];
        if (url) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [[SXEngineRuntime sharedRuntime] postNewTabRequestForURL:url];
          });
        }
      }
      return true;
    }
    case kSXMenuCopySelection:
      if (activeFrame) activeFrame->Copy();
      return true;
    case kSXMenuCopyLinkWithHighlight: {
      NSString* pageStr = NSStringFromCefString(params->GetPageUrl());
      NSString* selStr = [NSStringFromCefString(params->GetSelectionText())
          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
      NSString* encoded = [selStr stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLFragmentAllowedCharacterSet]];
      if (pageStr.length > 0 && encoded.length > 0) {
        NSRange hashRange = [pageStr rangeOfString:@"#"];
        NSString* base = (hashRange.location != NSNotFound) ? [pageStr substringToIndex:hashRange.location] : pageStr;
        NSString* full = [NSString stringWithFormat:@"%@#:~:text=%@", base, encoded];
        dispatch_async(dispatch_get_main_queue(), ^{
          NSPasteboard* pb = [NSPasteboard generalPasteboard];
          [pb clearContents];
          [pb setString:full forType:NSPasteboardTypeString];
        });
      }
      return true;
    }
    case kSXMenuShareSelection: {
      NSString* selStr = NSStringFromCefString(params->GetSelectionText());
      if (selStr.length > 0) {
        SXShowSharePickerForItems(@[selStr], strongTab, params->GetXCoord(), params->GetYCoord());
      }
      return true;
    }
    case kSXMenuStartSpeaking: {
      NSString* selStr = NSStringFromCefString(params->GetSelectionText());
      if (selStr.length > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [SXSharedSpeechSynthesizer() startSpeakingString:selStr];
        });
      }
      return true;
    }
    case kSXMenuStopSpeaking:
      dispatch_async(dispatch_get_main_queue(), ^{
        [SXSharedSpeechSynthesizer() stopSpeaking];
      });
      return true;

    case kSXMenuUndo:
      if (activeFrame) activeFrame->Undo();
      return true;
    case kSXMenuRedo:
      if (activeFrame) activeFrame->Redo();
      return true;
    case kSXMenuCut:
      if (activeFrame) activeFrame->Cut();
      return true;
    case kSXMenuPaste:
      if (activeFrame) activeFrame->Paste();
      return true;
    case kSXMenuPasteAndMatchStyle:
      if (activeFrame) activeFrame->PasteAndMatchStyle();
      return true;
    case kSXMenuSelectAll:
      if (activeFrame) activeFrame->SelectAll();
      return true;

    default:
      return false;
  }
}

bool SXBrowserClient::OnBeforeDownload(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    const CefString& suggested_name,
    CefRefPtr<CefBeforeDownloadCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  if (!download_item || !callback) {
    return false;
  }

  // Enforce Websites -> Downloads policy only if explicitly Denied (1). Default is Allow (2) — no nag prompt!
  NSString* pageHost = (browser && browser->GetMainFrame())
                           ? NormalizedHostFromURLString(NSStringFromCefString(browser->GetMainFrame()->GetURL()))
                           : @"";
  if (pageHost.length == 0) {
    pageHost = NormalizedHostFromURLString(NSStringFromCefString(download_item->GetURL()));
  }
  NSInteger dlPolicy = SitePolicyIndexForCategory(@"Downloads", pageHost, 2);
  if (dlPolicy == 1) {
    return true;  // Explicitly denied in Websites Settings
  }

  NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
  NSInteger dlMode = [ud objectForKey:@"Safarium.Pref.DownloadLocation"] ? [ud integerForKey:@"Safarium.Pref.DownloadLocation"] : 0;
  bool showSaveDialog = (dlMode == 2);
  std::string dlURL = download_item->GetURL().ToString();
  if (!force_save_dialog_url_.empty() && dlURL == force_save_dialog_url_) {
    showSaveDialog = true;
    force_save_dialog_url_.clear();
  }

  NSString* suggested = NSStringFromCefString(suggested_name);
  NSString* destPath = UniqueDownloadPath(suggested);
  uint32_t downloadID = download_item->GetId();
  if (showSaveDialog) {
    // Wait until the user actually confirms the Save dialog (indicated by a non-empty full path
    // in OnDownloadUpdated) before notifying didStartDownload. If the user cancels or hasn't
    // clicked Save yet, didStartDownload must NEVER fire.
    pending_save_dialog_downloads_[downloadID] = suggested_name.ToString();
    callback->Continue(CefString(destPath.UTF8String), true);
    return true;
  }

  started_download_ids_.insert(downloadID);
  callback->Continue(CefString(destPath.UTF8String), false);

  SXDownloadItem* item = BuildDownloadItem(download_item, suggested_name, destPath);
  SXBrowserTab* strongTab = RetainTab();
  if (strongTab) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongTab handleDownloadStarted:item];
    });
  }
  return true;
}

void SXBrowserClient::OnDownloadUpdated(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    CefRefPtr<CefDownloadItemCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  if (!download_item) {
    return;
  }
  uint32_t downloadID = download_item->GetId();
  BOOL keepCallback = (download_item->IsInProgress() || download_item->IsPaused() || download_item->IsInterrupted()) &&
                      !download_item->IsComplete() && !download_item->IsCanceled();

  auto pendingIt = pending_save_dialog_downloads_.find(downloadID);
  if (pendingIt != pending_save_dialog_downloads_.end()) {
    bool hasChosenPath = !download_item->GetFullPath().empty();
    if (download_item->IsCanceled() ||
        (!hasChosenPath && !download_item->IsInProgress() && !download_item->IsComplete() && !download_item->IsPaused())) {
      // Save dialog was canceled or download aborted before confirmation — never notify UI.
      pending_save_dialog_downloads_.erase(pendingIt);
      [[SXEngineRuntime sharedRuntime] unregisterDownloadCallbackForDownloadID:downloadID];
      return;
    }
    if (!hasChosenPath) {
      // Save dialog is still open (user hasn't clicked Save yet) — stay silent.
      return;
    }
    // User confirmed the Save dialog and chose a destination path: emit didStartDownload now.
    std::string origSuggested = pendingIt->second;
    pending_save_dialog_downloads_.erase(pendingIt);
    if (keepCallback) {
      started_download_ids_.insert(downloadID);
      if (callback) {
        [[SXEngineRuntime sharedRuntime] registerDownloadCallback:callback
                                                    forDownloadID:downloadID];
      }
    } else {
      [[SXEngineRuntime sharedRuntime] unregisterDownloadCallbackForDownloadID:downloadID];
    }
    SXDownloadItem* item = BuildDownloadItem(download_item, CefString(origSuggested), nil);
    SXBrowserTab* strongTab = RetainTab();
    if (strongTab) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [strongTab handleDownloadStarted:item];
        if (!keepCallback) {
          [strongTab handleDownloadUpdated:item];
        }
      });
    }
    return;
  }

  if (started_download_ids_.count(downloadID) == 0) {
    // Ignore pre-OnBeforeDownload updates or updates for canceled/denied Save dialogs.
    return;
  }

  if (keepCallback && callback) {
    [[SXEngineRuntime sharedRuntime] registerDownloadCallback:callback
                                                forDownloadID:downloadID];
  } else {
    started_download_ids_.erase(downloadID);
    [[SXEngineRuntime sharedRuntime] unregisterDownloadCallbackForDownloadID:downloadID];
  }

  SXDownloadItem* item = BuildDownloadItem(download_item, CefString(), nil);
  SXBrowserTab* strongTab = RetainTab();
  if (strongTab) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongTab handleDownloadUpdated:item];
    });
  }
}

#pragma mark - CefFocusHandler

bool SXBrowserClient::OnSetFocus(CefRefPtr<CefBrowser> browser, FocusSource source) {
  CEF_REQUIRE_UI_THREAD();
  SXBrowserTab* strongTab = RetainTab();
  // Prevent background/hidden tabs from stealing focus on navigation.
  if (strongTab && strongTab.contentView.hidden) {
    return true;  // Cancel focus for hidden tabs.
  }
  return false;  // Allow normal focus for visible tabs.
}

#pragma mark - CefKeyboardHandler

bool SXBrowserClient::OnPreKeyEvent(CefRefPtr<CefBrowser> browser,
                                    const CefKeyEvent& event,
                                    CefEventHandle os_event,
                                    bool* is_keyboard_shortcut) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  (void)os_event;
  (void)is_keyboard_shortcut;
  if (event.type != KEYEVENT_RAWKEYDOWN) {
    return false;
  }
  const uint32_t primaryMask = EVENTFLAG_COMMAND_DOWN | EVENTFLAG_SHIFT_DOWN |
                               EVENTFLAG_ALT_DOWN | EVENTFLAG_CONTROL_DOWN;
  const uint32_t activeMods = (event.modifiers & primaryMask);

  // Cmd+Left (kVK_LeftArrow=123 / VK_LEFT=0x25) & Cmd+Right (kVK_RightArrow=124 / VK_RIGHT=0x27):
  // Navigate Back / Forward when NOT editing a webpage input/textarea/contenteditable field.
  if (activeMods == EVENTFLAG_COMMAND_DOWN && !event.focus_on_editable_field) {
    const bool isLeft = (event.native_key_code == 123 || event.windows_key_code == 0x25);
    const bool isRight = (event.native_key_code == 124 || event.windows_key_code == 0x27);
    if (isLeft || isRight) {
      SXBrowserTab* strongTab = RetainTab();
      if (strongTab) {
        dispatch_async(dispatch_get_main_queue(), ^{
          if (isLeft) {
            [strongTab handleKeyboardNavigateBack];
          } else {
            [strongTab handleKeyboardNavigateForward];
          }
        });
      }
      return true;
    }
  }
  return false;
}

#pragma mark - CefPermissionHandler

bool SXBrowserClient::OnRequestMediaAccessPermission(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    const CefString& requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefMediaAccessCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  if (!callback) return false;
  NSString* host = NormalizedHostFromURLString(NSStringFromCefString(requesting_origin));

  uint32_t allowed = 0;
  bool needsPrompt = false;

  auto checkBit = [&](uint32_t bit, NSString* category) {
    if ((requested_permissions & bit) == 0) return;
    NSInteger policy = SitePolicyIndexForCategory(category, host, 0);  // 0=Ask, 1=Deny, 2=Allow
    if (policy == 2) {
      allowed |= bit;
    } else if (policy == 0) {
      needsPrompt = true;
    }
  };

  checkBit(CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE, @"Camera");
  checkBit(CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE, @"Microphone");
  checkBit(CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE, @"Screen Sharing");
  checkBit(CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE, @"Screen Sharing");

  if (needsPrompt) {
    return false;  // Defer to Chromium's native prompt
  }
  if (allowed != 0) {
    callback->Continue(allowed);
  } else {
    callback->Cancel();
  }
  return true;
}

bool SXBrowserClient::OnShowPermissionPrompt(
    CefRefPtr<CefBrowser> browser,
    uint64_t prompt_id,
    const CefString& requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefPermissionPromptCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  (void)prompt_id;
  if (!callback) return false;
  NSString* host = NormalizedHostFromURLString(NSStringFromCefString(requesting_origin));

  // Evaluate EVERY requested category: a combined prompt (e.g. camera + location) must never be answered from the
  // policy of just one of them, and bits we have no policy for must be decided by the native prompt.
  struct Category { uint32_t bit; NSString* name; NSInteger defaultPolicy; };
  const Category kCategories[] = {
      {CEF_PERMISSION_TYPE_CAMERA_STREAM, @"Camera", 0},
      {CEF_PERMISSION_TYPE_MIC_STREAM, @"Microphone", 0},
      {CEF_PERMISSION_TYPE_GEOLOCATION, @"Location", 0},
      {CEF_PERMISSION_TYPE_NOTIFICATIONS, @"Notifications", 0},
      {CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS, @"Downloads", 2},
  };
  uint32_t handledMask = 0;
  for (const Category& c : kCategories) handledMask |= c.bit;
  if ((requested_permissions & handledMask) == 0 || (requested_permissions & ~handledMask) != 0) return false;

  bool allAllow = true;
  bool anyDeny = false;
  for (const Category& c : kCategories) {
    if ((requested_permissions & c.bit) == 0) continue;
    NSInteger policy = SitePolicyIndexForCategory(c.name, host, c.defaultPolicy);  // 0=Ask, 1=Deny, 2=Allow
    if (policy != 2) allAllow = false;
    if (policy == 1) anyDeny = true;
  }
  if (allAllow) {
    callback->Continue(CEF_PERMISSION_RESULT_ACCEPT);
    return true;
  }
  if (anyDeny) {
    callback->Continue(CEF_PERMISSION_RESULT_DENY);
    return true;
  }
  return false;
}

#pragma mark - CefRequestHandler & CefResourceRequestHandler & CefCookieAccessFilter

bool SXBrowserClient::OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                                     CefRefPtr<CefFrame> frame,
                                     CefRefPtr<CefRequest> request,
                                     bool user_gesture,
                                     bool is_redirect) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  (void)user_gesture;
  if (frame && frame->IsMain() && request) {
    std::string urlUtf8 = request->GetURL().ToString();
    if (!urlUtf8.empty() && urlUtf8.rfind("chrome-error://", 0) != 0 && !is_redirect) {
      std::lock_guard<std::mutex> lock(nav_privacy_mutex_);
      last_cert_error_url_.clear();
      suppressed_fallback_error_url_.clear();
      reported_cookie_blocks_.clear();
      bounce_redirector_hosts_.clear();
      if (upgraded_committed_url_ != urlUtf8) {
        upgraded_committed_url_.clear();
      }
    }
    if (!urlUtf8.empty() && urlUtf8.rfind("chrome-error://", 0) != 0 && !is_redirect) {
      // Copy the current page now, while it is still on screen, so it can cover Chromium's view swap at commit.
      SXBrowserTab* strongTab = RetainTab();
      if (strongTab) {
        if ([NSThread isMainThread]) {
          [strongTab handleMainFrameNavigationWillStart];
        } else {
          dispatch_async(dispatch_get_main_queue(), ^{
            [strongTab handleMainFrameNavigationWillStart];
          });
        }
      }
    }
  }
  return false;
}

bool SXBrowserClient::OnResourceResponse(CefRefPtr<CefBrowser> browser,
                                         CefRefPtr<CefFrame> frame,
                                         CefRefPtr<CefRequest> request,
                                         CefRefPtr<CefResponse> response) {
  (void)browser;
  (void)response;
  // IO thread. The main-frame response arrives just before Chromium commits and swaps views: the moment to pin
  // the freeze frame while the old page is still intact on screen.
  if (frame && frame->IsMain() && request && request->GetResourceType() == RT_MAIN_FRAME) {
    SXBrowserTab* strongTab = RetainTab();
    if (strongTab) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [strongTab handleMainFrameResponseReceived];
      });
    }
  }
  return false;
}

CefRefPtr<CefResourceRequestHandler> SXBrowserClient::GetResourceRequestHandler(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefRequest> request,
    bool is_navigation,
    bool is_download,
    const CefString& request_initiator,
    bool& disable_default_handling) {
  (void)browser;
  (void)frame;
  (void)request;
  (void)is_navigation;
  (void)is_download;
  (void)request_initiator;
  (void)disable_default_handling;
  return this;
}

bool SXBrowserClient::OnCertificateError(CefRefPtr<CefBrowser> browser,
                                         cef_errorcode_t cert_error,
                                         const CefString& request_url,
                                         CefRefPtr<CefSSLInfo> ssl_info,
                                         CefRefPtr<CefCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  (void)cert_error;
  (void)ssl_info;
  (void)callback;

  std::string urlUtf8 = request_url.ToString();
  std::string normHost = sx::privacy::NormalizeHost(sx::privacy::ExtractHostFromURL(urlUtf8));

  std::string fallbackHttpUrl;
  {
    std::lock_guard<std::mutex> lock(nav_privacy_mutex_);
    auto it = pending_upgraded_urls_.find(urlUtf8);
    if (it != pending_upgraded_urls_.end()) {
      fallbackHttpUrl = it->second;
      pending_upgraded_urls_.erase(it);
      suppressed_fallback_error_url_ = urlUtf8;
    }
  }

  if (!fallbackHttpUrl.empty()) {
    const bool isPrivate = is_incognito_.load(std::memory_order_acquire);
    sx::privacy::SXPrivacyEngine::Shared().AddSessionHTTPSFallbackHost(normHost, isPrivate);
    if (browser && browser->GetMainFrame()) {
      CefRefPtr<CefFrame> mainFrame = browser->GetMainFrame();
      CefPostTask(TID_UI, CefCreateClosureTask(base::BindOnce(
          [](CefRefPtr<CefFrame> f, std::string origUrl) {
            if (f && f->IsValid()) {
              f->LoadURL(CefString(origUrl));
            }
          },
          mainFrame, fallbackHttpUrl)));
    }
    return false;
  }

  {
    std::lock_guard<std::mutex> lock(nav_privacy_mutex_);
    last_cert_error_url_ = urlUtf8;
  }
  SXConnectionSecurityState certState = SXConnectionSecurityStateCertificateError;
  UpdateConnectionSecurityForMainURL(urlUtf8, &certState);
  return false;
}

CefRefPtr<CefCookieAccessFilter> SXBrowserClient::GetCookieAccessFilter(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefRequest> request) {
  (void)browser;
  (void)frame;
  (void)request;
  return this;
}

bool SXBrowserClient::EvaluateCookieAccess(CefRefPtr<CefBrowser> browser,
                                           CefRefPtr<CefFrame> frame,
                                           CefRefPtr<CefRequest> request,
                                           CefRefPtr<CefResponse> response,
                                           bool is_save) {
  (void)frame;
  if (!request) return true;
  std::string reqUrl = request->GetURL().ToString();
  std::string reqScheme = sx::privacy::ExtractSchemeFromURL(reqUrl);
  if (reqScheme != "http" && reqScheme != "https") {
    return true;
  }

  auto policy = sx::privacy::SXPrivacyEngine::Shared().Snapshot();
  std::string reqHostRaw = sx::privacy::ExtractHostFromURL(reqUrl);
  std::string reqHostNorm = sx::privacy::NormalizeHost(reqHostRaw);
  const bool isMainFrame = (request->GetResourceType() == RT_MAIN_FRAME);

  std::string pageUrl = isMainFrame ? reqUrl : ResolveCurrentPageURL(browser, request);
  std::string pageHost = sx::privacy::NormalizeHost(sx::privacy::ExtractHostFromURL(pageUrl));

  auto emitCookieBlocked = [&](const std::string& pHost, const std::string& entity, const std::string& owner) {
    if (reqHostNorm.empty()) return;
    std::string dedupKey = pHost + "|" + reqHostNorm;
    bool shouldEmit = false;
    {
      std::lock_guard<std::mutex> lock(nav_privacy_mutex_);
      shouldEmit = reported_cookie_blocks_.insert(dedupKey).second;
    }
    if (shouldEmit) {
      EmitPrivacyEventOnMainThread("cookieBlocked",
                                   pHost,
                                   reqHostNorm,
                                   entity,
                                   owner,
                                   "cookie",
                                   "",
                                   1);
    }
  };

  if (policy->block_all_cookies) {
    auto tm = sx::privacy::SXPrivacyEngine::Shared().ClassifyTrackerHost(reqHostRaw, policy->protection_level, false);
    std::string ent = tm.matched ? tm.entity_domain : sx::privacy::RegistrableDomain(reqHostRaw);
    std::string own = tm.matched ? tm.owner_name : ent;
    emitCookieBlocked(pageHost, ent, own);
    return false;
  }

  if (!policy->prevent_cross_site_tracking) {
    return true;
  }
  if (reqHostRaw.empty()) {
    return true;
  }

  // Main-frame navigations are first-party to the target host, EXCEPT we reject Set-Cookie
  // on 3xx bounce-tracker redirects / recorded bounce redirectors.
  if (isMainFrame) {
    if (is_save && policy->IsSiteProtectionEnabled(reqHostNorm)) {
      bool isRedirectResponse = (response && response->GetStatus() >= 300 && response->GetStatus() < 400);
      bool markedBounce = false;
      {
        std::lock_guard<std::mutex> lock(nav_privacy_mutex_);
        markedBounce = (bounce_redirector_hosts_.count(reqHostNorm) > 0);
      }
      if (markedBounce || (isRedirectResponse && sx::privacy::SXPrivacyEngine::Shared().IsBounceTrackerHost(reqHostRaw))) {
        auto tm = sx::privacy::SXPrivacyEngine::Shared().ClassifyTrackerHost(reqHostRaw, 1, true);
        std::string ent = tm.matched ? tm.entity_domain : sx::privacy::RegistrableDomain(reqHostRaw);
        std::string own = tm.matched ? tm.owner_name : ent;
        emitCookieBlocked(reqHostNorm, ent, own);
        return false;
      }
    }
    return true;
  }

  if (!policy->IsSiteProtectionEnabled(pageHost)) {
    return true;
  }

  // Check essential auth / payment / CAPTCHA allowlist BEFORE tracker rules so login/checkout cookies never break.
  if (sx::privacy::SXPrivacyEngine::Shared().IsEssentialAllowlistedHost(reqHostRaw)) {
    return true;
  }

  auto tm = sx::privacy::SXPrivacyEngine::Shared().ClassifyTrackerHost(reqHostRaw, policy->protection_level, false);
  if (tm.matched && !sx::privacy::SXPrivacyEngine::Shared().IsSameEntity(pageHost, reqHostRaw, tm.entity_domain)) {
    emitCookieBlocked(pageHost, tm.entity_domain, tm.owner_name);
    return false;
  }

  std::string pageReg = sx::privacy::RegistrableDomain(pageHost);
  std::string reqReg = sx::privacy::RegistrableDomain(reqHostRaw);
  if (!pageReg.empty() && !reqReg.empty() && pageReg != reqReg &&
      !sx::privacy::SXPrivacyEngine::Shared().IsSameEntity(pageHost, reqHostRaw, "")) {
    emitCookieBlocked(pageHost, reqReg, reqReg);
    return false;
  }

  return true;
}

bool SXBrowserClient::CanSendCookie(CefRefPtr<CefBrowser> browser,
                                    CefRefPtr<CefFrame> frame,
                                    CefRefPtr<CefRequest> request,
                                    const CefCookie& cookie) {
  (void)cookie;
  @autoreleasepool {
    return EvaluateCookieAccess(browser, frame, request, nullptr, false);
  }
}

bool SXBrowserClient::CanSaveCookie(CefRefPtr<CefBrowser> browser,
                                    CefRefPtr<CefFrame> frame,
                                    CefRefPtr<CefRequest> request,
                                    CefRefPtr<CefResponse> response,
                                    const CefCookie& cookie) {
  (void)cookie;
  @autoreleasepool {
    return EvaluateCookieAccess(browser, frame, request, response, true);
  }
}

CefRefPtr<CefResourceHandler> SXBrowserClient::GetResourceHandler(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefRequest> request) {
  (void)frame;
  CefRefPtr<CefResourceHandler> mediaHandler = CreateSXMediaResourceHandler(request);
  if (mediaHandler) {
    return mediaHandler;
  }

  if (!request || request->GetResourceType() == RT_MAIN_FRAME) {
    return nullptr;
  }

  @autoreleasepool {
    std::string reqUrl = request->GetURL().ToString();
    std::string reqScheme = sx::privacy::ExtractSchemeFromURL(reqUrl);
    if (reqScheme != "http" && reqScheme != "https") {
      return nullptr;
    }
    auto policy = sx::privacy::SXPrivacyEngine::Shared().Snapshot();
    std::string pageUrl = ResolveCurrentPageURL(browser, request);
    std::string pageHost = sx::privacy::NormalizeHost(sx::privacy::ExtractHostFromURL(pageUrl));
    std::string reqHostRaw = sx::privacy::ExtractHostFromURL(reqUrl);
    std::string reqHostNorm = sx::privacy::NormalizeHost(reqHostRaw);

    auto match = sx::privacy::SXPrivacyEngine::Shared().EvaluateSubresourceBlock(
        reqUrl, reqHostRaw, pageHost, *policy);
    if (match.matched && match.is_surrogate_eligible) {
      auto kind = sx::privacy::SXPrivacyEngine::Shared().DetectSurrogateKind(reqUrl);
      const char* body = sx::privacy::SXPrivacyEngine::SurrogateScriptBody(kind);
      if (body && body[0] != '\0') {
        EmitPrivacyEventOnMainThread("trackerBlocked",
                                     pageHost,
                                     reqHostNorm,
                                     match.entity_domain,
                                     match.owner_name,
                                     match.category,
                                     match.matched_domain + " (surrogate)",
                                     1);
        return new SXSurrogateJSResourceHandler(body);
      }
    }
  }

  return nullptr;
}

CefResourceRequestHandler::ReturnValue SXBrowserClient::OnBeforeResourceLoad(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefRequest> request,
    CefRefPtr<CefCallback> callback) {
  (void)frame;
  (void)callback;
  if (!request) {
    return RV_CONTINUE;
  }

  // Runs on CEF's C++ TID_IO thread: always drain ObjC temporaries and never call UI-thread-only CefBrowserHost APIs.
  @autoreleasepool {
    auto policy = sx::privacy::SXPrivacyEngine::Shared().Snapshot();

    // 1. Disable caches while Web Inspector is open
    if (devtools_open_.load(std::memory_order_relaxed)) {
      NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
      if ([ud boolForKey:@"Safarium.Pref.DevDisableCache"]) {
        request->SetFlags(request->GetFlags() | UR_FLAG_SKIP_CACHE);
      }
    }

    std::string reqUrl = request->GetURL().ToString();
    std::string reqScheme = sx::privacy::ExtractSchemeFromURL(reqUrl);
    if (reqScheme != "http" && reqScheme != "https") {
      return RV_CONTINUE;
    }

    // 2. Global Privacy Control header (only on HTTP/HTTPS, overwrite-safe on retries/redirects)
    if (policy->global_privacy_control) {
      request->SetHeaderByName("Sec-GPC", "1", true);
    }

    std::string reqHostRaw = sx::privacy::ExtractHostFromURL(reqUrl);
    std::string reqHostNorm = sx::privacy::NormalizeHost(reqHostRaw);
    const bool isMainFrame = (request->GetResourceType() == RT_MAIN_FRAME);
    const bool isPrivate = is_incognito_.load(std::memory_order_acquire);

    if (isMainFrame) {
      std::string method = sx::privacy::ToLowerASCII(request->GetMethod().ToString());
      const bool isSafeMethod = (method == "get" || method == "head") && !request->GetPostData();

      // 3. Expanded Link Tracking Protection on safe main-frame navigations
      const bool stripActive =
          policy->strip_tracking_params ||
          (policy->advanced_fingerprint && (policy->advanced_fingerprint_scope == 1 || isPrivate));
      if (isSafeMethod && stripActive && policy->IsSiteProtectionEnabled(reqHostNorm)) {
        auto stripped = sx::privacy::SXPrivacyEngine::Shared().StripTrackingParamsFromURL(reqUrl);
        if (stripped.modified && !stripped.cleaned_url.empty()) {
          reqUrl = stripped.cleaned_url;
          request->SetURL(CefString(reqUrl));
          std::string reg = sx::privacy::RegistrableDomain(reqHostNorm);
          EmitPrivacyEventOnMainThread("trackingParamStripped",
                                       reqHostNorm,
                                       reqHostNorm,
                                       reg,
                                       reg,
                                       "linkTracking",
                                       JoinCSV(stripped.stripped_params),
                                       static_cast<NSInteger>(stripped.stripped_params.size()));
        }
      }

      // 4. HTTPS-First Automatic Upgrade (safe GET/HEAD without POST body)
      if (isSafeMethod &&
          sx::privacy::SXPrivacyEngine::Shared().ShouldUpgradeMainFrameToHTTPS(
              reqUrl, reqHostNorm, *policy, isPrivate)) {
        std::string origHttpUrl = reqUrl;
        std::string httpsUrl = sx::privacy::UpgradeURLSchemeToHTTPS(origHttpUrl);
        {
          std::lock_guard<std::mutex> lock(nav_privacy_mutex_);
          pending_upgraded_urls_[httpsUrl] = origHttpUrl;
        }
        reqUrl = httpsUrl;
        reqScheme = "https";
        request->SetURL(CefString(reqUrl));
      }
    } else {
      // 5. Subresource Tracker Blocking + Inert JS Surrogate handoff
      std::string pageUrl = ResolveCurrentPageURL(browser, request);
      std::string pageHost = sx::privacy::NormalizeHost(sx::privacy::ExtractHostFromURL(pageUrl));
      auto match = sx::privacy::SXPrivacyEngine::Shared().EvaluateSubresourceBlock(
          reqUrl, reqHostRaw, pageHost, *policy);
      if (match.matched && !match.is_surrogate_eligible) {
        EmitPrivacyEventOnMainThread("trackerBlocked",
                                     pageHost,
                                     reqHostNorm,
                                     match.entity_domain,
                                     match.owner_name,
                                     match.category,
                                     match.matched_domain,
                                     1);
        return RV_CANCEL;
      }
    }

    // 6. Cross-Origin Referrer Hardening
    if (policy->referrer_trimming && policy->prevent_cross_site_tracking) {
      std::string refUrl = request->GetReferrerURL().ToString();
      if (!refUrl.empty() && !sx::privacy::IsSameOriginURL(refUrl, reqUrl)) {
        std::string pageUrl = isMainFrame ? reqUrl : ResolveCurrentPageURL(browser, request);
        std::string pageHost = sx::privacy::NormalizeHost(sx::privacy::ExtractHostFromURL(pageUrl));
        if (policy->IsSiteProtectionEnabled(pageHost)) {
          std::string refScheme = sx::privacy::ExtractSchemeFromURL(refUrl);
          auto curPolicy = request->GetReferrerPolicy();
          auto tm = sx::privacy::SXPrivacyEngine::Shared().ClassifyTrackerHost(
              reqHostRaw, policy->protection_level, false);
          bool targetIsTracker = tm.matched && !sx::privacy::SXPrivacyEngine::Shared().IsSameEntity(
                                                   pageHost, reqHostRaw, tm.entity_domain);
          if ((refScheme == "https" && reqScheme == "http") ||
              targetIsTracker ||
              curPolicy == REFERRER_POLICY_NO_REFERRER ||
              curPolicy == REFERRER_POLICY_CLEAR_REFERRER_ON_TRANSITION_CROSS_ORIGIN) {
            request->SetReferrer("", REFERRER_POLICY_NO_REFERRER);
          } else {
            std::string origin = sx::privacy::ExtractOriginFromURL(refUrl);
            if (!origin.empty()) {
              request->SetReferrer(
                  CefString(origin),
                  REFERRER_POLICY_ORIGIN_CLEAR_ON_TRANSITION_FROM_SECURE_TO_INSECURE);
            }
          }
        }
      }
    }
  }

  return RV_CONTINUE;
}

void SXBrowserClient::OnResourceRedirect(CefRefPtr<CefBrowser> browser,
                                         CefRefPtr<CefFrame> frame,
                                         CefRefPtr<CefRequest> request,
                                         CefRefPtr<CefResponse> response,
                                         CefString& new_url) {
  (void)browser;
  (void)frame;
  (void)response;
  if (!request || request->GetResourceType() != RT_MAIN_FRAME) {
    return;
  }

  @autoreleasepool {
    std::string oldUrl = request->GetURL().ToString();
    std::string newUrlStr = new_url.ToString();
    std::string newScheme = sx::privacy::ExtractSchemeFromURL(newUrlStr);
    if (newScheme != "http" && newScheme != "https") {
      return;
    }

    std::string oldHostRaw = sx::privacy::ExtractHostFromURL(oldUrl);
    std::string oldHostNorm = sx::privacy::NormalizeHost(oldHostRaw);
    std::string newHostRaw = sx::privacy::ExtractHostFromURL(newUrlStr);
    std::string newHostNorm = sx::privacy::NormalizeHost(newHostRaw);

    auto policy = sx::privacy::SXPrivacyEngine::Shared().Snapshot();
    const bool isPrivate = is_incognito_.load(std::memory_order_acquire);
    const bool siteEnabled = policy->IsSiteProtectionEnabled(newHostNorm);

    // Detect server-initiated HTTPS->HTTP downgrade loop from an active pending upgrade.
    {
      std::string origHttpUrl;
      bool hadPending = false;
      {
        std::lock_guard<std::mutex> lock(nav_privacy_mutex_);
        auto it = pending_upgraded_urls_.find(oldUrl);
        if (it != pending_upgraded_urls_.end()) {
          origHttpUrl = it->second;
          pending_upgraded_urls_.erase(it);
          hadPending = true;
        }
      }
      if (hadPending) {
        if (newScheme == "http" && !oldHostNorm.empty() && oldHostNorm == newHostNorm) {
          sx::privacy::SXPrivacyEngine::Shared().AddSessionHTTPSFallbackHost(newHostNorm, isPrivate);
        } else if (newScheme == "https") {
          std::lock_guard<std::mutex> lock(nav_privacy_mutex_);
          pending_upgraded_urls_[newUrlStr] = origHttpUrl;
        }
      }
    }

    // Strip tracking params on redirect target
    const bool stripActive =
        policy->strip_tracking_params ||
        (policy->advanced_fingerprint && (policy->advanced_fingerprint_scope == 1 || isPrivate));
    if (stripActive && siteEnabled) {
      auto stripped = sx::privacy::SXPrivacyEngine::Shared().StripTrackingParamsFromURL(newUrlStr);
      if (stripped.modified && !stripped.cleaned_url.empty()) {
        newUrlStr = stripped.cleaned_url;
        new_url = CefString(newUrlStr);
        std::string reg = sx::privacy::RegistrableDomain(newHostNorm);
        EmitPrivacyEventOnMainThread("trackingParamStripped",
                                     newHostNorm,
                                     newHostNorm,
                                     reg,
                                     reg,
                                     "linkTracking",
                                     JoinCSV(stripped.stripped_params),
                                     static_cast<NSInteger>(stripped.stripped_params.size()));
      }
    }

    // Bounce-tracker intermediary detection & cookie mitigation
    if (policy->prevent_cross_site_tracking && siteEnabled && !oldHostRaw.empty() &&
        sx::privacy::SXPrivacyEngine::Shared().IsBounceTrackerHost(oldHostRaw) &&
        sx::privacy::RegistrableDomain(oldHostRaw) != sx::privacy::RegistrableDomain(newHostRaw)) {
      {
        std::lock_guard<std::mutex> lock(nav_privacy_mutex_);
        bounce_redirector_hosts_.insert(oldHostNorm);
      }
      auto tm = sx::privacy::SXPrivacyEngine::Shared().ClassifyTrackerHost(oldHostRaw, 1, true);
      std::string entity = tm.matched ? tm.entity_domain : sx::privacy::RegistrableDomain(oldHostRaw);
      std::string owner = tm.matched ? tm.owner_name : entity;
      EmitPrivacyEventOnMainThread("bounceTrackerMitigated",
                                   newHostNorm,
                                   oldHostNorm,
                                   entity,
                                   owner,
                                   "bounceTracking",
                                   oldHostNorm,
                                   1);
    }
  }
}

#pragma mark - CefDevToolsMessageObserver

void SXBrowserClient::OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                                             int message_id,
                                             bool success,
                                             const void* result,
                                             size_t result_size) {
  CEF_REQUIRE_UI_THREAD();
  if (getenv("SAFARIUM_CEF_DEBUG")) {
    fprintf(stderr, "[BrowserCore] OnDevToolsMethodResult id=%d success=%d size=%zu\n",
            message_id, success ? 1 : 0, result_size);
    fflush(stderr);
  }
  std::function<void(const std::string&)> callback;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    if (inflight_capture_id_ == 0 || inflight_capture_id_ != message_id) {
      return;
    }
    inflight_capture_id_ = 0;
    callback.swap(inflight_capture_callback_);
  }

  std::string pngBytes;
  if (success && result && result_size > 0) {
    CefRefPtr<CefValue> parsed =
        CefParseJSON(result, result_size, JSON_PARSER_RFC);
    if (parsed && parsed->GetType() == VTYPE_DICTIONARY) {
      CefRefPtr<CefDictionaryValue> dict = parsed->GetDictionary();
      if (dict && dict->HasKey("data")) {
        CefString b64 = dict->GetString("data");
        CefRefPtr<CefBinaryValue> decoded = CefBase64Decode(b64);
        if (decoded && decoded->GetSize() > 0) {
          pngBytes.resize(decoded->GetSize());
          decoded->GetData(pngBytes.data(), pngBytes.size(), 0);
        }
      }
    }
  }

  if (callback) {
    callback(pngBytes);
  }
  StartNextCaptureIfIdle();
  ScheduleDevToolsDetachIfIdle();
}

void SXBrowserClient::OnDevToolsAgentDetached(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  devtools_open_.store(false, std::memory_order_relaxed);
  std::function<void(const std::string&)> inflight;
  std::deque<PendingCapture> queued;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    inflight_capture_id_ = 0;
    inflight.swap(inflight_capture_callback_);
    queued.swap(capture_queue_);
  }
  if (inflight) {
    inflight(std::string());
  }
  for (auto& item : queued) {
    if (item.callback) {
      item.callback(std::string());
    }
  }
}

#pragma mark - CefJSDialogHandler (Native macOS Safari NSAlert Sheets)

bool SXBrowserClient::OnJSDialog(CefRefPtr<CefBrowser> browser,
                                 const CefString& origin_url,
                                 JSDialogType dialog_type,
                                 const CefString& message_text,
                                 const CefString& default_prompt_text,
                                 CefRefPtr<CefJSDialogCallback> callback,
                                 bool& suppress_message) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  (void)suppress_message;

  NSString* originStr = origin_url.empty() ? @"" : [NSString stringWithUTF8String:origin_url.ToString().c_str()];
  NSURL* parsedURL = originStr.length > 0 ? [NSURL URLWithString:originStr] : nil;
  NSString* host = parsedURL.host.length > 0 ? parsedURL.host : (originStr.length > 0 ? originStr : @"This page");
  NSString* msg = message_text.empty() ? @"" : [NSString stringWithUTF8String:message_text.ToString().c_str()];
  NSString* defPrompt = default_prompt_text.empty() ? @"" : [NSString stringWithUTF8String:default_prompt_text.ToString().c_str()];

  SXBrowserTab* strongTab = RetainTab();
  CefRefPtr<CefJSDialogCallback> cb = callback;

  dispatch_async(dispatch_get_main_queue(), ^{
    NSAlert* alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.icon = NSApp.applicationIconImage;
    alert.messageText = [NSString stringWithFormat:@"From “%@”:", host];
    alert.informativeText = msg ?: @"";

    NSTextField* inputField = nil;
    if (dialog_type == JSDIALOGTYPE_ALERT) {
      [alert addButtonWithTitle:@"OK"];
    } else if (dialog_type == JSDIALOGTYPE_CONFIRM) {
      [alert addButtonWithTitle:@"OK"];
      [alert addButtonWithTitle:@"Cancel"];
    } else if (dialog_type == JSDIALOGTYPE_PROMPT) {
      [alert addButtonWithTitle:@"OK"];
      [alert addButtonWithTitle:@"Cancel"];
      inputField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 290, 24)];
      inputField.stringValue = defPrompt ?: @"";
      inputField.bezelStyle = NSTextFieldRoundedBezel;
      alert.accessoryView = inputField;
    }

    NSWindow* hostWindow = strongTab.contentView.window ?: NSApp.keyWindow;
    void (^finish)(NSModalResponse) = ^(NSModalResponse resp) {
      bool ok = (resp == NSAlertFirstButtonReturn);
      std::string userInput;
      if (ok && inputField) {
        const char* utf8 = inputField.stringValue.UTF8String;
        if (utf8) userInput = utf8;
      }
      if (cb) {
        cb->Continue(ok, userInput);
      }
    };

    if (hostWindow) {
      [alert beginSheetModalForWindow:hostWindow completionHandler:finish];
      if (inputField) {
        [alert.window makeFirstResponder:inputField];
      }
    } else {
      finish([alert runModal]);
    }
  });
  return true;
}

bool SXBrowserClient::OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                                           const CefString& message_text,
                                           bool is_reload,
                                           CefRefPtr<CefJSDialogCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;

  NSString* msg = message_text.empty() ? @"" : [NSString stringWithUTF8String:message_text.ToString().c_str()];
  SXBrowserTab* strongTab = RetainTab();
  CefRefPtr<CefJSDialogCallback> cb = callback;

  dispatch_async(dispatch_get_main_queue(), ^{
    NSAlert* alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.icon = NSApp.applicationIconImage;
    alert.messageText = is_reload
        ? @"Are you sure you want to reload this page?"
        : @"Are you sure you want to leave this page?";
    alert.informativeText = msg.length > 0
        ? msg
        : @"Changes you made may not be saved.";
    [alert addButtonWithTitle:is_reload ? @"Reload Page" : @"Leave Page"];
    [alert addButtonWithTitle:@"Cancel"];

    NSWindow* hostWindow = strongTab.contentView.window ?: NSApp.keyWindow;
    void (^finish)(NSModalResponse) = ^(NSModalResponse resp) {
      if (cb) {
        cb->Continue(resp == NSAlertFirstButtonReturn, "");
      }
    };

    if (hostWindow) {
      [alert beginSheetModalForWindow:hostWindow completionHandler:finish];
    } else {
      finish([alert runModal]);
    }
  });
  return true;
}
