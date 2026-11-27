// SXHelperMain.mm
// macOS Chromium subprocess helper (Renderer, GPU, Plugin, Alerts).
// Implements zero-fingerprint visualViewport.scale telemetry and Safarium-grade
// Safari rubber-band overscroll + pull-to-refresh + momentum bounce physics.

#include "include/cef_app.h"
#include "include/cef_load_handler.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_sandbox_mac.h"
#include "include/cef_v8.h"
#include "include/wrapper/cef_library_loader.h"

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace {

// -----------------------------------------------------------------------------
// Safari-style Activity Monitor process naming via macOS LaunchServices.
// Registers each subprocess as a lightweight UIElement (!cgsConnection, no Dock
// icon, no Cmd+Tab entry) BEFORE Seatbelt sandbox initialization, then updates
// _kLSDisplayNameKey dynamically as tabs navigate (e.g. "https://www.reddit.com",
// "https://www.google.com", "Bitwarden Web Extension", "Safarium Graphics and Media").
// -----------------------------------------------------------------------------
struct SXLaunchServicesBridge {
  using CheckInFn = CFTypeRef (*)(int32_t, CFDictionaryRef);
  using GetCurrentASNFn = CFTypeRef (*)(void);
  using SetInfoItemFn = OSStatus (*)(int32_t, CFTypeRef, CFStringRef, CFTypeRef, CFTypeRef*);

  std::mutex mu;
  bool initialized = false;
  bool is_extension_process = false;
  std::string default_name = "Safarium Web Content";
  std::string current_name;
  std::unordered_map<std::string, std::string> extension_names;

  CheckInFn check_in = nullptr;
  GetCurrentASNFn get_asn = nullptr;
  SetInfoItemFn set_info_item = nullptr;
  CFStringRef display_name_key = nullptr;
  CFTypeRef current_asn = nullptr;
};

SXLaunchServicesBridge& SXLS() {
  static SXLaunchServicesBridge* bridge = new SXLaunchServicesBridge();
  return *bridge;
}

std::string SXResolveLocalizedExtName(NSString* dir, NSDictionary* manifest, NSString* rawName) {
  if (![rawName isKindOfClass:[NSString class]] || rawName.length == 0) return "";
  NSString* resolved = rawName;
  if ([rawName hasPrefix:@"__MSG_"] && [rawName hasSuffix:@"__"] && rawName.length > 8) {
    NSString* key = [rawName substringWithRange:NSMakeRange(6, rawName.length - 8)];
    NSString* defLocale = [manifest[@"default_locale"] isKindOfClass:[NSString class]]
                              ? manifest[@"default_locale"]
                              : @"en";
    NSArray<NSString*>* locales = @[ defLocale, @"en", @"en_US" ];
    for (NSString* loc in locales) {
      NSString* msgPath = [[dir stringByAppendingPathComponent:@"_locales"]
          stringByAppendingPathComponent:[loc stringByAppendingPathComponent:@"messages.json"]];
      NSData* data = [NSData dataWithContentsOfFile:msgPath];
      if (!data) continue;
      id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      if (![parsed isKindOfClass:[NSDictionary class]]) continue;
      NSDictionary* dict = (NSDictionary*)parsed;
      NSDictionary* entry = [dict[key] isKindOfClass:[NSDictionary class]] ? dict[key] : nil;
      if (!entry) {
        NSString* lowerKey = [key lowercaseString];
        for (NSString* k in dict) {
          if ([[k lowercaseString] isEqualToString:lowerKey] &&
              [dict[k] isKindOfClass:[NSDictionary class]]) {
            entry = dict[k];
            break;
          }
        }
      }
      if ([entry[@"message"] isKindOfClass:[NSString class]] && [(NSString*)entry[@"message"] length] > 0) {
        resolved = entry[@"message"];
        break;
      }
    }
  }
  return resolved.UTF8String ? std::string(resolved.UTF8String) : "";
}

void SXLoadExtensionNameMapFromUserDataDir(const std::string& userDataDir) {
  if (userDataDir.empty()) return;
  @autoreleasepool {
    NSString* root = [NSString stringWithUTF8String:userDataDir.c_str()];
    NSString* regPath = [[root stringByAppendingPathComponent:@"SafariumExtensions"]
        stringByAppendingPathComponent:@"registry.json"];
    NSData* data = [NSData dataWithContentsOfFile:regPath];
    if (!data) return;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![parsed isKindOfClass:[NSArray class]]) return;

    auto& ls = SXLS();
    for (id obj in (NSArray*)parsed) {
      if (![obj isKindOfClass:[NSDictionary class]]) continue;
      NSString* extId = [obj[@"extensionID"] isKindOfClass:[NSString class]]
                            ? [(NSString*)obj[@"extensionID"] lowercaseString]
                            : nil;
      NSString* extPath = [obj[@"path"] isKindOfClass:[NSString class]] ? obj[@"path"] : nil;
      if (!extId.length || !extPath.length) continue;
      NSData* mData = [NSData dataWithContentsOfFile:[extPath stringByAppendingPathComponent:@"manifest.json"]];
      if (!mData) continue;
      id mParsed = [NSJSONSerialization JSONObjectWithData:mData options:0 error:nil];
      if (![mParsed isKindOfClass:[NSDictionary class]]) continue;
      NSDictionary* manifest = (NSDictionary*)mParsed;
      NSString* rawName = [manifest[@"short_name"] isKindOfClass:[NSString class]]
                              ? manifest[@"short_name"]
                              : ([manifest[@"name"] isKindOfClass:[NSString class]] ? manifest[@"name"] : nil);
      std::string name = SXResolveLocalizedExtName(extPath, manifest, rawName);
      if (!name.empty()) {
        ls.extension_names[extId.UTF8String] = name;
      }
    }
  }
}

void SXSetProcessDisplayName(const std::string& name) {
  if (name.empty()) return;
  auto& ls = SXLS();
  std::lock_guard<std::mutex> lock(ls.mu);
  if (!ls.initialized || !ls.set_info_item || !ls.current_asn || !ls.display_name_key) return;
  if (ls.current_name == name) return;
  CFStringRef cfName = CFStringCreateWithCString(kCFAllocatorDefault, name.c_str(), kCFStringEncodingUTF8);
  if (!cfName) return;
  OSStatus st = ls.set_info_item(-2, ls.current_asn, ls.display_name_key, cfName, nullptr);
  CFRelease(cfName);
  if (st == noErr) {
    ls.current_name = name;
  }
}

void SXInitLaunchServicesForSubprocess(int argc, char* argv[]) {
  std::string procType;
  std::string utilitySubType;
  std::string userDataDir;
  bool isExtProcess = false;

  for (int i = 1; i < argc; ++i) {
    if (!argv[i]) continue;
    std::string arg(argv[i]);
    if (arg.rfind("--type=", 0) == 0) {
      procType = arg.substr(7);
    } else if (arg.rfind("--utility-sub-type=", 0) == 0) {
      utilitySubType = arg.substr(19);
    } else if (arg.rfind("--user-data-dir=", 0) == 0) {
      userDataDir = arg.substr(16);
    } else if (arg == "--extension-process") {
      isExtProcess = true;
    }
  }

  std::string initialName = "Safarium Helper";
  std::string bundleId = "com.safarium.browser.helper";

  if (procType == "renderer") {
    if (isExtProcess) {
      initialName = "Safarium Web Extension";
      bundleId = "com.safarium.browser.webextension";
    } else {
      initialName = "Safarium Web Content";
      bundleId = "com.safarium.browser.webcontent";
    }
  } else if (procType == "gpu-process") {
    initialName = "Safarium Graphics and Media";
    bundleId = "com.safarium.browser.gpu";
  } else if (procType == "utility") {
    if (utilitySubType.find("NetworkService") != std::string::npos) {
      initialName = "Safarium Networking";
      bundleId = "com.safarium.browser.networking";
    } else if (utilitySubType.find("StorageService") != std::string::npos) {
      initialName = "Safarium Storage";
      bundleId = "com.safarium.browser.storage";
    } else if (utilitySubType.find("AudioService") != std::string::npos) {
      initialName = "Safarium Audio";
      bundleId = "com.safarium.browser.audio";
    } else if (utilitySubType.find("VideoCapture") != std::string::npos) {
      initialName = "Safarium Media Capture";
      bundleId = "com.safarium.browser.mediacapture";
    } else {
      initialName = "Safarium Helper Service";
      bundleId = "com.safarium.browser.service";
    }
  }

  auto& ls = SXLS();
  ls.is_extension_process = isExtProcess;
  ls.default_name = initialName;

  // Load extension display names before Seatbelt sandbox locks down filesystem reads.
  if (procType == "renderer" && !userDataDir.empty()) {
    SXLoadExtensionNameMapFromUserDataDir(userDataDir);
  }

  void* cs = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
  if (!cs) return;

  ls.check_in = reinterpret_cast<SXLaunchServicesBridge::CheckInFn>(dlsym(cs, "_LSApplicationCheckIn"));
  ls.get_asn = reinterpret_cast<SXLaunchServicesBridge::GetCurrentASNFn>(dlsym(cs, "_LSGetCurrentApplicationASN"));
  ls.set_info_item = reinterpret_cast<SXLaunchServicesBridge::SetInfoItemFn>(dlsym(cs, "_LSSetApplicationInformationItem"));
  auto* keyPtr = reinterpret_cast<CFStringRef*>(dlsym(cs, "_kLSDisplayNameKey"));
  if (keyPtr) {
    ls.display_name_key = *keyPtr;
  }
  if (!ls.check_in || !ls.get_asn || !ls.set_info_item || !ls.display_name_key) {
    return;
  }

  CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  if (!dict) return;

  CFStringRef cfBundleId = CFStringCreateWithCString(kCFAllocatorDefault, bundleId.c_str(), kCFStringEncodingUTF8);
  CFStringRef cfName = CFStringCreateWithCString(kCFAllocatorDefault, initialName.c_str(), kCFStringEncodingUTF8);
  CFDictionarySetValue(dict, CFSTR("LSUIElement"), kCFBooleanTrue);
  CFDictionarySetValue(dict, CFSTR("ApplicationType"), CFSTR("UIElement"));
  if (cfBundleId) {
    CFDictionarySetValue(dict, CFSTR("CFBundleIdentifier"), cfBundleId);
    CFRelease(cfBundleId);
  }
  if (cfName) {
    CFDictionarySetValue(dict, CFSTR("CFBundleName"), cfName);
    CFDictionarySetValue(dict, CFSTR("CFBundleDisplayName"), cfName);
  }

  CFTypeRef checkInResult = ls.check_in(-2, dict);
  if (checkInResult) {
    CFRelease(checkInResult);
  }
  CFRelease(dict);

  ls.current_asn = ls.get_asn();
  if (ls.current_asn) {
    CFRetain(ls.current_asn);
    ls.initialized = true;
    if (cfName) {
      if (ls.set_info_item(-2, ls.current_asn, ls.display_name_key, cfName, nullptr) == noErr) {
        ls.current_name = initialName;
      }
    }
  }
  if (cfName) {
    CFRelease(cfName);
  }
}

std::string SXFormatDisplayNameForURL(const std::string& urlStr) {
  if (urlStr.empty()) return "";
  @autoreleasepool {
    NSString* nsUrl = [NSString stringWithUTF8String:urlStr.c_str()];
    if (!nsUrl.length) return "";
    NSURL* u = [NSURL URLWithString:nsUrl];
    NSString* scheme = [u.scheme lowercaseString];
    NSString* host = [u.host lowercaseString];
    if (!scheme.length) return "";

    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
      if (!host.length) return "";
      NSNumber* port = u.port;
      BOOL isDefaultPort = !port ||
                           ([scheme isEqualToString:@"https"] && port.intValue == 443) ||
                           ([scheme isEqualToString:@"http"] && port.intValue == 80);
      NSString* formatted = isDefaultPort
                                ? [NSString stringWithFormat:@"%@://%@", scheme, host]
                                : [NSString stringWithFormat:@"%@://%@:%@", scheme, host, port];
      return formatted.UTF8String ? std::string(formatted.UTF8String) : "";
    }

    if ([scheme isEqualToString:@"chrome-extension"] && host.length > 0) {
      std::string extId(host.UTF8String);
      auto& ls = SXLS();
      auto it = ls.extension_names.find(extId);
      if (it != ls.extension_names.end() && !it->second.empty()) {
        return it->second + " Web Extension";
      }
      return "Safarium Web Extension";
    }

    if ([scheme isEqualToString:@"chrome"] && host.length > 0) {
      NSString* formatted = [NSString stringWithFormat:@"Safarium (%@)", host];
      return formatted.UTF8String ? std::string(formatted.UTF8String) : "";
    }
  }
  return "";
}

std::string SXDefaultSessionSalt() {
  static const std::string salt = []() {
    uint64_t buf[2] = {0, 0};
    arc4random_buf(buf, sizeof(buf));
    char hex[33];
    std::snprintf(hex, sizeof(hex), "%016llx%016llx",
                  static_cast<unsigned long long>(buf[0]),
                  static_cast<unsigned long long>(buf[1]));
    return std::string(hex);
  }();
  return salt;
}

std::string SXGenerateNavNonce() {
  uint64_t val = 0;
  arc4random_buf(&val, sizeof(val));
  char hex[17];
  std::snprintf(hex, sizeof(hex), "%016llx", static_cast<unsigned long long>(val));
  return std::string(hex);
}

std::string SXNormalizeHost(std::string host) {
  std::transform(host.begin(), host.end(), host.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  while (!host.empty() && host.back() == '.') {
    host.pop_back();
  }
  if (host.rfind("www.", 0) == 0 && host.size() > 4) {
    host.erase(0, 4);
  }
  return host;
}

std::string SXRegistrableDomain(std::string host) {
  host = SXNormalizeHost(std::move(host));
  if (host.empty()) return "";
  if (host.front() == '[' && host.back() == ']' && host.size() > 2) {
    return host.substr(1, host.size() - 2);
  }
  if (host.find(':') != std::string::npos) return host;
  bool allDigitsOrDots = true;
  for (char c : host) {
    if (!std::isdigit(static_cast<unsigned char>(c)) && c != '.') {
      allDigitsOrDots = false;
      break;
    }
  }
  if (allDigitsOrDots) return host;

  std::vector<std::string> labels;
  size_t start = 0;
  while (start <= host.size()) {
    size_t dot = host.find('.', start);
    if (dot == std::string::npos) {
      if (start < host.size()) labels.push_back(host.substr(start));
      break;
    }
    if (dot > start) labels.push_back(host.substr(start, dot - start));
    start = dot + 1;
  }
  if (labels.size() <= 2) return host;
  static const std::unordered_set<std::string> kMultiPartTlds = {
      "co.uk", "org.uk", "ac.uk", "gov.uk", "net.uk",
      "com.au", "net.au", "org.au", "edu.au", "gov.au",
      "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
      "com.br", "net.br", "org.br", "gov.br",
      "com.cn", "net.cn", "org.cn", "gov.cn",
      "com.tr", "net.tr", "org.tr", "gov.tr", "edu.tr",
      "co.in", "net.in", "org.in", "ac.in", "gov.in",
      "co.kr", "or.kr", "ne.kr", "go.kr",
      "co.nz", "net.nz", "org.nz", "govt.nz",
      "co.za", "org.za", "gov.za", "com.mx", "com.sg", "com.hk", "com.tw",
      "com.ar", "com.co", "com.pl", "com.ua", "com.my", "com.ph", "co.id", "co.il", "co.th"
  };
  std::string lastTwo = labels[labels.size() - 2] + "." + labels.back();
  if (kMultiPartTlds.count(lastTwo) > 0 && labels.size() >= 3) {
    return labels[labels.size() - 3] + "." + lastTwo;
  }
  return lastTwo;
}

void SXParseCommaHosts(const std::string& csv, std::unordered_set<std::string>& out) {
  out.clear();
  size_t start = 0;
  while (start < csv.size()) {
    size_t comma = csv.find(',', start);
    std::string item = (comma == std::string::npos) ? csv.substr(start) : csv.substr(start, comma - start);
    std::string norm = SXNormalizeHost(std::move(item));
    if (!norm.empty()) {
      out.insert(std::move(norm));
    }
    if (comma == std::string::npos) break;
    start = comma + 1;
  }
}

std::string SXExtractHostFromURL(const std::string& urlStr) {
  if (urlStr.empty()) return "";
  @autoreleasepool {
    NSString* nsUrl = [NSString stringWithUTF8String:urlStr.c_str()];
    if (!nsUrl.length) return "";
    NSURL* u = [NSURL URLWithString:nsUrl];
    NSString* host = [u.host lowercaseString];
    if (!host.length || !host.UTF8String) return "";
    return SXNormalizeHost(std::string(host.UTF8String));
  }
}

bool SXStartsWithCaseInsensitive(const std::string& str, const char* prefix) {
  if (!prefix) return false;
  size_t len = std::strlen(prefix);
  if (str.size() < len) return false;
  for (size_t i = 0; i < len; ++i) {
    if (std::tolower(static_cast<unsigned char>(str[i])) !=
        std::tolower(static_cast<unsigned char>(prefix[i]))) {
      return false;
    }
  }
  return true;
}

bool SXIsInternalScheme(const std::string& url) {
  return SXStartsWithCaseInsensitive(url, "chrome://") ||
         SXStartsWithCaseInsensitive(url, "chrome-extension://") ||
         SXStartsWithCaseInsensitive(url, "devtools://") ||
         SXStartsWithCaseInsensitive(url, "safarium://") ||
         SXStartsWithCaseInsensitive(url, "view-source:");
}

bool SXIsHttpScheme(const std::string& url) {
  return SXStartsWithCaseInsensitive(url, "http://") ||
         SXStartsWithCaseInsensitive(url, "https://");
}

class SXTelemetryV8Handler : public CefV8Handler {
 public:
  SXTelemetryV8Handler(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame)
      : browser_(browser), frame_(frame) {}

  bool Execute(const CefString& name,
               CefRefPtr<CefV8Value> object,
               const CefV8ValueList& arguments,
               CefRefPtr<CefV8Value>& retval,
               CefString& exception) override {
    if (!frame_ || !frame_->IsValid()) {
      return false;
    }
    if (name == "reportMetrics" && arguments.size() >= 4) {
      CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create("sx.telemetry");
      CefRefPtr<CefListValue> args = msg->GetArgumentList();
      args->SetDouble(0, arguments[0]->GetDoubleValue());
      args->SetDouble(1, arguments[1]->GetDoubleValue());
      args->SetDouble(2, arguments[2]->GetDoubleValue());
      args->SetBool(3, arguments[3]->GetBoolValue());
      args->SetDouble(4, arguments.size() >= 5 ? arguments[4]->GetDoubleValue() : 0.0);
      args->SetBool(5, arguments.size() >= 6 ? arguments[5]->GetBoolValue() : false);
      args->SetBool(6, arguments.size() >= 7 ? arguments[6]->GetBoolValue() : false);
      args->SetBool(7, arguments.size() >= 8 ? arguments[7]->GetBoolValue() : false);
      args->SetBool(8, arguments.size() >= 9 ? arguments[8]->GetBoolValue() : false);
      args->SetBool(9, arguments.size() >= 10 ? arguments[9]->GetBoolValue() : false);
      frame_->SendProcessMessage(PID_BROWSER, msg);
      return true;
    }
    if (name == "reportNavReady" && arguments.size() >= 1) {
      CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create("sx.nav_ready");
      msg->GetArgumentList()->SetBool(0, arguments[0]->GetBoolValue());
      frame_->SendProcessMessage(PID_BROWSER, msg);
      return true;
    }
    if (name == "reportNavTraverse") {
      CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create("sx.nav_traverse");
      frame_->SendProcessMessage(PID_BROWSER, msg);
      return true;
    }
    if (name == "reportOverscroll" || name == "triggerPullRefresh") {
      return true;
    }
    if (name == "cwsAction" && arguments.size() >= 2) {
      std::string action = arguments[0]->GetStringValue().ToString();
      std::string storeId = arguments[1]->GetStringValue().ToString();
      if (action == "query" || action == "install" || action == "uninstall") {
        CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create("sx.cws_" + action);
        msg->GetArgumentList()->SetString(0, storeId);
        frame_->SendProcessMessage(PID_BROWSER, msg);
        return true;
      }
    }
    if (name == "extPopupSize" && arguments.size() >= 2) {
      CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create("sx.ext_popup_size");
      CefRefPtr<CefListValue> args = msg->GetArgumentList();
      args->SetDouble(0, arguments[0]->GetDoubleValue());
      args->SetDouble(1, arguments[1]->GetDoubleValue());
      frame_->SendProcessMessage(PID_BROWSER, msg);
      return true;
    }
    if (name == "extTabReload") {
      CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create("sx.ext_tab_reload");
      frame_->SendProcessMessage(PID_BROWSER, msg);
      return true;
    }
    if (name == "extTabCreate" && arguments.size() >= 1) {
      CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create("sx.ext_tab_create");
      msg->GetArgumentList()->SetString(0, arguments[0]->GetStringValue());
      frame_->SendProcessMessage(PID_BROWSER, msg);
      return true;
    }
    if (name == "extWindowCreate" && arguments.size() >= 1) {
      CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create("sx.ext_window_create");
      CefRefPtr<CefListValue> args = msg->GetArgumentList();
      args->SetString(0, arguments[0]->GetStringValue());
      args->SetDouble(1, arguments.size() >= 2 ? arguments[1]->GetDoubleValue() : 380.0);
      args->SetDouble(2, arguments.size() >= 3 ? arguments[2]->GetDoubleValue() : 630.0);
      args->SetDouble(3, arguments.size() >= 4 ? arguments[3]->GetDoubleValue() : -1.0);
      args->SetDouble(4, arguments.size() >= 5 ? arguments[4]->GetDoubleValue() : -1.0);
      frame_->SendProcessMessage(PID_BROWSER, msg);
      return true;
    }
    if (name == "extWindowClose") {
      CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create("sx.ext_window_close");
      frame_->SendProcessMessage(PID_BROWSER, msg);
      return true;
    }
    if (name == "spaceScroll" && arguments.size() >= 1) {
      CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create("sx.space_scroll");
      CefRefPtr<CefListValue> args = msg->GetArgumentList();
      args->SetInt(0, arguments[0]->GetIntValue());
      args->SetBool(1, arguments.size() >= 2 ? arguments[1]->GetBoolValue() : false);
      frame_->SendProcessMessage(PID_BROWSER, msg);
      return true;
    }
    if (name == "reportFixedHeader" && arguments.size() >= 4) {
      CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create("sx.fixed_header");
      CefRefPtr<CefListValue> args = msg->GetArgumentList();
      args->SetBool(0, arguments[0]->GetBoolValue());
      args->SetDouble(1, arguments[1]->GetDoubleValue());
      args->SetDouble(2, arguments[2]->GetDoubleValue());
      args->SetDouble(3, arguments[3]->GetDoubleValue());
      args->SetDouble(4, arguments.size() >= 5 ? arguments[4]->GetDoubleValue() : 1.0);
      frame_->SendProcessMessage(PID_BROWSER, msg);
      return true;
    }
    if (name == "reportPageBg" && arguments.size() >= 3) {
      CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create("sx.page_bg");
      CefRefPtr<CefListValue> args = msg->GetArgumentList();
      args->SetDouble(0, arguments[0]->GetDoubleValue());
      args->SetDouble(1, arguments[1]->GetDoubleValue());
      args->SetDouble(2, arguments[2]->GetDoubleValue());
      frame_->SendProcessMessage(PID_BROWSER, msg);
      return true;
    }
    if (name == "reportNativeVideo" && arguments.size() >= 8) {
      CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create("sx.native_video");
      CefRefPtr<CefListValue> args = msg->GetArgumentList();
      args->SetString(0, arguments[0]->GetStringValue()); // videoId
      args->SetString(1, arguments[1]->GetStringValue()); // srcURL
      args->SetDouble(2, arguments[2]->GetDoubleValue()); // x
      args->SetDouble(3, arguments[3]->GetDoubleValue()); // y
      args->SetDouble(4, arguments[4]->GetDoubleValue()); // width
      args->SetDouble(5, arguments[5]->GetDoubleValue()); // height
      args->SetBool(6, arguments[6]->GetBoolValue());     // visible
      args->SetBool(7, arguments[7]->GetBoolValue());     // autoplay
      frame_->SendProcessMessage(PID_BROWSER, msg);
      return true;
    }
    if (name == "reportAuthEvent" && arguments.size() >= 1) {
      CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create("sx.auth_event");
      CefRefPtr<CefListValue> args = msg->GetArgumentList();
      args->SetString(0, arguments[0]->GetStringValue());
      frame_->SendProcessMessage(PID_BROWSER, msg);
      return true;
    }
    if (name == "reportPrivacyFpEvent" && arguments.size() >= 1) {
      CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create("sx_privacy_fp_event");
      CefRefPtr<CefListValue> args = msg->GetArgumentList();
      args->SetString(0, arguments[0]->GetStringValue());
      frame_->SendProcessMessage(PID_BROWSER, msg);
      return true;
    }
    return false;
  }

 private:
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<CefFrame> frame_;
  IMPLEMENT_REFCOUNTING(SXTelemetryV8Handler);
};

struct SXFrameHooks {
  CefRefPtr<CefV8Context> context;
  CefRefPtr<CefV8Value> onScrollPhaseFn;
  CefRefPtr<CefV8Value> onResetOverscrollFn;
  CefRefPtr<CefV8Value> onCwsStateFn;
};

struct SXPopupContextInfo {
  std::string extId;
  std::string activeUrl;
  std::string activeTitle;
  int activeTabId = 1;
  bool activeLoading = false;
  bool isPopout = false;
  int hostWinLeft = 120;
  int hostWinTop = 80;
  int hostWinWidth = 1200;
  int hostWinHeight = 800;
};

struct SXPrivacyRenderConfig {
  int ref_count = 0;
  int top_inset = 0;   // px the page is inset below Safarium's toolbar (0 = not a toolbar tab, e.g. sign-in popup)
  bool is_private = false;
  bool fp_enabled = true;
  int fp_scope = 1;    // 0 = Private Only, 1 = All Browsing
  bool gpc_enabled = false;
  int level = 0;       // 0 = Standard, 1 = Strict
  int cb_default = 0;  // 0 = On, 1 = Off
  int mic_default = 0; // 0 = Ask, 1 = Deny, 2 = Allow
  int cam_default = 0; // 0 = Ask, 1 = Deny, 2 = Allow
  std::string session_salt;
  std::unordered_set<std::string> disabled_hosts;
  std::unordered_set<std::string> enabled_hosts;
  std::unordered_set<std::string> mic_allowed_hosts;
  std::unordered_set<std::string> cam_allowed_hosts;
};

SXPrivacyRenderConfig& SXLaunchPrivacyConfig() {
  static SXPrivacyRenderConfig* cfg = new SXPrivacyRenderConfig();
  return *cfg;
}

void SXInitLaunchPrivacyConfig(int argc, char* argv[]) {
  auto& cfg = SXLaunchPrivacyConfig();
  for (int i = 1; i < argc; ++i) {
    if (!argv[i]) continue;
    std::string arg(argv[i]);
    if (arg.rfind("--sx-privacy-fp=", 0) == 0) {
      cfg.fp_enabled = (arg.substr(16) != "0");
    } else if (arg.rfind("--sx-privacy-scope=", 0) == 0) {
      cfg.fp_scope = std::atoi(arg.substr(19).c_str());
    } else if (arg.rfind("--sx-privacy-gpc=", 0) == 0) {
      cfg.gpc_enabled = (arg.substr(17) == "1");
    } else if (arg.rfind("--sx-privacy-level=", 0) == 0) {
      cfg.level = std::atoi(arg.substr(19).c_str());
    } else if (arg.rfind("--sx-privacy-cb-default=", 0) == 0) {
      cfg.cb_default = std::atoi(arg.substr(24).c_str());
    } else if (arg.rfind("--sx-privacy-mic-default=", 0) == 0) {
      cfg.mic_default = std::atoi(arg.substr(25).c_str());
    } else if (arg.rfind("--sx-privacy-cam-default=", 0) == 0) {
      cfg.cam_default = std::atoi(arg.substr(25).c_str());
    } else if (arg.rfind("--sx-privacy-salt=", 0) == 0) {
      cfg.session_salt = arg.substr(18);
    } else if (arg.rfind("--sx-privacy-disabled-hosts=", 0) == 0) {
      SXParseCommaHosts(arg.substr(28), cfg.disabled_hosts);
    } else if (arg.rfind("--sx-privacy-enabled-hosts=", 0) == 0) {
      SXParseCommaHosts(arg.substr(27), cfg.enabled_hosts);
    } else if (arg.rfind("--sx-privacy-mic-allowed-hosts=", 0) == 0) {
      SXParseCommaHosts(arg.substr(31), cfg.mic_allowed_hosts);
    } else if (arg.rfind("--sx-privacy-cam-allowed-hosts=", 0) == 0) {
      SXParseCommaHosts(arg.substr(31), cfg.cam_allowed_hosts);
    }
  }
  if (cfg.session_salt.empty()) {
    cfg.session_salt = SXDefaultSessionSalt();
  }
}

// Unified Native Safari Biometric Auth Bridge (Sign in with Apple, WebAuthn Level 3 Passkeys, & Apple Passwords AutoFill).
// Injected identically into main frames, auth popups, and eligible subframes (e.g. idmsa.apple.com).
static const char* const kUnifiedSafariAuthBridgeJS = R"JS(
  (function(reportAuthEvent) {
    if (typeof reportAuthEvent !== 'function') return;
    if (window.__safariumAuthInstalled) return;
    window.__safariumAuthInstalled = true;

    function sendAuth(obj) {
      try { reportAuthEvent(JSON.stringify(obj)); } catch (_) {}
    }

    function toB64Url(buf) {
      if (!buf) return '';
      const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf.buffer ? buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength) : buf);
      let bin = '';
      for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
      return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    }

    function fromB64Url(str) {
      if (!str) return new ArrayBuffer(0);
      let s = String(str).replace(/-/g, '+').replace(/_/g, '/');
      while (s.length % 4) s += '=';
      const bin = atob(s);
      const out = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
      return out.buffer;
    }

    function cleanSiteDisplayName() {
      try {
        const og = document.querySelector('meta[property="og:site_name"], meta[name="application-name"], meta[name="apple-mobile-web-app-title"]');
        if (og && og.content && og.content.trim().length > 0 && og.content.trim().length <= 42) {
          return og.content.trim();
        }
      } catch (_) {}
      const rawTitle = (document.title || '').trim();
      if (rawTitle) {
        const parts = rawTitle.split(/\s*[|\u2014\u2013\-\u00b7:]\s*/).map(function(s) { return s.trim(); }).filter(Boolean);
        const genericRe = /^(sign\s*in|log\s*in|login|register|sign\s*up|welcome|authorize|auth|account|home)$/i;
        for (let i = parts.length - 1; i >= 0; i--) {
          if (!genericRe.test(parts[i]) && parts[i].length >= 2 && parts[i].length <= 36) {
            return parts[i];
          }
        }
      }
      let h = (window.location && window.location.hostname || '').replace(/^www\./i, '');
      const seg = h.split('.')[0] || h;
      return seg ? (seg.charAt(0).toUpperCase() + seg.slice(1)) : h;
    }

    function bestPageIconURL() {
      try {
        const selectors = [
          'link[rel="apple-touch-icon"]',
          'link[rel="apple-touch-icon-precomposed"]',
          'link[rel="icon"][sizes*="192"]',
          'link[rel="icon"][sizes*="180"]',
          'link[rel="icon"][sizes*="128"]',
          'link[rel="icon"][type="image/png"]',
          'link[rel*="icon"]'
        ];
        for (let i = 0; i < selectors.length; i++) {
          const el = document.querySelector(selectors[i]);
          if (el && el.href) return el.href;
        }
      } catch (_) {}
      return '';
    }

    // --- 1. WebAuthn Level 3 / Passkeys Bridge ---
    const pendingWebAuthn = new Map();
    let webAuthnSeq = 0;
    let activeConditionalReqId = null;

    if (navigator.credentials && typeof navigator.credentials.get === 'function') {
      const origGet = navigator.credentials.get.bind(navigator.credentials);
      const origCreate = navigator.credentials.create.bind(navigator.credentials);

      function patchPublicKeyCredentialStatics(pkCtor) {
        if (!pkCtor || pkCtor.__sxPatched) return;
        const defPKStatic = function(name, fn) {
          try {
            Object.defineProperty(pkCtor, name, {
              value: fn,
              configurable: true,
              writable: true,
              enumerable: true
            });
          } catch (_) {
            try { pkCtor[name] = fn; } catch (__) {}
          }
        };
        const origCaps = typeof pkCtor.getClientCapabilities === 'function'
          ? pkCtor.getClientCapabilities.bind(pkCtor)
          : null;
        defPKStatic('isUserVerifyingPlatformAuthenticatorAvailable', function() {
          return Promise.resolve(true);
        });
        defPKStatic('isConditionalMediationAvailable', function() {
          return Promise.resolve(true);
        });
        defPKStatic('getClientCapabilities', function() {
          const overrideCaps = {
            conditionalCreate: true,
            conditionalGet: true,
            hybridTransport: true,
            passkeyPlatformAuthenticator: true,
            userVerifyingPlatformAuthenticator: true
          };
          if (origCaps) {
            return Promise.resolve().then(function() { return origCaps(); }).then(function(base) {
              return Object.assign({}, base || {}, overrideCaps);
            }).catch(function() {
              return Object.assign({ relatedOrigins: false }, overrideCaps);
            });
          }
          return Promise.resolve(Object.assign({ relatedOrigins: false }, overrideCaps));
        });
        try { pkCtor.__sxPatched = true; } catch (_) {}
      }

      if (window.PublicKeyCredential) {
        patchPublicKeyCredentialStatics(window.PublicKeyCredential);
      } else {
        try {
          let _pkCtor = undefined;
          Object.defineProperty(window, 'PublicKeyCredential', {
            configurable: true,
            enumerable: false,
            get: function() { return _pkCtor; },
            set: function(v) {
              _pkCtor = v;
              patchPublicKeyCredentialStatics(v);
            }
          });
        } catch (_) {}
      }
      if (typeof queueMicrotask === 'function') {
        queueMicrotask(function() {
          if (window.PublicKeyCredential) patchPublicKeyCredentialStatics(window.PublicKeyCredential);
        });
      }
      document.addEventListener('readystatechange', function() {
        if (window.PublicKeyCredential) patchPublicKeyCredentialStatics(window.PublicKeyCredential);
      }, { capture: true, passive: true });

      navigator.credentials.create = function(options) {
        if (!options || !options.publicKey) {
          return origCreate(options);
        }
        const pk = options.publicKey;
        const reqId = 'wa_c_' + (++webAuthnSeq);
        const wantsCredProps = !!(pk.extensions && pk.extensions.credProps);
        return new Promise(function(resolve, reject) {
          pendingWebAuthn.set(reqId, { kind: 'create', resolve, reject, origArgs: options, origFn: origCreate, wantsCredProps });
          if (options.signal) {
            if (options.signal.aborted) {
              pendingWebAuthn.delete(reqId);
              reject(new DOMException('The operation was aborted.', 'AbortError'));
              return;
            }
            options.signal.addEventListener('abort', function() {
              if (pendingWebAuthn.has(reqId)) {
                pendingWebAuthn.delete(reqId);
                sendAuth({ type: 'webauthn_abort', reqId });
                reject(new DOMException('The operation was aborted.', 'AbortError'));
              }
            }, { once: true });
          }
          const authSel = pk.authenticatorSelection || {};
          const payload = {
            type: 'webauthn_create',
            reqId,
            origin: window.location.origin,
            host: window.location.hostname,
            siteName: cleanSiteDisplayName(),
            iconURL: bestPageIconURL(),
            publicKey: {
              challenge: toB64Url(pk.challenge),
              rp: { id: (pk.rp && pk.rp.id) || window.location.hostname, name: (pk.rp && pk.rp.name) || cleanSiteDisplayName() || window.location.hostname },
              user: {
                id: toB64Url(pk.user && pk.user.id),
                name: (pk.user && pk.user.name) || '',
                displayName: (pk.user && pk.user.displayName) || (pk.user && pk.user.name) || ''
              },
              pubKeyCredParams: (pk.pubKeyCredParams || []).map(function(p) { return { type: p.type, alg: p.alg }; }),
              excludeCredentials: (pk.excludeCredentials || []).map(function(c) { return { id: toB64Url(c.id), type: c.type }; }),
              authenticatorSelection: {
                authenticatorAttachment: authSel.authenticatorAttachment || '',
                residentKey: authSel.residentKey || (authSel.requireResidentKey ? 'required' : 'preferred'),
                userVerification: authSel.userVerification || 'preferred'
              },
              credProps: wantsCredProps
            }
          };
          sendAuth(payload);
        });
      };

      navigator.credentials.get = function(options) {
        if (!options || !options.publicKey) {
          return origGet(options);
        }
        const pk = options.publicKey;
        const reqId = 'wa_g_' + (++webAuthnSeq);
        const mediation = options.mediation || 'optional';
        if (mediation === 'conditional') {
          activeConditionalReqId = reqId;
        }
        return new Promise(function(resolve, reject) {
          pendingWebAuthn.set(reqId, { kind: 'get', resolve, reject, origArgs: options, origFn: origGet, mediation });
          if (options.signal) {
            if (options.signal.aborted) {
              pendingWebAuthn.delete(reqId);
              if (activeConditionalReqId === reqId) activeConditionalReqId = null;
              reject(new DOMException('The operation was aborted.', 'AbortError'));
              return;
            }
            options.signal.addEventListener('abort', function() {
              if (pendingWebAuthn.has(reqId)) {
                pendingWebAuthn.delete(reqId);
                if (activeConditionalReqId === reqId) activeConditionalReqId = null;
                sendAuth({ type: 'webauthn_abort', reqId });
                reject(new DOMException('The operation was aborted.', 'AbortError'));
              }
            }, { once: true });
          }
          let topOrigin = window.location.origin;
          let isCrossOrigin = false;
          try {
            if (window.top && window.top !== window) {
              topOrigin = window.top.location.origin;
              isCrossOrigin = (topOrigin !== window.location.origin);
            }
          } catch (_) {
            isCrossOrigin = true;
            try { topOrigin = document.referrer ? new URL(document.referrer).origin : window.location.origin; } catch (__) {}
          }
          const payload = {
            type: 'webauthn_get',
            reqId,
            origin: window.location.origin,
            topOrigin: topOrigin,
            isCrossOrigin: isCrossOrigin,
            host: window.location.hostname,
            siteName: cleanSiteDisplayName(),
            iconURL: bestPageIconURL(),
            mediation,
            publicKey: {
              challenge: toB64Url(pk.challenge),
              rpId: pk.rpId || window.location.hostname,
              allowCredentials: (pk.allowCredentials || []).map(function(c) { return { id: toB64Url(c.id), type: c.type }; }),
              userVerification: pk.userVerification || 'preferred'
            }
          };
          sendAuth(payload);
        });
      };

      window.__safariumResolveWebAuthn = function(reqId, res) {
        const entry = pendingWebAuthn.get(reqId);
        if (!entry) return;
        pendingWebAuthn.delete(reqId);
        if (activeConditionalReqId === reqId) activeConditionalReqId = null;
        try {
          const rawIdBuf = fromB64Url(res.rawId);
          if (entry.kind === 'create') {
            const attObjBuf = fromB64Url(res.attestationObject);
            const clientDataBuf = fromB64Url(res.clientDataJSON);
            const authDataBuf = fromB64Url(res.authenticatorData);
            const spkiBuf = fromB64Url(res.publicKeySpki);
            const extRes = entry.wantsCredProps ? { credProps: { rk: true } } : {};
            const response = {
              clientDataJSON: clientDataBuf,
              attestationObject: attObjBuf,
              getTransports: function() { return ['internal', 'hybrid']; },
              getAuthenticatorData: function() { return authDataBuf; },
              getPublicKey: function() { return spkiBuf; },
              getPublicKeyAlgorithm: function() { return -7; }
            };
            if (window.AuthenticatorAttestationResponse) {
              try { Object.setPrototypeOf(response, window.AuthenticatorAttestationResponse.prototype); } catch (_) {}
            }
            const cred = {
              id: res.id,
              rawId: rawIdBuf,
              type: 'public-key',
              authenticatorAttachment: 'platform',
              response: response,
              getClientExtensionResults: function() { return extRes; },
              toJSON: function() {
                return {
                  id: res.id,
                  rawId: res.rawId,
                  type: 'public-key',
                  authenticatorAttachment: 'platform',
                  response: {
                    clientDataJSON: res.clientDataJSON,
                    attestationObject: res.attestationObject,
                    authenticatorData: res.authenticatorData,
                    publicKey: res.publicKeySpki,
                    publicKeyAlgorithm: -7,
                    transports: ['internal', 'hybrid']
                  },
                  clientExtensionResults: extRes
                };
              }
            };
            if (window.PublicKeyCredential) {
              try { Object.setPrototypeOf(cred, window.PublicKeyCredential.prototype); } catch (_) {}
            }
            entry.resolve(cred);
          } else {
            const clientDataBuf = fromB64Url(res.clientDataJSON);
            const authDataBuf = fromB64Url(res.authenticatorData);
            const sigBuf = fromB64Url(res.signature);
            const userHandleBuf = res.userHandle ? fromB64Url(res.userHandle) : null;
            const response = {
              clientDataJSON: clientDataBuf,
              authenticatorData: authDataBuf,
              signature: sigBuf,
              userHandle: userHandleBuf
            };
            if (window.AuthenticatorAssertionResponse) {
              try { Object.setPrototypeOf(response, window.AuthenticatorAssertionResponse.prototype); } catch (_) {}
            }
            const cred = {
              id: res.id,
              rawId: rawIdBuf,
              type: 'public-key',
              authenticatorAttachment: 'platform',
              response: response,
              getClientExtensionResults: function() { return {}; },
              toJSON: function() {
                return {
                  id: res.id,
                  rawId: res.rawId,
                  type: 'public-key',
                  authenticatorAttachment: 'platform',
                  response: {
                    clientDataJSON: res.clientDataJSON,
                    authenticatorData: res.authenticatorData,
                    signature: res.signature,
                    userHandle: res.userHandle || null
                  },
                  clientExtensionResults: {}
                };
              }
            };
            if (window.PublicKeyCredential) {
              try { Object.setPrototypeOf(cred, window.PublicKeyCredential.prototype); } catch (_) {}
            }
            entry.resolve(cred);
          }
        } catch (err) {
          entry.reject(err);
        }
      };

      window.__safariumRejectWebAuthn = function(reqId, name, message) {
        const entry = pendingWebAuthn.get(reqId);
        if (!entry) return;
        pendingWebAuthn.delete(reqId);
        if (activeConditionalReqId === reqId) activeConditionalReqId = null;
        entry.reject(new DOMException(message || 'The operation was cancelled.', name || 'NotAllowedError'));
      };

      window.__safariumFallbackWebAuthn = function(reqId) {
        const entry = pendingWebAuthn.get(reqId);
        if (!entry) return;
        pendingWebAuthn.delete(reqId);
        if (activeConditionalReqId === reqId) activeConditionalReqId = null;
        Promise.resolve(entry.origFn(entry.origArgs)).then(entry.resolve, entry.reject);
      };
    }

    // --- 2. Sign in with Apple Native Sheet Intent & Apple Auth Automation Bridge ---
    (function installSignInWithAppleBridge() {
      const hostname = (window.location && window.location.hostname || '').toLowerCase();
      const pathname = (window.location && window.location.pathname || '');
      const isAppleAuthHost =
        hostname === 'appleid.apple.com' || hostname.endsWith('.appleid.apple.com') ||
        hostname === 'idmsa.apple.com' || hostname.endsWith('.idmsa.apple.com');

      function setInputValue(el, val) {
        if (!el || val == null) return;
        el.focus();
        const desc = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
        if (desc && desc.set) desc.set.call(el, val);
        else el.value = val;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        el.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: 'Enter', keyCode: 13 }));
      }

      if (!isAppleAuthHost) {
        // Relying-party webpage (e.g. janitorai.com): capture Sign in with Apple clicks & AppleJS calls
        function hookAppleJS() {
          try {
            if (window.AppleID && window.AppleID.auth && typeof window.AppleID.auth.signIn === 'function' && !window.AppleID.auth.__sxWrapped) {
              const origSignIn = window.AppleID.auth.signIn.bind(window.AppleID.auth);
              const origInit = typeof window.AppleID.auth.init === 'function' ? window.AppleID.auth.init.bind(window.AppleID.auth) : null;
              let savedCfg = window.__sxAppleJSCfg || {};
              if (origInit) {
                window.AppleID.auth.init = function(cfg) {
                  if (cfg && typeof cfg === 'object') {
                    savedCfg = Object.assign({}, savedCfg, cfg);
                    window.__sxAppleJSCfg = savedCfg;
                  }
                  return origInit(cfg);
                };
              }
              const wrappedSignIn = function(signInCfg) {
                const merged = Object.assign({}, savedCfg, signInCfg || {});
                sendAuth({
                  type: 'apple_signin_intent',
                  source: 'applejs',
                  host: window.location.hostname,
                  origin: window.location.origin,
                  siteName: cleanSiteDisplayName(),
                  iconURL: bestPageIconURL(),
                  clientId: merged.clientId || '',
                  redirectURI: merged.redirectURI || '',
                  scope: merged.scope || '',
                  state: merged.state || '',
                  usePopup: !!merged.usePopup
                });
                return origSignIn(signInCfg);
              };
              window.AppleID.auth.signIn = wrappedSignIn;
              window.AppleID.auth.__sxWrapped = true;
            }
          } catch (_) {}
        }
        hookAppleJS();
        try {
          if (!('AppleID' in window)) {
            let _appleIDVal = undefined;
            Object.defineProperty(window, 'AppleID', {
              configurable: true,
              enumerable: true,
              get: function() { return _appleIDVal; },
              set: function(v) {
                _appleIDVal = v;
                hookAppleJS();
              }
            });
          }
        } catch (_) {}
        document.addEventListener('DOMContentLoaded', hookAppleJS, { once: true, passive: true });
        window.addEventListener('load', hookAppleJS, { once: true, passive: true });

        document.addEventListener('click', function(e) {
          try {
            hookAppleJS();
            let el = e.target;
            for (let hop = 0; hop < 6 && el && el !== document.body; hop++, el = el.parentElement) {
              if (!el.tagName) continue;
              const dataProv = (el.getAttribute && (el.getAttribute('data-provider') || el.getAttribute('data-oauth-provider') || el.getAttribute('data-social') || '')) || '';
              const idCls = ((el.id || '') + ' ' + (typeof el.className === 'string' ? el.className : '') + ' ' + dataProv + ' ' + ((el.getAttribute && el.getAttribute('data-testid')) || '')).toLowerCase();
              const href = (el.getAttribute && el.getAttribute('href')) || '';
              const aria = ((el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('title'))) || '').trim();
              const rawOwnTxt = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
              const txt = (rawOwnTxt + ' ' + aria).replace(/\s+/g, ' ').trim();
              const isBtnLike = el.tagName === 'BUTTON' || el.tagName === 'A' || (el.getAttribute && el.getAttribute('role') === 'button');
              const isAppleLink = href.indexOf('appleid.apple.com/auth/authorize') !== -1 ||
                (/[?&]provider=apple(?:&|$)/i.test(href) || /\/(?:auth|oauth|login|signin)\/apple(?:\b|\/|\?|$)/i.test(href));
              const isAppleAttr = /\b(appleid-signin|sign-in-with-apple|signin-with-apple|apple-login|apple-signin|apple-auth|oauth-apple|provider-apple|social-apple)\b/i.test(idCls) ||
                el.hasAttribute('data-apple-signin') ||
                /^(apple|apple\.com)$/i.test(dataProv.trim());
              const isExplicitApplePhrase = isBtnLike &&
                /\b(sign\s*in|continue|log\s*in|sign\s*up|authenticate)\s+(?:with\s+)?apple\b/i.test(txt);
              const isCompactSocialAppleBtn = (el.tagName === 'BUTTON' || (el.getAttribute && el.getAttribute('role') === 'button')) &&
                (/^apple$/i.test(rawOwnTxt) || /^apple$/i.test(aria)) &&
                (!!el.querySelector('svg, img, i, [class*="icon"]') || /\b(auth|login|signin|sign-in|oauth|social|provider|sso)\b/i.test(idCls + ' ' + (window.location.pathname || '')));
              if (isAppleLink || isAppleAttr || isExplicitApplePhrase || isCompactSocialAppleBtn) {
                sendAuth({
                  type: 'apple_signin_intent',
                  source: isAppleLink ? 'link' : 'button',
                  host: window.location.hostname,
                  origin: window.location.origin,
                  siteName: cleanSiteDisplayName(),
                  iconURL: bestPageIconURL(),
                  targetURL: href || ''
                });
                break;
              }
            }
          } catch (_) {}
        }, true);
        return;
      }

      // On appleid.apple.com or idmsa.apple.com:
      let lastReportedStep = '';
      function isVisible(el) {
        if (!el) return false;
        const r = el.getBoundingClientRect();
        if (r.width < 4 || r.height < 4) return false;
        const cs = window.getComputedStyle(el);
        return cs.display !== 'none' && cs.visibility !== 'hidden' && parseFloat(cs.opacity || '1') > 0.05;
      }

      function parseAuthorizeMeta() {
        const sp = new URLSearchParams(window.location.search || '');
        let rpName = '';
        let rpIcon = '';
        try {
          const nameEl = document.querySelector('.app-name, .rp-name, [class*="app-title"], .si-container-title strong, .delegated-client-name');
          if (nameEl && nameEl.textContent) rpName = nameEl.textContent.trim();
          if (!rpName) {
            const bodyTxt = (document.body && document.body.innerText) || '';
            const m = bodyTxt.match(/Sign in to\s+([^\n.]+?)\s+with your Apple/i) ||
                      bodyTxt.match(/Use your Apple\s+(?:Account|ID)\s+to sign in to\s+([^\n.]+)/i);
            if (m && m[1]) rpName = m[1].trim();
          }
          const imgEl = document.querySelector('img.app-icon, img[class*="app-icon"], .si-app-icon img, img[alt*="icon" i]');
          if (imgEl && imgEl.src) rpIcon = imgEl.src;
        } catch (_) {}
        return {
          clientId: sp.get('client_id') || '',
          redirectURI: sp.get('redirect_uri') || '',
          scope: sp.get('scope') || '',
          state: sp.get('state') || '',
          responseMode: sp.get('response_mode') || '',
          rpName: rpName,
          rpIcon: rpIcon
        };
      }

      function findContinueConsentButton() {
        const candidates = Array.from(document.querySelectorAll('button, [role="button"], input[type="submit"]'));
        for (let i = 0; i < candidates.length; i++) {
          const b = candidates[i];
          if (!isVisible(b) || b.disabled) continue;
          const label = ((b.innerText || b.value || b.getAttribute('aria-label') || '')).trim();
          const id = (b.id || '').toLowerCase();
          if (id === 'continue-password' || /^continue$/i.test(label) || /^continue with/i.test(label)) {
            const acct = document.querySelector('#account_name_text_field');
            const pw = document.querySelector('#password_text_field');
            if (!isVisible(acct) && !isVisible(pw)) return b;
          }
        }
        return null;
      }

      function inspectAppleAuthStep(force) {
        try {
          const twoFactorEl = document.querySelector('input.security-code-input, input[id^="char"], .security-code-container input, [data-focus-input-index]');
          const errEl = document.querySelector('.si-error-message, .form-message-wrapper .form-message, [id*="errMsg"], .has-error .error');
          const pwEl = document.querySelector('#password_text_field, input[type="password"]');
          const acctEl = document.querySelector('#account_name_text_field, input[name="accountName"], input[autocomplete*="username"]');
          const continueBtn = findContinueConsentButton();

          let step = 'loading';
          let errorMessage = '';
          if (errEl && isVisible(errEl) && (errEl.textContent || '').trim().length > 0) {
            errorMessage = (errEl.textContent || '').trim();
          }
          if (twoFactorEl && isVisible(twoFactorEl)) {
            step = 'two_factor';
          } else if (continueBtn) {
            step = 'consent_ready';
          } else if ((pwEl && isVisible(pwEl)) || (acctEl && isVisible(acctEl))) {
            step = errorMessage ? 'credentials_error' : 'credentials_needed';
          } else if (pathname.indexOf('/auth/authorize') !== -1) {
            step = 'authorize_shell';
          }

          const key = step + '|' + errorMessage;
          if (!force && key === lastReportedStep) return;
          lastReportedStep = key;

          const meta = parseAuthorizeMeta();
          sendAuth({
            type: 'apple_signin_page_state',
            host: hostname,
            url: window.location.href,
            isMainFrame: (window.top === window),
            step: step,
            errorMessage: errorMessage,
            clientId: meta.clientId,
            redirectURI: meta.redirectURI,
            scope: meta.scope,
            rpName: meta.rpName,
            rpIcon: meta.rpIcon
          });
        } catch (_) {}
      }

      window.__safariumDriveAppleSignIn = function(cmd) {
        if (!cmd || typeof cmd !== 'object') return;
        try {
          if (cmd.action === 'cancel') {
            const cancelBtn = document.querySelector('button.button-secondary, button[id*="cancel" i], a[id*="cancel" i]');
            if (cancelBtn && isVisible(cancelBtn)) cancelBtn.click();
            return;
          }
          if (cmd.action === 'continueOrSubmit') {
            if (typeof cmd.hideEmail === 'boolean') {
              const radios = Array.from(document.querySelectorAll('input[type="radio"]'));
              for (let i = 0; i < radios.length; i++) {
                const r = radios[i];
                const lbl = ((r.closest('label') || r.parentElement || {}).innerText || r.value || '').toLowerCase();
                if (cmd.hideEmail && lbl.indexOf('hide') !== -1) { r.click(); break; }
                if (!cmd.hideEmail && lbl.indexOf('share') !== -1) { r.click(); break; }
              }
            }
            const consentBtn = findContinueConsentButton();
            if (consentBtn) {
              consentBtn.click();
              return;
            }
            const acctEl = document.querySelector('#account_name_text_field, input[name="accountName"]');
            const pwEl = document.querySelector('#password_text_field, input[type="password"]');
            const signInBtn = document.querySelector('#sign-in, button#continue-password, button[type="submit"]');

            if (pwEl && isVisible(pwEl) && cmd.password) {
              if (acctEl && isVisible(acctEl) && cmd.appleId && !acctEl.value) {
                setInputValue(acctEl, cmd.appleId);
              }
              setInputValue(pwEl, cmd.password);
              setTimeout(function() {
                const btn = document.querySelector('#sign-in, button[type="submit"]');
                if (btn) btn.click();
              }, 80);
              return;
            }

            if (acctEl && isVisible(acctEl) && cmd.appleId) {
              setInputValue(acctEl, cmd.appleId);
              if (signInBtn) signInBtn.click();
              if (cmd.password) {
                let tries = 0;
                const timer = setInterval(function() {
                  tries++;
                  const nextPw = document.querySelector('#password_text_field, input[type="password"]');
                  if (nextPw && isVisible(nextPw)) {
                    clearInterval(timer);
                    setInputValue(nextPw, cmd.password);
                    setTimeout(function() {
                      const submitBtn = document.querySelector('#sign-in, button[type="submit"]');
                      if (submitBtn) submitBtn.click();
                    }, 90);
                  } else if (tries >= 30) {
                    clearInterval(timer);
                    inspectAppleAuthStep(true);
                  }
                }, 150);
              }
              return;
            }

            if ((acctEl && isVisible(acctEl)) || (pwEl && isVisible(pwEl))) {
              sendAuth({
                type: 'apple_signin_needs_interactive',
                host: hostname,
                reason: 'credentials_required'
              });
            }
          }
        } catch (_) {}
      };

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function() { inspectAppleAuthStep(true); }, { once: true, passive: true });
      } else {
        setTimeout(function() { inspectAppleAuthStep(true); }, 20);
      }
      window.addEventListener('load', function() { inspectAppleAuthStep(true); }, { once: true, passive: true });
      const attachMO = function() {
        if (!document.documentElement) return;
        const mo = new MutationObserver(function() { inspectAppleAuthStep(false); });
        mo.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'style', 'hidden', 'aria-hidden'] });
      };
      attachMO();
    })();

    // --- 3. Inline Apple Passwords AutoFill & Save Detector ---
    let activeAuthInput = null;
    let blurTimer = null;

    function classifyInput(el) {
      if (!el || el.tagName !== 'INPUT' || el.disabled || el.readOnly) return null;
      const type = (el.type || 'text').toLowerCase();
      const ac = (el.getAttribute('autocomplete') || '').toLowerCase();
      const nameId = ((el.name || '') + ' ' + (el.id || '') + ' ' + (el.placeholder || '')).toLowerCase();
      if (type === 'password') {
        return ac.includes('new-password') ? 'new-password' : 'password';
      }
      if (type === 'email' || type === 'text' || type === 'tel') {
        if (el.id === 'account_name_text_field' || ac.includes('username') || ac.includes('webauthn') || ac.includes('email')) {
          return 'username';
        }
        const form = el.form || el.closest('form') || document;
        const hasPw = !!form.querySelector('input[type="password"]');
        if (hasPw && /(user|email|login|account|phone|id)/i.test(nameId)) {
          return 'username';
        }
        if (/(email|username|login|apple.?id|account_name)/i.test(nameId) && !/(search|query|filter)/i.test(nameId)) {
          return 'username';
        }
      }
      return null;
    }

    function findPairedInputs(focused) {
      const scope = (focused && (focused.form || focused.closest('form'))) || document;
      const inputs = Array.from(scope.querySelectorAll('input')).filter(function(i) {
        if (i.disabled || i.readOnly) return false;
        const r = i.getBoundingClientRect();
        return r.width > 20 && r.height > 10;
      });
      let userEl = null;
      let passEl = null;
      for (let i = 0; i < inputs.length; i++) {
        const kind = classifyInput(inputs[i]);
        if ((kind === 'password' || kind === 'new-password') && !passEl) passEl = inputs[i];
        if (kind === 'username' && !userEl) userEl = inputs[i];
      }
      if (focused) {
        const fk = classifyInput(focused);
        if (fk === 'username') userEl = focused;
        if (fk === 'password' || fk === 'new-password') passEl = focused;
      }
      return { userEl, passEl };
    }

    function setNativeInputValue(el, val) {
      if (!el || val == null) return;
      const desc = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
      if (desc && desc.set) {
        desc.set.call(el, val);
      } else {
        el.value = val;
      }
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }

    window.__safariumFillCredentials = function(username, password, onlyPassword) {
      const pair = findPairedInputs(activeAuthInput);
      if (!onlyPassword && pair.userEl && username) {
        setNativeInputValue(pair.userEl, username);
      }
      if (pair.passEl && password) {
        setNativeInputValue(pair.passEl, password);
      } else if (activeAuthInput && onlyPassword && password) {
        setNativeInputValue(activeAuthInput, password);
      }
    };

    function reportFocusFor(el) {
      const kind = classifyInput(el);
      if (!kind) return;
      activeAuthInput = el;
      if (blurTimer) { clearTimeout(blurTimer); blurTimer = null; }
      const r = el.getBoundingClientRect();
      if (r.width < 20 || r.height < 10) return;
      const ac = (el.getAttribute('autocomplete') || '').toLowerCase();
      sendAuth({
        type: 'autofill_focus',
        host: window.location.hostname,
        origin: window.location.origin,
        siteName: cleanSiteDisplayName(),
        iconURL: bestPageIconURL(),
        fieldType: kind,
        value: el.value || '',
        hasPasskeyHint: ac.includes('webauthn') || !!activeConditionalReqId,
        conditionalReqId: activeConditionalReqId || '',
        rect: { x: r.left, y: r.top, width: r.width, height: r.height }
      });
    }

    document.addEventListener('focusin', function(e) {
      reportFocusFor(e.target);
    }, true);

    document.addEventListener('click', function(e) {
      if (e.target && e.target.tagName === 'INPUT') {
        reportFocusFor(e.target);
      }
    }, true);

    document.addEventListener('focusout', function(e) {
      if (e.target === activeAuthInput) {
        if (blurTimer) clearTimeout(blurTimer);
        blurTimer = setTimeout(function() {
          activeAuthInput = null;
          sendAuth({ type: 'autofill_blur' });
        }, 160);
      }
    }, true);

    window.addEventListener('scroll', function() {
      if (activeAuthInput) sendAuth({ type: 'autofill_blur' });
    }, { passive: true, capture: true });

    let lastSavedUser = '';
    document.addEventListener('input', function(e) {
      try {
        const t = e.target;
        if (t && classifyInput(t) === 'username' && t.value && t.value.trim().length > 1) {
          lastSavedUser = t.value.trim();
        }
      } catch (_) {}
    }, true);

    function maybeEmitSaveFromScope(scopeEl) {
      try {
        const root = scopeEl || document;
        const pwEl = root.querySelector ? root.querySelector('input[type="password"]') : null;
        if (!pwEl) return;
        const pair = findPairedInputs(pwEl);
        const u = (pair.userEl && pair.userEl.value ? pair.userEl.value.trim() : '') || lastSavedUser;
        const p = pair.passEl ? (pair.passEl.value || '') : '';
        if (p.length >= 3) {
          sendAuth({
            type: 'autofill_save',
            host: window.location.hostname,
            origin: window.location.origin,
            username: u,
            password: p
          });
        }
      } catch (_) {}
    }

    document.addEventListener('submit', function(e) {
      maybeEmitSaveFromScope(e.target);
    }, true);

    document.addEventListener('click', function(e) {
      const btn = e.target && e.target.closest ? e.target.closest('button#sign-in, button[type="submit"], input[type="submit"]') : null;
      if (btn) maybeEmitSaveFromScope(btn.form || document);
    }, true);
  })
)JS";

class SXHelperApp : public CefApp,
                    public CefRenderProcessHandler,
                    public CefLoadHandler {
 public:
  SXHelperApp() = default;

  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
    return this;
  }

  CefRefPtr<CefLoadHandler> GetLoadHandler() override {
    return this;
  }

  void OnLoadStart(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   TransitionType transition_type) override {
    UpdateProcessNameForFrame(browser, frame);
  }

  void OnBrowserCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDictionaryValue> extra_info) override {
    if (!browser) return;

    const int bid = browser->GetIdentifier();
    auto existingIt = privacy_configs_.find(bid);
    if (existingIt == privacy_configs_.end()) {
      SXPrivacyRenderConfig initial = SXLaunchPrivacyConfig();
      initial.ref_count = 0;
      existingIt = privacy_configs_.emplace(bid, std::move(initial)).first;
    }
    SXPrivacyRenderConfig& pcfg = existingIt->second;
    pcfg.ref_count += 1;
    if (extra_info) {
      if (extra_info->HasKey("sx_top_inset") && extra_info->GetType("sx_top_inset") == VTYPE_INT) {
        pcfg.top_inset = std::max(0, extra_info->GetInt("sx_top_inset"));
      }
      if (extra_info->HasKey("sx_privacy_is_private") &&
          extra_info->GetType("sx_privacy_is_private") == VTYPE_BOOL) {
        pcfg.is_private = extra_info->GetBool("sx_privacy_is_private");
      }
      if (extra_info->HasKey("sx_privacy_fp_enabled") &&
          extra_info->GetType("sx_privacy_fp_enabled") == VTYPE_BOOL) {
        pcfg.fp_enabled = extra_info->GetBool("sx_privacy_fp_enabled");
      }
      if (extra_info->HasKey("sx_privacy_fp_scope") &&
          extra_info->GetType("sx_privacy_fp_scope") == VTYPE_INT) {
        pcfg.fp_scope = extra_info->GetInt("sx_privacy_fp_scope");
      }
      if (extra_info->HasKey("sx_privacy_gpc_enabled") &&
          extra_info->GetType("sx_privacy_gpc_enabled") == VTYPE_BOOL) {
        pcfg.gpc_enabled = extra_info->GetBool("sx_privacy_gpc_enabled");
      }
      if (extra_info->HasKey("sx_privacy_level") &&
          extra_info->GetType("sx_privacy_level") == VTYPE_INT) {
        pcfg.level = extra_info->GetInt("sx_privacy_level");
      }
      if (extra_info->HasKey("sx_privacy_cb_default") &&
          extra_info->GetType("sx_privacy_cb_default") == VTYPE_INT) {
        pcfg.cb_default = extra_info->GetInt("sx_privacy_cb_default");
      }
      if (extra_info->HasKey("sx_privacy_mic_default") &&
          extra_info->GetType("sx_privacy_mic_default") == VTYPE_INT) {
        pcfg.mic_default = extra_info->GetInt("sx_privacy_mic_default");
      }
      if (extra_info->HasKey("sx_privacy_cam_default") &&
          extra_info->GetType("sx_privacy_cam_default") == VTYPE_INT) {
        pcfg.cam_default = extra_info->GetInt("sx_privacy_cam_default");
      }
      if (extra_info->HasKey("sx_privacy_session_salt") &&
          extra_info->GetType("sx_privacy_session_salt") == VTYPE_STRING) {
        pcfg.session_salt = extra_info->GetString("sx_privacy_session_salt").ToString();
      }
      auto loadHostList = [&](const char* key, std::unordered_set<std::string>& dest) {
        if (extra_info->HasKey(key) && extra_info->GetType(key) == VTYPE_LIST) {
          dest.clear();
          CefRefPtr<CefListValue> list = extra_info->GetList(key);
          if (list) {
            size_t count = list->GetSize();
            for (size_t i = 0; i < count; ++i) {
              if (list->GetType(i) == VTYPE_STRING) {
                std::string h = SXNormalizeHost(list->GetString(i).ToString());
                if (!h.empty()) dest.insert(std::move(h));
              }
            }
          }
        }
      };
      loadHostList("sx_privacy_disabled_hosts", pcfg.disabled_hosts);
      loadHostList("sx_privacy_enabled_hosts", pcfg.enabled_hosts);
      loadHostList("sx_privacy_mic_allowed_hosts", pcfg.mic_allowed_hosts);
      loadHostList("sx_privacy_cam_allowed_hosts", pcfg.cam_allowed_hosts);
    }
    if (pcfg.session_salt.empty()) {
      pcfg.session_salt = SXDefaultSessionSalt();
    }

    if (CefRefPtr<CefFrame> mainFrame = browser->GetMainFrame()) {
      if (mainFrame->IsValid()) {
        mainFrame->SendProcessMessage(PID_BROWSER,
                                      CefProcessMessage::Create("sx_privacy_request_config"));
      }
    }

    if (extra_info && extra_info->HasKey("sx_is_ext_popup") && extra_info->GetBool("sx_is_ext_popup")) {
      SXPopupContextInfo info;
      if (extra_info->HasKey("sx_ext_id"))
        info.extId = extra_info->GetString("sx_ext_id").ToString();
      if (extra_info->HasKey("sx_active_tab_url"))
        info.activeUrl = extra_info->GetString("sx_active_tab_url").ToString();
      if (extra_info->HasKey("sx_active_tab_title"))
        info.activeTitle = extra_info->GetString("sx_active_tab_title").ToString();
      if (extra_info->HasKey("sx_active_tab_id"))
        info.activeTabId = extra_info->GetInt("sx_active_tab_id");
      if (extra_info->HasKey("sx_active_tab_loading"))
        info.activeLoading = extra_info->GetBool("sx_active_tab_loading");
      if (extra_info->HasKey("sx_is_ext_popout"))
        info.isPopout = extra_info->GetBool("sx_is_ext_popout");
      if (extra_info->HasKey("sx_host_win_left"))
        info.hostWinLeft = extra_info->GetInt("sx_host_win_left");
      if (extra_info->HasKey("sx_host_win_top"))
        info.hostWinTop = extra_info->GetInt("sx_host_win_top");
      if (extra_info->HasKey("sx_host_win_width"))
        info.hostWinWidth = extra_info->GetInt("sx_host_win_width");
      if (extra_info->HasKey("sx_host_win_height"))
        info.hostWinHeight = extra_info->GetInt("sx_host_win_height");
      if (!info.extId.empty()) {
        std::string label = SXFormatDisplayNameForURL("chrome-extension://" + info.extId + "/");
        if (!label.empty()) {
          main_frame_names_[browser->GetIdentifier()] = label;
          RefreshProcessDisplayName();
        }
      }
      popup_contexts_[browser->GetIdentifier()] = std::move(info);
    }
  }

  void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override {
    if (!browser) return;
    int bid = browser->GetIdentifier();
    popup_contexts_.erase(bid);
    auto pit = privacy_configs_.find(bid);
    if (pit != privacy_configs_.end()) {
      pit->second.ref_count -= 1;
      if (pit->second.ref_count <= 0) {
        privacy_configs_.erase(pit);
        main_frame_nav_nonces_.erase(bid);
      }
    }
    frame_hooks_.erase(bid);
    main_frame_names_.erase(bid);
    subframe_names_.erase(bid);
    RefreshProcessDisplayName();
  }

  void OnContextCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    if (!browser || !frame || !context) {
      return;
    }

    UpdateProcessNameForFrame(browser, frame);

    // Install document-start GPC and anti-fingerprinting protections synchronously
    // on the frame's main V8 world (main frames and eligible subframes) before any
    // webpage script executes. Never inject into isolated MV3 extension worlds.
    CefRefPtr<CefV8Context> frameMainCtx = frame->GetV8Context();
    if (!frameMainCtx || frameMainCtx->IsSame(context)) {
      InstallPrivacyProtectionsIfNeeded(browser, frame, context);
    }

    if (!frame->IsMain()) {
      // Install lightweight Passkeys + Apple Passwords AutoFill bridge inside web iframes
      // (e.g. idmsa.apple.com Sign in with Apple / Passkey widget) on the iframe's main V8 world.
      std::string subURL = frame->GetURL().ToString();
      if (subURL.rfind("chrome-extension://", 0) != 0 && subURL.rfind("chrome://", 0) != 0 && subURL.rfind("devtools://", 0) != 0) {
        CefRefPtr<CefV8Context> subMainCtx = frame->GetV8Context();
        if (!subMainCtx || subMainCtx->IsSame(context)) {
          if (context->Enter()) {
            CefRefPtr<CefV8Value> subInstaller;
            CefRefPtr<CefV8Exception> subEx;
            if (context->Eval(kUnifiedSafariAuthBridgeJS, CefString(), 0, subInstaller, subEx) &&
                subInstaller && subInstaller->IsFunction()) {
              CefRefPtr<CefV8Handler> handler = new SXTelemetryV8Handler(browser, frame);
              CefV8ValueList args;
              args.push_back(CefV8Value::CreateFunction("reportAuthEvent", handler));
              subInstaller->ExecuteFunction(nullptr, args);
            }
            context->Exit();
          }
        }
      }
      return;
    }

    // Ignore isolated V8 worlds (e.g. MV3 extension content scripts injected by Bitwarden,
    // Google Translate, etc.) so they NEVER overwrite main-world `frame_hooks_` or hijack
    // `sx.cws_state` / `sx.scroll_phase` IPC!
    CefRefPtr<CefV8Context> mainCtx = frame->GetV8Context();
    if (mainCtx && !mainCtx->IsSame(context)) {
      return;
    }

    // Extension popup context: bridge chrome.tabs.query/get/reload/create to the
    // real active SXBrowserTab AND report exact DOM content dimensions for popover sizing.
    auto pit = popup_contexts_.find(browser->GetIdentifier());
    if (pit != popup_contexts_.end()) {
      if (context->Enter()) {
        CefRefPtr<CefV8Value> popupInstaller;
        CefRefPtr<CefV8Exception> pEx;
        const char* kPopupBridgeJS = R"JS(
          (function(activeUrl, activeTitle, activeTabId, activeLoading, isPopout, hostWinLeft, hostWinTop, hostWinWidth, hostWinHeight, reportSize, doReload, doCreate, doCreateWindow, doCloseWindow) {
            const tabObj = {
              id: activeTabId > 0 ? activeTabId : 1,
              index: 0,
              windowId: 1,
              active: true,
              highlighted: true,
              selected: true,
              pinned: false,
              incognito: false,
              status: activeLoading ? 'loading' : 'complete',
              url: activeUrl || 'about:blank',
              pendingUrl: activeUrl || 'about:blank',
              title: activeTitle || '',
              width: hostWinWidth || 1200,
              height: hostWinHeight || 748
            };
            const hostWinObj = {
              id: isPopout ? 2 : 1,
              focused: true,
              top: Number.isFinite(hostWinTop) ? hostWinTop : 80,
              left: Number.isFinite(hostWinLeft) ? hostWinLeft : 120,
              width: hostWinWidth > 200 ? hostWinWidth : 1200,
              height: hostWinHeight > 200 ? hostWinHeight : 800,
              incognito: false,
              type: isPopout ? 'popup' : 'normal',
              state: 'normal',
              alwaysOnTop: false,
              tabs: [Object.assign({}, tabObj)]
            };

            // Route window.close() cleanly to close our native popup panel or popout window
            try {
              const origWinClose = typeof window.close === 'function' ? window.close.bind(window) : null;
              window.close = function() {
                try { doCloseWindow(); } catch (_) {}
                if (origWinClose) { try { origWinClose(); } catch (_) {} }
              };
            } catch (_) {}

            function patchExtensionAPIs(ns) {
              if (!ns) return;
              if (ns.__sxPatched) return;
              if (!ns.tabs) ns.tabs = {};
              const rawTabs = ns.tabs;
              const origQuery = typeof rawTabs.query === 'function' ? rawTabs.query.bind(rawTabs) : null;
              const origGet = typeof rawTabs.get === 'function' ? rawTabs.get.bind(rawTabs) : null;

              const normUrl = (u) => String(u || '').replace(/\/+$/, '');
              const targetNorm = normUrl(activeUrl);

              const resolveActiveTab = () => {
                const synth = Object.assign({}, tabObj);
                if (origQuery) {
                  try {
                    const p = origQuery({});
                    if (p && typeof p.then === 'function') {
                      return p.then(allTabs => {
                        if (Array.isArray(allTabs)) {
                          const exact = allTabs.find(t => t && normUrl(t.url) === targetNorm);
                          const match = exact || allTabs.find(t => t && /^https?:\/\//i.test(t.url || ''));
                          if (match) {
                            return Object.assign({}, match, {
                              url: activeUrl || match.url,
                              title: activeTitle || match.title || '',
                              active: true,
                              highlighted: true,
                              selected: true
                            });
                          }
                        }
                        return synth;
                      }).catch(() => synth);
                    }
                  } catch (_) {}
                }
                return Promise.resolve(synth);
              };

              const wrappedQuery = function(queryInfo, cb) {
                const q = queryInfo || {};
                const wantsActive = !queryInfo || q.active === true || q.currentWindow === true || q.lastFocusedWindow === true;
                if (wantsActive && activeUrl && /^https?:\/\//i.test(activeUrl)) {
                  const p = resolveActiveTab().then(t => [t]);
                  if (typeof cb === 'function') {
                    p.then(res => cb(res));
                    return;
                  }
                  return p;
                }
                if (origQuery) return origQuery(queryInfo, cb);
                const fallback = [Object.assign({}, tabObj)];
                if (typeof cb === 'function') {
                  Promise.resolve().then(() => cb(fallback));
                  return;
                }
                return Promise.resolve(fallback);
              };

              const wrappedGet = function(id, cb) {
                if (id === tabObj.id && activeUrl && /^https?:\/\//i.test(activeUrl)) {
                  const p = resolveActiveTab();
                  if (typeof cb === 'function') {
                    p.then(res => cb(res));
                    return;
                  }
                  return p;
                }
                if (origGet) return origGet(id, cb);
                return Promise.resolve(Object.assign({}, tabObj));
              };

              const wrappedReload = function(id, props, cb) {
                doReload();
                const fn = typeof id === 'function' ? id : (typeof props === 'function' ? props : cb);
                if (typeof fn === 'function') {
                  Promise.resolve().then(() => fn());
                  return;
                }
                return Promise.resolve();
              };

              const wrappedCreate = function(props, cb) {
                let targetUrl = (props && props.url) ? String(props.url) : '';
                if (targetUrl && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(targetUrl)) {
                  try {
                    if (ns.runtime && typeof ns.runtime.getURL === 'function') {
                      targetUrl = ns.runtime.getURL(targetUrl.replace(/^\/+/, ''));
                    }
                  } catch (_) {}
                }
                if (targetUrl) doCreate(targetUrl);
                const created = Object.assign({}, tabObj, { id: tabObj.id + 100, url: targetUrl });
                if (typeof cb === 'function') {
                  Promise.resolve().then(() => cb(created));
                  return;
                }
                return Promise.resolve(created);
              };

              try {
                Object.defineProperty(rawTabs, 'query', { value: wrappedQuery, configurable: true, writable: true });
                Object.defineProperty(rawTabs, 'get', { value: wrappedGet, configurable: true, writable: true });
                Object.defineProperty(rawTabs, 'reload', { value: wrappedReload, configurable: true, writable: true });
                Object.defineProperty(rawTabs, 'create', { value: wrappedCreate, configurable: true, writable: true });
              } catch (_) {
                try {
                  rawTabs.query = wrappedQuery;
                  rawTabs.get = wrappedGet;
                  rawTabs.reload = wrappedReload;
                  rawTabs.create = wrappedCreate;
                } catch (_2) {}
              }
              if (rawTabs.query !== wrappedQuery || rawTabs.create !== wrappedCreate) {
                const tabsProxy = new Proxy(rawTabs, {
                  get(target, prop) {
                    if (prop === 'query') return wrappedQuery;
                    if (prop === 'get') return wrappedGet;
                    if (prop === 'reload') return wrappedReload;
                    if (prop === 'create') return wrappedCreate;
                    const v = Reflect.get(target, prop, target);
                    return typeof v === 'function' ? v.bind(target) : v;
                  }
                });
                try {
                  Object.defineProperty(ns, 'tabs', { value: tabsProxy, configurable: true, writable: true });
                } catch (_) {}
              }

              // Polyfill & intercept chrome.windows.* so Bitwarden "Pop out to a new window"
              // and extension popout flows work seamlessly inside Safarium's native windows.
              if (!ns.windows) {
                try { ns.windows = {}; } catch (_) {}
              }
              if (ns.windows) {
                const rawWin = ns.windows;
                const makeWinCopy = (overrideId, overrideType) => Object.assign({}, hostWinObj, {
                  id: typeof overrideId === 'number' ? overrideId : hostWinObj.id,
                  type: overrideType || hostWinObj.type,
                  tabs: [Object.assign({}, tabObj)]
                });
                const respond = (val, cb) => {
                  if (typeof cb === 'function') {
                    Promise.resolve().then(() => cb(val));
                    return;
                  }
                  return Promise.resolve(val);
                };

                const wrappedWinGetCurrent = function(getInfo, cb) {
                  const fn = typeof getInfo === 'function' ? getInfo : cb;
                  return respond(makeWinCopy(), fn);
                };
                const wrappedWinGetLastFocused = function(getInfo, cb) {
                  const fn = typeof getInfo === 'function' ? getInfo : cb;
                  return respond(makeWinCopy(1, 'normal'), fn);
                };
                const wrappedWinGet = function(windowId, getInfo, cb) {
                  const fn = typeof getInfo === 'function' ? getInfo : cb;
                  return respond(makeWinCopy(typeof windowId === 'number' ? windowId : hostWinObj.id), fn);
                };
                const wrappedWinGetAll = function(getInfo, cb) {
                  const fn = typeof getInfo === 'function' ? getInfo : cb;
                  const info = (getInfo && typeof getInfo === 'object') ? getInfo : {};
                  const types = Array.isArray(info.windowTypes) ? info.windowTypes : null;
                  const cur = makeWinCopy();
                  const list = (!types || types.includes(cur.type)) ? [cur] : [];
                  return respond(list, fn);
                };
                const wrappedWinUpdate = function(windowId, updateInfo, cb) {
                  const fn = typeof updateInfo === 'function' ? updateInfo : cb;
                  return respond(makeWinCopy(typeof windowId === 'number' ? windowId : hostWinObj.id), fn);
                };
                const wrappedWinRemove = function(windowId, cb) {
                  try { doCloseWindow(); } catch (_) {}
                  return respond(undefined, cb);
                };
                const wrappedWinCreate = function(createData, cb) {
                  const data = (createData && typeof createData === 'object') ? createData : {};
                  let targetUrl = '';
                  if (data.url) {
                    targetUrl = Array.isArray(data.url) ? String(data.url[0] || '') : String(data.url);
                  }
                  if (targetUrl && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(targetUrl)) {
                    try {
                      if (ns.runtime && typeof ns.runtime.getURL === 'function') {
                        targetUrl = ns.runtime.getURL(targetUrl.replace(/^\/+/, ''));
                      }
                    } catch (_) {}
                  }
                  const winType = data.type ? String(data.type) : 'normal';
                  const reqW = Number.isFinite(Number(data.width)) ? Number(data.width) : 380;
                  const reqH = Number.isFinite(Number(data.height)) ? Number(data.height) : 630;
                  const reqL = Number.isFinite(Number(data.left)) ? Number(data.left) : -1;
                  const reqT = Number.isFinite(Number(data.top)) ? Number(data.top) : -1;
                  const wantsPopoutWin =
                    winType === 'popup' ||
                    winType === 'panel' ||
                    targetUrl.indexOf('uilocation=popout') !== -1;

                  if (targetUrl) {
                    if (wantsPopoutWin) {
                      doCreateWindow(targetUrl, reqW, reqH, reqL, reqT);
                    } else {
                      doCreate(targetUrl);
                    }
                  }
                  const createdWin = {
                    id: Math.floor(Math.random() * 10000) + 100,
                    focused: true,
                    top: reqT >= 0 ? reqT : hostWinObj.top + 60,
                    left: reqL >= 0 ? reqL : hostWinObj.left + Math.max(0, hostWinObj.width - reqW - 20),
                    width: reqW,
                    height: reqH,
                    incognito: false,
                    state: 'normal',
                    type: winType,
                    alwaysOnTop: false,
                    tabs: [Object.assign({}, tabObj, { id: tabObj.id + 100, url: targetUrl })]
                  };
                  return respond(createdWin, cb);
                };

                const winOverrides = {
                  create: wrappedWinCreate,
                  getCurrent: wrappedWinGetCurrent,
                  getLastFocused: wrappedWinGetLastFocused,
                  get: wrappedWinGet,
                  getAll: wrappedWinGetAll,
                  update: wrappedWinUpdate,
                  remove: wrappedWinRemove
                };
                let allDefined = true;
                for (const [k, fn] of Object.entries(winOverrides)) {
                  try {
                    Object.defineProperty(rawWin, k, { value: fn, configurable: true, writable: true });
                  } catch (_) {
                    try { rawWin[k] = fn; } catch (_2) {}
                  }
                  if (rawWin[k] !== fn) allDefined = false;
                }
                if (!allDefined) {
                  const winProxy = new Proxy(rawWin, {
                    get(target, prop) {
                      if (Object.prototype.hasOwnProperty.call(winOverrides, prop)) {
                        return winOverrides[prop];
                      }
                      const v = Reflect.get(target, prop, target);
                      return typeof v === 'function' ? v.bind(target) : v;
                    }
                  });
                  try {
                    Object.defineProperty(ns, 'windows', { value: winProxy, configurable: true, writable: true });
                  } catch (_) {}
                }
              }

              // Intercept chrome.runtime.openOptionsPage() so clicking extension settings/gear
              // opens dashboard/options in a native Safarium tab (NEVER a raw Chrome window).
              if (ns.runtime) {
                const rawRuntime = ns.runtime;
                const wrappedOpenOptions = function(cb) {
                  let page = '';
                  try {
                    const m = typeof rawRuntime.getManifest === 'function' ? rawRuntime.getManifest() : null;
                    if (m) {
                      page = (m.options_ui && m.options_ui.page) || m.options_page || '';
                    }
                  } catch (_) {}
                  if (page && typeof rawRuntime.getURL === 'function') {
                    const optUrl = rawRuntime.getURL(page.replace(/^\/+/, ''));
                    if (optUrl) doCreate(optUrl);
                  }
                  if (typeof cb === 'function') {
                    Promise.resolve().then(() => cb());
                    return;
                  }
                  return Promise.resolve();
                };
                try {
                  Object.defineProperty(rawRuntime, 'openOptionsPage', {
                    value: wrappedOpenOptions, configurable: true, writable: true
                  });
                } catch (_) {
                  try { rawRuntime.openOptionsPage = wrappedOpenOptions; } catch (_2) {}
                }
                if (rawRuntime.openOptionsPage !== wrappedOpenOptions) {
                  const runtimeProxy = new Proxy(rawRuntime, {
                    get(target, prop) {
                      if (prop === 'openOptionsPage') return wrappedOpenOptions;
                      const v = Reflect.get(target, prop, target);
                      return typeof v === 'function' ? v.bind(target) : v;
                    }
                  });
                  try {
                    Object.defineProperty(ns, 'runtime', { value: runtimeProxy, configurable: true, writable: true });
                  } catch (_) {}
                }
              }

              try { ns.__sxPatched = true; } catch (_) {}
            }

            function tryPatchAll() {
              let patched = false;
              if (typeof chrome !== 'undefined') { patchExtensionAPIs(chrome); patched = true; }
              if (typeof browser !== 'undefined') { patchExtensionAPIs(browser); patched = true; }
              return patched;
            }
            // In CEF + Chromium 156, OnContextCreated runs just before Chromium's
            // ExtensionsRendererClient::DidCreateScriptContext installs window.chrome/window.browser.
            // Hook immediately + microtask + early document MutationObserver so both namespaces are
            // patched BEFORE any <script> or <script type="module"> in popup.html executes!
            if (!tryPatchAll()) {
              if (typeof queueMicrotask === 'function') {
                queueMicrotask(() => { tryPatchAll(); });
              }
              if (typeof MutationObserver !== 'undefined') {
                const earlyMo = new MutationObserver(() => {
                  if (tryPatchAll()) {
                    earlyMo.disconnect();
                  }
                });
                earlyMo.observe(document, { childList: true, subtree: true });
              }
              document.addEventListener('readystatechange', tryPatchAll, { passive: true });
            }

            // Dynamic popup content sizing -> SXExtensionPopupPreferredSizeDidChangeNotification
            let lastW = 0, lastH = 0, prevW = 0, prevH = 0;
            let raf = 0, debounceTimer = 0, resizeCount = 0;
            let observersAttached = false;
            let lastReportTs = 0;
            const MAX_RESIZES = 10;

            function measureAndReport() {
              raf = 0;
              if (isPopout || resizeCount >= MAX_RESIZES) return;
              const docEl = document.documentElement;
              const body = document.body;
              if (!docEl || !body) return;

              // Wait until real UI content has mounted (avoid collapsing Angular/React
              // loading spinners like Bitwarden's `#loading` into a narrow column).
              const hasRealContent =
                ((body.innerText || '').trim().length > 0) ||
                !!document.querySelector('input, button, textarea, select, form, main');
              if (!hasRealContent) return;

              const bStyle = getComputedStyle(body);
              const dStyle = getComputedStyle(docEl);
              const minW = Math.max(
                parseFloat(bStyle.minWidth) || 0,
                parseFloat(dStyle.minWidth) || 0
              );
              let maxRight = 0;
              let maxBottom = 0;
              const inspectEl = (el) => {
                const cs = getComputedStyle(el);
                if (cs.display === 'none' || cs.visibility === 'hidden') return;
                if (cs.position === 'fixed' || cs.position === 'absolute') return;
                const r = el.getBoundingClientRect();
                if (r.height > 0 && r.bottom > maxBottom) maxBottom = r.bottom;
                if (r.width > 0 && r.right > maxRight && r.right <= 600) maxRight = r.right;
                // Custom root elements (e.g. Angular <app-root>) may be display:inline with a
                // sized inner block container (e.g. Bitwarden `.tw-w-[380px]`).
                if ((cs.display === 'inline' || r.width < 40) && el.children && el.children.length > 0) {
                  for (const sub of el.children) {
                    const scs = getComputedStyle(sub);
                    if (scs.display === 'none' || scs.visibility === 'hidden') continue;
                    const sr = sub.getBoundingClientRect();
                    if (sr.height > 0 && sr.bottom > maxBottom) maxBottom = sr.bottom;
                    if (sr.width > 0 && sr.right > maxRight && sr.right <= 600) maxRight = sr.right;
                  }
                }
              };
              for (const child of body.children) {
                inspectEl(child);
              }
              const padRight = parseFloat(bStyle.paddingRight) || 0;
              const padBottom = parseFloat(bStyle.paddingBottom) || 0;
              const minH = Math.max(parseFloat(bStyle.minHeight) || 0, parseFloat(dStyle.minHeight) || 0);
              let w = 0;
              if (body.scrollWidth > window.innerWidth + 2) {
                w = body.scrollWidth;
              } else if (minW >= 200 && minW <= window.innerWidth && body.scrollWidth <= minW + 2) {
                w = minW;
              } else {
                w = Math.max(minW, maxRight > 0 ? (maxRight + padRight) : 0, body.scrollWidth || 0);
              }
              if (w < 40) w = body.scrollWidth || docEl.scrollWidth || 380;
              let h = Math.max(
                minH,
                maxBottom > 40 ? Math.ceil(maxBottom + padBottom) : Math.ceil(Math.max(body.scrollHeight, docEl.scrollHeight))
              );
              if (h < 600 && (dStyle.overflowY === 'hidden' || bStyle.overflowY === 'hidden')) {
                let extraScroll = 0;
                const scrollers = body.querySelectorAll('main, section, div');
                for (let i = 0; i < scrollers.length && i < 60; i++) {
                  const s = scrollers[i];
                  if (s.clientHeight > 80 && s.scrollHeight > s.clientHeight + 6) {
                    const diff = s.scrollHeight - s.clientHeight;
                    if (diff > extraScroll) extraScroll = diff;
                  }
                }
                if (extraScroll > 0) h = Math.min(600, Math.max(h, lastH, h + extraScroll));
              }
              w = Math.max(240, Math.min(600, Math.ceil(w)));
              h = Math.max(120, Math.min(600, Math.ceil(h)));

              // Prevent A <-> B size oscillation loops
              if (Math.abs(w - prevW) <= 4 && Math.abs(h - prevH) <= 4 && resizeCount >= 2) {
                return;
              }
              if (Math.abs(w - lastW) < 4 && Math.abs(h - lastH) < 4) {
                return;
              }
              const now = performance.now();
              if (lastReportTs > 0 && (now - lastReportTs) < 120) {
                if (!debounceTimer) {
                  debounceTimer = setTimeout(() => {
                    debounceTimer = 0;
                    measureAndReport();
                  }, 140);
                }
                return;
              }

              prevW = lastW;
              prevH = lastH;
              lastW = w;
              lastH = h;
              lastReportTs = now;
              resizeCount++;
              reportSize(w, h);
            }
            function scheduleMeasure() {
              if (resizeCount >= MAX_RESIZES || raf || debounceTimer) return;
              debounceTimer = setTimeout(() => {
                debounceTimer = 0;
                if (!raf) raf = requestAnimationFrame(measureAndReport);
              }, 80);
            }
            function attachObservers() {
              tryPatchAll();
              if (observersAttached) return;
              observersAttached = true;
              scheduleMeasure();
              setTimeout(measureAndReport, 120);
              setTimeout(measureAndReport, 350);
              setTimeout(measureAndReport, 750);
              if (typeof MutationObserver !== 'undefined' && document.body) {
                const mo = new MutationObserver(scheduleMeasure);
                mo.observe(document.body, { childList: true, subtree: true });
              }
            }
            if (document.readyState === 'loading') {
              document.addEventListener('DOMContentLoaded', attachObservers, { once: true, passive: true });
            } else {
              attachObservers();
            }
            window.addEventListener('load', () => {
              tryPatchAll();
              scheduleMeasure();
            }, { once: true, passive: true });
          })
        )JS";

        if (context->Eval(kPopupBridgeJS, CefString(), 0, popupInstaller, pEx) &&
            popupInstaller && popupInstaller->IsFunction()) {
          CefRefPtr<CefV8Handler> handler = new SXTelemetryV8Handler(browser, frame);
          CefV8ValueList args;
          args.push_back(CefV8Value::CreateString(pit->second.activeUrl));
          args.push_back(CefV8Value::CreateString(pit->second.activeTitle));
          args.push_back(CefV8Value::CreateInt(pit->second.activeTabId));
          args.push_back(CefV8Value::CreateBool(pit->second.activeLoading));
          args.push_back(CefV8Value::CreateBool(pit->second.isPopout));
          args.push_back(CefV8Value::CreateInt(pit->second.hostWinLeft));
          args.push_back(CefV8Value::CreateInt(pit->second.hostWinTop));
          args.push_back(CefV8Value::CreateInt(pit->second.hostWinWidth));
          args.push_back(CefV8Value::CreateInt(pit->second.hostWinHeight));
          args.push_back(CefV8Value::CreateFunction("extPopupSize", handler));
          args.push_back(CefV8Value::CreateFunction("extTabReload", handler));
          args.push_back(CefV8Value::CreateFunction("extTabCreate", handler));
          args.push_back(CefV8Value::CreateFunction("extWindowCreate", handler));
          args.push_back(CefV8Value::CreateFunction("extWindowClose", handler));
          popupInstaller->ExecuteFunction(nullptr, args);
        }
        context->Exit();
      }
      return;
    }

    // Extension pages opened in regular Safarium tabs (e.g. options.html, dashboard.html, settings):
    // bridge chrome.tabs.create / chrome.windows.* / chrome.runtime.openOptionsPage so calls like
    // `browser.tabs.create({ url })` open a native Safarium tab instead of throwing "No current window".
    const std::string frameURL = frame->GetURL().ToString();
    if (frameURL.rfind("chrome-extension://", 0) == 0) {
      if (context->Enter()) {
        CefRefPtr<CefV8Value> extTabInstaller;
        CefRefPtr<CefV8Exception> extTabEx;
        const char* kExtTabBridgeJS = R"JS(
          (function(currentUrl, currentTabId, doReload, doCreate, doCreateWindow) {
            const selfTabObj = () => ({
              id: currentTabId > 0 ? currentTabId : 1,
              index: 0,
              windowId: 1,
              active: true,
              highlighted: true,
              selected: true,
              pinned: false,
              incognito: false,
              status: 'complete',
              url: window.location.href || currentUrl || 'about:blank',
              pendingUrl: window.location.href || currentUrl || 'about:blank',
              title: document.title || '',
              width: window.innerWidth || 1200,
              height: window.innerHeight || 800
            });
            const makeWinObj = (overrideId, overrideType) => ({
              id: typeof overrideId === 'number' ? overrideId : 1,
              focused: true,
              top: 80,
              left: 120,
              width: window.outerWidth > 200 ? window.outerWidth : 1200,
              height: window.outerHeight > 200 ? window.outerHeight : 800,
              incognito: false,
              type: overrideType || 'normal',
              state: 'normal',
              alwaysOnTop: false,
              tabs: [selfTabObj()]
            });
            const respond = (val, cb) => {
              if (typeof cb === 'function') {
                Promise.resolve().then(() => cb(val));
                return;
              }
              return Promise.resolve(val);
            };
            const resolveExtUrl = (ns, raw) => {
              let u = raw ? String(raw) : '';
              if (u && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(u)) {
                try {
                  if (ns.runtime && typeof ns.runtime.getURL === 'function') {
                    u = ns.runtime.getURL(u.replace(/^\/+/, ''));
                  }
                } catch (_) {}
              }
              return u;
            };

            function patchExtTabAPIs(ns) {
              if (!ns || ns.__sxTabPatched) return;
              if (!ns.tabs) { try { ns.tabs = {}; } catch (_) {} }
              if (ns.tabs) {
                const rawTabs = ns.tabs;
                const origQuery = typeof rawTabs.query === 'function' ? rawTabs.query.bind(rawTabs) : null;
                const origGetCurrent = typeof rawTabs.getCurrent === 'function' ? rawTabs.getCurrent.bind(rawTabs) : null;
                const wrappedCreate = function(props, cb) {
                  const targetUrl = resolveExtUrl(ns, props && props.url);
                  if (targetUrl) doCreate(targetUrl);
                  const created = Object.assign(selfTabObj(), {
                    id: Math.floor(Math.random() * 100000) + 1000,
                    url: targetUrl || 'about:blank',
                    pendingUrl: targetUrl || 'about:blank'
                  });
                  return respond(created, cb);
                };
                const wrappedReload = function(id, props, cb) {
                  doReload();
                  const fn = typeof id === 'function' ? id : (typeof props === 'function' ? props : cb);
                  return respond(undefined, fn);
                };
                const wrappedGetCurrent = function(cb) {
                  if (origGetCurrent) {
                    try {
                      const p = new Promise((resolve) => {
                        try {
                          origGetCurrent((t) => {
                            if ((ns.runtime && ns.runtime.lastError) || !t) return resolve(selfTabObj());
                            resolve(t);
                          });
                        } catch (_) { resolve(selfTabObj()); }
                      });
                      if (typeof cb === 'function') { p.then(cb); return; }
                      return p;
                    } catch (_) {}
                  }
                  return respond(selfTabObj(), cb);
                };
                const wrappedQuery = function(queryInfo, cb) {
                  const q = (queryInfo && typeof queryInfo === 'object') ? queryInfo : {};
                  if (!origQuery) return respond([selfTabObj()], cb);
                  const p = new Promise((resolve) => {
                    try {
                      origQuery(q, (tabs) => {
                        if (ns.runtime && ns.runtime.lastError) {
                          return resolve([selfTabObj()]);
                        }
                        if (Array.isArray(tabs) && tabs.length > 0) {
                          return resolve(tabs);
                        }
                        if (q.active === true || q.currentWindow === true || q.lastFocusedWindow === true || Object.keys(q).length === 0) {
                          return resolve([selfTabObj()]);
                        }
                        resolve([]);
                      });
                    } catch (_) { resolve([selfTabObj()]); }
                  });
                  if (typeof cb === 'function') { p.then(cb); return; }
                  return p;
                };
                const tabOverrides = {
                  create: wrappedCreate,
                  reload: wrappedReload,
                  getCurrent: wrappedGetCurrent,
                  query: wrappedQuery
                };
                let tabsOk = true;
                for (const [k, fn] of Object.entries(tabOverrides)) {
                  try { Object.defineProperty(rawTabs, k, { value: fn, configurable: true, writable: true }); }
                  catch (_) { try { rawTabs[k] = fn; } catch (_2) {} }
                  if (rawTabs[k] !== fn) tabsOk = false;
                }
                if (!tabsOk) {
                  const tabsProxy = new Proxy(rawTabs, {
                    get(target, prop) {
                      if (Object.prototype.hasOwnProperty.call(tabOverrides, prop)) return tabOverrides[prop];
                      const v = Reflect.get(target, prop, target);
                      return typeof v === 'function' ? v.bind(target) : v;
                    }
                  });
                  try { Object.defineProperty(ns, 'tabs', { value: tabsProxy, configurable: true, writable: true }); } catch (_) {}
                }
              }

              if (!ns.windows) { try { ns.windows = {}; } catch (_) {} }
              if (ns.windows) {
                const rawWin = ns.windows;
                const winOverrides = {
                  getCurrent: (info, cb) => respond(makeWinObj(), typeof info === 'function' ? info : cb),
                  getLastFocused: (info, cb) => respond(makeWinObj(1, 'normal'), typeof info === 'function' ? info : cb),
                  get: (id, info, cb) => respond(makeWinObj(typeof id === 'number' ? id : 1), typeof info === 'function' ? info : cb),
                  getAll: (info, cb) => respond([makeWinObj()], typeof info === 'function' ? info : cb),
                  update: (id, info, cb) => respond(makeWinObj(typeof id === 'number' ? id : 1), typeof info === 'function' ? info : cb),
                  create: (data, cb) => {
                    const d = (data && typeof data === 'object') ? data : {};
                    const rawUrl = Array.isArray(d.url) ? d.url[0] : d.url;
                    const u = resolveExtUrl(ns, rawUrl);
                    if (u) doCreateWindow(u, Number(d.width) || 380, Number(d.height) || 630, -1, -1);
                    return respond(makeWinObj(Math.floor(Math.random() * 10000) + 100, d.type || 'normal'), cb);
                  }
                };
                let winOk = true;
                for (const [k, fn] of Object.entries(winOverrides)) {
                  try { Object.defineProperty(rawWin, k, { value: fn, configurable: true, writable: true }); }
                  catch (_) { try { rawWin[k] = fn; } catch (_2) {} }
                  if (rawWin[k] !== fn) winOk = false;
                }
                if (!winOk) {
                  const winProxy = new Proxy(rawWin, {
                    get(target, prop) {
                      if (Object.prototype.hasOwnProperty.call(winOverrides, prop)) return winOverrides[prop];
                      const v = Reflect.get(target, prop, target);
                      return typeof v === 'function' ? v.bind(target) : v;
                    }
                  });
                  try { Object.defineProperty(ns, 'windows', { value: winProxy, configurable: true, writable: true }); } catch (_) {}
                }
              }

              if (ns.runtime) {
                const rawRuntime = ns.runtime;
                const wrappedOpenOptions = function(cb) {
                  let page = '';
                  try {
                    const m = typeof rawRuntime.getManifest === 'function' ? rawRuntime.getManifest() : null;
                    if (m) page = (m.options_ui && m.options_ui.page) || m.options_page || '';
                  } catch (_) {}
                  const optUrl = resolveExtUrl(ns, page);
                  if (optUrl) doCreate(optUrl);
                  return respond(undefined, cb);
                };
                try { Object.defineProperty(rawRuntime, 'openOptionsPage', { value: wrappedOpenOptions, configurable: true, writable: true }); }
                catch (_) { try { rawRuntime.openOptionsPage = wrappedOpenOptions; } catch (_2) {} }
                if (rawRuntime.openOptionsPage !== wrappedOpenOptions) {
                  const rtProxy = new Proxy(rawRuntime, {
                    get(target, prop) {
                      if (prop === 'openOptionsPage') return wrappedOpenOptions;
                      const v = Reflect.get(target, prop, target);
                      return typeof v === 'function' ? v.bind(target) : v;
                    }
                  });
                  try { Object.defineProperty(ns, 'runtime', { value: rtProxy, configurable: true, writable: true }); } catch (_) {}
                }
              }

              try { ns.__sxTabPatched = true; } catch (_) {}
            }

            function tryPatchExtTab() {
              let ok = false;
              if (typeof chrome !== 'undefined') { patchExtTabAPIs(chrome); ok = true; }
              if (typeof browser !== 'undefined') { patchExtTabAPIs(browser); ok = true; }
              return ok;
            }
            if (!tryPatchExtTab()) {
              if (typeof queueMicrotask === 'function') queueMicrotask(tryPatchExtTab);
              if (typeof MutationObserver !== 'undefined') {
                const mo = new MutationObserver(() => {
                  if (tryPatchExtTab()) mo.disconnect();
                });
                mo.observe(document, { childList: true, subtree: true });
              }
              document.addEventListener('readystatechange', tryPatchExtTab, { passive: true });
            }
          })
        )JS";
        if (context->Eval(kExtTabBridgeJS, CefString(), 0, extTabInstaller, extTabEx) &&
            extTabInstaller && extTabInstaller->IsFunction()) {
          CefRefPtr<CefV8Handler> handler = new SXTelemetryV8Handler(browser, frame);
          CefV8ValueList args;
          args.push_back(CefV8Value::CreateString(frameURL));
          args.push_back(CefV8Value::CreateInt(browser->GetIdentifier()));
          args.push_back(CefV8Value::CreateFunction("extTabReload", handler));
          args.push_back(CefV8Value::CreateFunction("extTabCreate", handler));
          args.push_back(CefV8Value::CreateFunction("extWindowCreate", handler));
          extTabInstaller->ExecuteFunction(nullptr, args);
        }
        context->Exit();
      }
    }

    // Install lightweight read-only scroll & visualViewport telemetry (no JS overscroll;
    // all elastic scrolling, momentum overshoot, and pull-to-refresh run natively in AppKit at 120Hz).
    if (!context->Enter()) {
      return;
    }
    CefRefPtr<CefV8Value> installer;
    CefRefPtr<CefV8Exception> exception;
    const char* kInstallerJS = R"JS(
      (function(reportMetrics, _unusedOverscroll, _unusedPullRefresh, cwsAction, spaceScroll, reportFixedHeader, reportPageBg, reportNativeVideo, reportAuthEvent, mediaProxyPort, mediaProxyToken, reportNavReady, initialTopInset, reportNavTraverse) {
        const onScrollPhase = function() {};
        const settle = function() {};

        // Prevent Chromium's Blink compositor from running a second competing root rubber-band
        // underneath Safarium's native 120Hz AppKit elastic engine.
        function disableRootBlinkOverscroll() {
          try {
            const root = document.documentElement;
            if (root && !root.style.overscrollBehaviorY) {
              root.style.overscrollBehaviorY = 'none';
            }
          } catch (_) {}
        }
        disableRootBlinkOverscroll();
        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', disableRootBlinkOverscroll, { once: true, passive: true });
        }

        // Page under the toolbar (Safari's obscured top inset). Safarium's web view runs behind its translucent
        // toolbar, so the page gets a top inset of the toolbar's height: nothing is hidden at the top, and scrolled
        // content slides under the glass. The band above the page is painted in the colour of whatever sits right
        // below it (the glass blurs it). Fixed/sticky bars pinned near the top, and full-width app chrome placed
        // absolutely on the initial containing block (which ignores the inset), move down by the same amount.
        // The inset comes from native per tab (0 for sign-in popups); __sxSetTopInset(px) updates it.
        const sxTopInset = {
          px: Math.max(0, Math.round(Number(initialTopInset) || 0)),
          setFixedEdgeColor: null, onInsetChanged: null, fixedBars: new Set()
        };
        (function installUnderToolbarInset() {
          const MAX_SHIFTED_TOP = 160;          // bars pinned lower than this (dialogs, toasts) are left alone
          const PROBE_XS = [0.02, 0.2, 0.5, 0.8, 0.98];
          let sheet = null;
          let styleEl = null;
          let edgeColor = 'transparent';
          const shifted = new Map();            // element -> { base, inline, prio } (page's own top + inline top)
          let observer = null;

          function css() {
            const h = sxTopInset.px;
            if (h <= 0) return '';
            return '@media screen{html{border-top:' + h + 'px solid ' + edgeColor + ' !important;' +
                   'scroll-padding-top:' + h + 'px !important;box-sizing:border-box !important;}}';
          }
          // Both an adopted sheet (works before <html> exists) and a <style> under <html> (survives pages that
          // reassign document.adoptedStyleSheets).
          function writeSheet() {
            const text = css();
            try {
              if (!sheet) sheet = new CSSStyleSheet();
              sheet.replaceSync(text);
              const list = document.adoptedStyleSheets || [];
              if (list.indexOf(sheet) === -1) document.adoptedStyleSheets = list.concat([sheet]);
            } catch (_) {}
            try {
              const root = document.documentElement;
              if (root) {
                if (!styleEl) { styleEl = document.createElement('style'); styleEl.setAttribute('data-sx-inset', ''); }
                if (styleEl.textContent !== text) styleEl.textContent = text;
                if (styleEl.parentNode !== root) root.appendChild(styleEl);
              }
            } catch (_) {}
          }

          function pxTop(cs) {
            const t = cs.top;
            if (!t || !/px$/.test(t)) return null;
            const v = parseFloat(t);
            return isFinite(v) ? v : null;
          }

          // Our own writes must never animate (a page's `transition: all` would slide the bar down).
          function writeTop(el, value, prio) {
            const prevTransition = el.style.getPropertyValue('transition');
            const prevTransitionPrio = el.style.getPropertyPriority('transition');
            el.style.setProperty('transition', 'none', 'important');
            if (value) el.style.setProperty('top', value, prio || ''); else el.style.removeProperty('top');
            void el.offsetTop;
            if (prevTransition) el.style.setProperty('transition', prevTransition, prevTransitionPrio);
            else el.style.removeProperty('transition');
          }

          function onInitialContainingBlock(el) {
            for (let p = el.parentElement; p; p = p.parentElement) {
              const cs = window.getComputedStyle(p);
              if (cs.position !== 'static' || cs.transform !== 'none' || cs.filter !== 'none' ||
                  cs.contain === 'paint' || cs.contain === 'strict' || cs.contain === 'content') return false;
            }
            return true;
          }

          function qualifies(el, cs) {
            const pos = cs.position;
            if (pos !== 'fixed' && pos !== 'sticky' && pos !== 'absolute') return null;
            const top = pxTop(cs);
            if (top === null || top < -1 || top > MAX_SHIFTED_TOP) return null;
            const r = el.getBoundingClientRect();
            if (r.width < 1 || r.height < 1) return null;
            if (pos === 'absolute') {
              // Only full-width app chrome: tooltips/menus placed from getBoundingClientRect already include it.
              if (r.width < (window.innerWidth || 1) * 0.6 || !onInitialContainingBlock(el)) return null;
            }
            return top;
          }

          function shift(el) {
            if (shifted.has(el) || el === document.documentElement || el === document.body) return;
            let cs;
            try { cs = window.getComputedStyle(el); } catch (_) { return; }
            const top = qualifies(el, cs);
            if (top === null) return;
            const rec = { base: top, inline: el.style.getPropertyValue('top'), prio: el.style.getPropertyPriority('top') };
            shifted.set(el, rec);
            writeTop(el, (top + sxTopInset.px) + 'px', 'important');
          }

          function unshift(el) {
            const rec = shifted.get(el);
            if (!rec) return;
            shifted.delete(el);
            if (el.isConnected) writeTop(el, rec.inline, rec.prio);
          }

          // Re-read a shifted element from the page's own styles (its class/style changed).
          function refresh(el) {
            const rec = shifted.get(el);
            if (!rec) return;
            const ours = (rec.base + sxTopInset.px) + 'px';
            const cur = el.style.getPropertyValue('top');
            if (cur !== ours || el.style.getPropertyPriority('top') !== 'important') {
              rec.inline = cur;  // the page wrote its own inline top: keep it as the base
              rec.prio = el.style.getPropertyPriority('top');
            }
            unshift(el);
            shift(el);
          }

          function updateEdgeColor() {
            let c = null;
            try {
              const vw = window.innerWidth || 1;
              const stack = document.elementsFromPoint(vw * 0.5, sxTopInset.px + 2);
              for (let i = 0; i < stack.length && i < 12 && !c; i++) {
                const el = stack[i];
                if (!el || el === document.documentElement) continue;
                const bg = window.getComputedStyle(el).backgroundColor;
                const m = bg && bg.match(/rgba?\(([^)]+)\)/);
                if (!m) continue;
                const parts = m[1].split(/[\s,\/]+/).filter(Boolean);
                const a = parts.length > 3 ? parseFloat(parts[3]) : 1;
                if (a >= 0.85) c = bg;
              }
              if (!c) {
                for (const el of [document.body, document.documentElement]) {
                  const bg = el && window.getComputedStyle(el).backgroundColor;
                  if (bg && bg !== 'rgba(0, 0, 0, 0)' && bg !== 'transparent') { c = bg; break; }
                }
              }
            } catch (_) {}
            c = c || 'transparent';
            if (c !== edgeColor) { edgeColor = c; writeSheet(); }
          }

          function probe() {
            if (observer) observer.takeRecords();
            writeSheet();
            const h = sxTopInset.px;
            if (h <= 0 || !document.body || !document.elementsFromPoint) return;
            if (document.fullscreenElement || document.webkitFullscreenElement) return;
            for (const el of Array.from(shifted.keys())) {
              if (!el.isConnected) { shifted.delete(el); continue; }
              const pos = window.getComputedStyle(el).position;
              if (pos !== 'fixed' && pos !== 'sticky' && pos !== 'absolute') unshift(el);
            }
            const vw = window.innerWidth || 1;
            const vh = window.innerHeight || 1;
            const seen = new Set();
            const ys = [1, h * 0.5, h - 1, h + 24, h + 96, vh * 0.35, vh * 0.65, vh * 0.92];
            for (let xi = 0; xi < PROBE_XS.length; xi++) {
              const x = Math.min(vw - 1, Math.max(0, vw * PROBE_XS[xi]));
              for (let yi = 0; yi < ys.length; yi++) {
                let stack;
                try { stack = document.elementsFromPoint(x, ys[yi]); } catch (_) { continue; }
                for (let j = 0; j < stack.length && j < 16; j++) {
                  for (let n = stack[j], hop = 0; n && n !== document.body && n !== document.documentElement && hop < 10;
                       n = n.parentElement, hop++) {
                    if (seen.has(n)) continue;
                    seen.add(n);
                    shift(n);
                  }
                }
              }
            }
            if ((window.scrollY || 0) < h + 2) updateEdgeColor();
            if (observer) observer.takeRecords();  // drop records of our own writes
          }

          // Probe in a frame callback (before paint) so a bar never shows under the toolbar first; while the page
          // is loading every mutated frame is probed, afterwards at most every 120 ms.
          let queued = false;
          let lastProbe = 0;
          function schedule() {
            if (queued) return;
            queued = true;
            const settled = document.readyState === 'complete' && (performance.now() > 3000);
            const wait = settled ? Math.max(0, 120 - (performance.now() - lastProbe)) : 0;
            const run = function() {
              requestAnimationFrame(function() { queued = false; lastProbe = performance.now(); probe(); });
            };
            if (wait > 0) setTimeout(run, wait); else run();
          }

          window.__sxSetTopInset = function(px) {
            const v = Math.max(0, Math.round(Number(px) || 0));
            if (v === sxTopInset.px) return;
            sxTopInset.px = v;
            for (const el of Array.from(shifted.keys())) unshift(el);
            writeSheet();
            probe();
            if (typeof sxTopInset.onInsetChanged === 'function') sxTopInset.onInsetChanged();
          };

          writeSheet();
          try {
            observer = new MutationObserver(function(records) {
              let dirty = false;
              for (const rec of records) {
                if (rec.type === 'attributes') {
                  for (const el of Array.from(shifted.keys())) {
                    if (rec.target === el || (rec.attributeName === 'class' && rec.target.contains && rec.target.contains(el))) {
                      refresh(el);
                    }
                  }
                }
                dirty = true;
              }
              if (observer) observer.takeRecords();
              if (dirty) schedule();
            });
            observer.observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'style'] });
          } catch (_) {}
          window.addEventListener('scroll', schedule, { passive: true, capture: true });
          window.addEventListener('resize', schedule, { passive: true });
          window.addEventListener('load', schedule, { passive: true });
          window.addEventListener('pageshow', schedule, { passive: true });
          document.addEventListener('fullscreenchange', schedule, { passive: true });
        })();

        // Read-only detector: checks if the webpage has an opaque fixed/sticky bar docked at y=0
        // and reports its RGB color so Safarium can switch the toolbar gradient to that fixed bar color.
        (function installReadOnlyFixedHeaderDetector() {
          let lastKey = '';
          let lastPageBgKey = '';
          function notify(hasFixed, rgb) {
            const a = (rgb && rgb.length > 3) ? rgb[3] : 1;
            const key = hasFixed && rgb ? ('1:' + rgb[0] + ',' + rgb[1] + ',' + rgb[2] + ',' + a.toFixed(2)) : '0';
            if (key === lastKey) return;
            lastKey = key;
            if (typeof reportFixedHeader === 'function') {
              if (hasFixed && rgb) {
                reportFixedHeader(true, rgb[0] / 255, rgb[1] / 255, rgb[2] / 255, a);
              } else {
                reportFixedHeader(false, 0, 0, 0, 0);
              }
            }
          }

          let colorProbeCtx = null;
          function parseBgRGBA(bgStr) {
            if (!bgStr || bgStr === 'transparent' || bgStr === 'none') return null;
            const m = bgStr.match(/rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)(?:\s*,\s*([\d.]+))?\s*\)/i);
            if (m) {
              const a = m[4] !== undefined ? parseFloat(m[4]) : 1;
              if (a <= 0.05) return null;
              return [Math.round(parseFloat(m[1])), Math.round(parseFloat(m[2])), Math.round(parseFloat(m[3])), a];
            }
            const m2 = bgStr.match(/rgba?\(\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)(?:\s*\/\s*([\d.]+%?))?\s*\)/i);
            if (m2) {
              let a = 1;
              if (m2[4] !== undefined) {
                a = m2[4].endsWith('%') ? parseFloat(m2[4]) / 100 : parseFloat(m2[4]);
              }
              if (a <= 0.05) return null;
              return [Math.round(parseFloat(m2[1])), Math.round(parseFloat(m2[2])), Math.round(parseFloat(m2[3])), a];
            }
            // Universal fallback for CSS Color 4 (`color(srgb ...)`, `oklch(...)`, `lab(...)`, etc.)
            try {
              if (!colorProbeCtx) {
                const c = document.createElement('canvas');
                c.width = 1; c.height = 1;
                colorProbeCtx = c.getContext('2d', { willReadFrequently: true });
              }
              if (colorProbeCtx) {
                colorProbeCtx.clearRect(0, 0, 1, 1);
                colorProbeCtx.fillStyle = 'rgba(0,0,0,0)';
                colorProbeCtx.fillStyle = bgStr;
                colorProbeCtx.fillRect(0, 0, 1, 1);
                const d = colorProbeCtx.getImageData(0, 0, 1, 1).data;
                const a = d[3] / 255;
                if (a > 0.05) return [d[0], d[1], d[2], a];
              }
            } catch (_) {}
            return null;
          }

          function hasUnclippedVisualBox(cs) {
            if (!cs) return false;
            if (cs.display === 'none' || cs.visibility === 'hidden' || cs.visibility === 'collapse') return false;
            if (parseFloat(cs.opacity || '1') < 0.85) return false;
            if (cs.clipPath && cs.clipPath !== 'none') return false;
            if ((cs.maskImage && cs.maskImage !== 'none') || (cs.webkitMaskImage && cs.webkitMaskImage !== 'none')) return false;
            if (cs.clip && cs.clip !== 'auto') return false;
            if (cs.mixBlendMode && cs.mixBlendMode !== 'normal') return false;
            if (cs.filter && /opacity\s*\(\s*0(?:\.[0-7]\d*)?\s*\)/i.test(cs.filter)) return false;
            return true;
          }

          function isEffectivelyVisible(el, vw, barTop) {
            let cur = el;
            let hops = 0;
            while (cur && cur.nodeType === 1 && cur !== document.documentElement && hops < 16) {
              let cs;
              try { cs = window.getComputedStyle(cur); } catch (_) { return false; }
              if (!hasUnclippedVisualBox(cs)) return false;
              if (cur !== el) {
                if (cs.overflowY === 'hidden' || cs.overflowY === 'clip') {
                  const ar = cur.getBoundingClientRect();
                  if (ar.height < 24 || ar.bottom <= barTop + 24 || ar.top > barTop + 2) {
                    return false;
                  }
                }
                if (cs.overflowX === 'hidden' || cs.overflowX === 'clip') {
                  const ar = cur.getBoundingClientRect();
                  if (ar.left > 2 || ar.right < vw - 2) {
                    return false;
                  }
                }
              }
              cur = cur.parentElement || (cur.getRootNode && cur.getRootNode().host) || null;
              hops++;
            }
            return true;
          }

          function hasSquareTopCorners(cs) {
            if (!cs) return false;
            const tl = parseFloat(cs.borderTopLeftRadius || '0') || 0;
            const tr = parseFloat(cs.borderTopRightRadius || '0') || 0;
            return tl <= 1.5 && tr <= 1.5;
          }

          function hasFullEdgeBackgroundBox(cs) {
            if (!cs) return false;
            const clip = cs.backgroundClip || 'border-box';
            if (clip === 'text') return false;
            if (clip === 'content-box') {
              if ((parseFloat(cs.paddingTop || '0') || 0) > 1.5) return false;
              if ((parseFloat(cs.paddingLeft || '0') || 0) > 1.5) return false;
              if ((parseFloat(cs.paddingRight || '0') || 0) > 1.5) return false;
            } else if (clip === 'padding-box') {
              if ((parseFloat(cs.borderTopWidth || '0') || 0) > 1.5) return false;
              if ((parseFloat(cs.borderLeftWidth || '0') || 0) > 1.5) return false;
              if ((parseFloat(cs.borderRightWidth || '0') || 0) > 1.5) return false;
            }
            return true;
          }

          function isFlushFullWidthRect(rect, vw, vh, barTop) {
            if (!rect) return false;
            const maxBarH = Math.min(136, Math.max(64, vh * 0.25));
            return rect.left <= 1.5 &&
                   rect.right >= vw - 1.5 &&
                   rect.height >= 26 &&
                   rect.height <= maxBarH &&
                   rect.top <= barTop + 1.5 &&
                   rect.top >= barTop - 2.0 &&
                   rect.bottom >= barTop + 26;
          }

          function isActuallyStickyToViewportTop(node, rect, vw, vh, barTop) {
            let p = node.parentElement;
            let hops = 0;
            let foundInnerScroller = false;
            while (p && p.nodeType === 1 && p !== document.documentElement && hops < 16) {
              let pcs;
              try { pcs = window.getComputedStyle(p); } catch (_) { return false; }
              const oy = pcs ? (pcs.overflowY || 'visible') : 'visible';
              if (p !== document.body) {
                if (oy === 'hidden') {
                  // CSS spec: overflow:hidden ancestor breaks position:sticky completely.
                  return false;
                }
                if (oy === 'auto' || oy === 'scroll' || oy === 'overlay') {
                  const pr = p.getBoundingClientRect();
                  if (pr.left > 2 || pr.right < vw - 2 || pr.top > barTop + 2) return false;
                  if (pr.height < Math.max(rect.height + 120, vh * 0.5)) return false;
                  if (p.scrollHeight <= p.clientHeight + 4) return false;
                  foundInnerScroller = true;
                  break;
                }
              }
              p = p.parentElement;
              hops++;
            }
            if (!foundInnerScroller) {
              const parent = node.parentElement;
              if (parent && parent !== document.body && parent !== document.documentElement) {
                const pr = parent.getBoundingClientRect();
                if (pr.height < Math.max(rect.height + 120, vh * 0.5)) return false;
              }
              const se = document.scrollingElement || document.documentElement;
              if (se && se.scrollHeight <= se.clientHeight + 4 && (window.scrollY || 0) <= 0.5) {
                return false;
              }
            }
            return true;
          }

          function isFullWidthBackdropPseudo(ps, vw) {
            if (!ps || ps.content === 'none' || ps.content === 'normal') return false;
            if (!hasUnclippedVisualBox(ps) || !hasSquareTopCorners(ps)) return false;
            if (ps.position !== 'absolute' && ps.position !== 'fixed') return false;
            const pw = parseFloat(ps.width || '0') || 0;
            const ph = parseFloat(ps.height || '0') || 0;
            const pt = parseFloat(ps.top || '0');
            const pl = parseFloat(ps.left || '0');
            if (pw < vw - 4 || ph < 24) return false;
            if (!isNaN(pt) && pt > 2) return false;
            if (!isNaN(pl) && pl > 2) return false;
            return true;
          }

          function extractOpaqueColorDeep(el, vw, barTop, depth) {
            if (!el || depth > 5) return null;
            let cs;
            try { cs = window.getComputedStyle(el); } catch (_) { return null; }
            if (!hasUnclippedVisualBox(cs) || !hasSquareTopCorners(cs)) return null;
            const checkStyle = function(st) {
              if (!st || !hasFullEdgeBackgroundBox(st)) return null;
              if (st.backgroundImage && st.backgroundImage !== 'none') return null;
              const bf = (st.backdropFilter && st.backdropFilter !== 'none') ||
                         (st.webkitBackdropFilter && st.webkitBackdropFilter !== 'none');
              const rgba = parseBgRGBA(st.backgroundColor);
              if (rgba && (rgba[3] >= 0.90 || (bf && rgba[3] >= 0.85))) return rgba;
              return null;
            };
            const selfHit = checkStyle(cs);
            if (selfHit) return selfHit;
            try {
              const beforeSt = window.getComputedStyle(el, '::before');
              if (isFullWidthBackdropPseudo(beforeSt, vw)) {
                const beforeHit = checkStyle(beforeSt);
                if (beforeHit) return beforeHit;
              }
              const afterSt = window.getComputedStyle(el, '::after');
              if (isFullWidthBackdropPseudo(afterSt, vw)) {
                const afterHit = checkStyle(afterSt);
                if (afterHit) return afterHit;
              }
            } catch (_) {}
            const scanKids = function(list) {
              if (!list) return null;
              for (let i = 0; i < list.length && i < 16; i++) {
                const k = list[i];
                if (!k || k.nodeType !== 1) continue;
                let kcs;
                try { kcs = window.getComputedStyle(k); } catch (_) { kcs = null; }
                const isContents = kcs && kcs.display === 'contents';
                if (!isContents) {
                  const kr = k.getBoundingClientRect();
                  if (kr.left > 1.5 || kr.right < vw - 1.5 || kr.height < 24 || kr.top > barTop + 1.5 || kr.bottom < barTop + 26) continue;
                }
                const found = extractOpaqueColorDeep(k, vw, barTop, depth + 1);
                if (found) return found;
              }
              return null;
            };
            return scanKids(el.children) || (el.shadowRoot ? scanKids(el.shadowRoot.children) : null);
          }

          function isQualifyingFixedBar(node, vw, vh, barTop) {
            if (!node || node === document.body || node === document.documentElement) return null;
            const tag = node.tagName;
            if (tag === 'THEAD' || tag === 'TR' || tag === 'TH' || tag === 'TD') return null;
            const rect = node.getBoundingClientRect();
            if (!isFlushFullWidthRect(rect, vw, vh, barTop)) return null;
            let cs;
            try { cs = window.getComputedStyle(node); } catch (_) { return null; }
            if (!cs || (cs.position !== 'fixed' && cs.position !== 'sticky')) return null;
            if (cs.position === 'sticky') {
              if (!cs.top || cs.top === 'auto') return null;
              const stickyTop = parseFloat(cs.top);
              if (isNaN(stickyTop) || stickyTop > barTop + 1.5 || stickyTop < -2) return null;
              if (!isActuallyStickyToViewportTop(node, rect, vw, vh, barTop)) return null;
            }
            if (!isEffectivelyVisible(node, vw, barTop)) return null;
            return extractOpaqueColorDeep(node, vw, barTop, 0);
          }

          function colorDiffMax(a, b) {
            return Math.max(Math.abs(a[0] - b[0]), Math.abs(a[1] - b[1]), Math.abs(a[2] - b[2]));
          }

          function hasConflictingTopChildPaint(topEl, barNode, barRGB, vw, barTop) {
            let cur = topEl;
            let hops = 0;
            while (cur && cur !== barNode && cur !== document.body && cur !== document.documentElement && hops < 10) {
              const r = cur.getBoundingClientRect();
              if (r.top <= barTop + 4 && r.width >= vw * 0.14 && r.height >= 16) {
                const tag = cur.tagName;
                if (tag === 'IMG' || tag === 'VIDEO' || tag === 'CANVAS') return true;
                let cs;
                try { cs = window.getComputedStyle(cur); } catch (_) { cs = null; }
                if (cs) {
                  if (cs.backgroundImage && cs.backgroundImage !== 'none') return true;
                  const bg = parseBgRGBA(cs.backgroundColor);
                  if (bg && bg[3] >= 0.85 && colorDiffMax(bg, barRGB) > 18) return true;
                }
              }
              cur = cur.parentElement || (cur.getRootNode && cur.getRootNode().host) || null;
              hops++;
            }
            return false;
          }

          function probeFixedHeader() {
            try {
              if (!document.body || !document.elementsFromPoint) {
                notify(false, null);
                return;
              }
              if (document.fullscreenElement || document.webkitFullscreenElement) {
                notify(false, null);
                return;
              }
              // Pinch-zoomed: layout says the sticky bar is at the top, but on screen it is scaled/offset away
              // from the toolbar, so treating it as a docked header produced a hard unfeathered edge.
              if (window.visualViewport && (window.visualViewport.scale > 1.01 || window.visualViewport.offsetTop > 1)) {
                notify(false, null);
                return;
              }
              const vw = (document.documentElement && document.documentElement.clientWidth) || window.innerWidth || 1200;
              const vh = window.innerHeight || 800;
              const barTop = sxTopInset.px;
              const probeXs = [vw * 0.02, vw * 0.22, vw * 0.50, vw * 0.78, vw * 0.98];
              const probeYs = [barTop + 2, barTop + 14];
              let matchedRGB = null;

              const collectStack = function(root, x, y, depth, out) {
                if (!root || depth > 4 || !root.elementsFromPoint) return;
                let hits;
                try { hits = root.elementsFromPoint(x, y); } catch (_) { return; }
                for (let a = 0; a < hits.length && a < 20; a++) {
                  const el = hits[a];
                  out.push(el);
                  if (el && el.shadowRoot) {
                    collectStack(el.shadowRoot, x, y, depth + 1, out);
                  }
                }
              };

              // Probe a 5x2 grid across the top edge and verify:
              // 1. No opaque non-descendant surface (e.g. sidebar, drawer, modal, hero) occludes the bar.
              // 2. No wide child inside the bar overpaints the top edge with media, gradients, or a different color.
              // 3. Every probe point confirms a flush, full-width, opaque fixed/sticky bar with consistent RGB.
              const probeMatches = [];
              let failed = false;
              for (let yi = 0; yi < probeYs.length && !failed; yi++) {
                for (let xi = 0; xi < probeXs.length && !failed; xi++) {
                  const stack = [];
                  collectStack(document, probeXs[xi], probeYs[yi], 0, stack);
                  let hitRGB = null;
                  const seen = new Set();
                  for (let j = 0; j < stack.length && j < 40; j++) {
                    const topEl = stack[j];
                    if (!topEl || topEl === document.body || topEl === document.documentElement) continue;
                    let node = topEl;
                    let foundBar = null;
                    let foundRGB = null;
                    for (let hop = 0; hop < 12 && node && node !== document.body && node !== document.documentElement; hop++) {
                      if (!seen.has(node)) {
                        seen.add(node);
                        const rgba = isQualifyingFixedBar(node, vw, vh, barTop);
                        if (rgba) {
                          foundBar = node;
                          foundRGB = rgba;
                          break;
                        }
                      }
                      node = node.parentElement || (node.getRootNode && node.getRootNode().host) || null;
                    }
                    if (foundBar && foundRGB) {
                      if (hasConflictingTopChildPaint(topEl, foundBar, foundRGB, vw, barTop)) {
                        break;
                      }
                      hitRGB = foundRGB;
                      break;
                    }
                    // Front-to-back occlusion guard: any opaque non-bar surface (including sidebars/drawers)
                    // sitting in front of a deeper fixed bar means the fixed bar does NOT cover the top entirely.
                    const tr = topEl.getBoundingClientRect();
                    if (tr.width >= 24 && tr.height >= 12 && tr.top <= probeYs[yi] + 2) {
                      const tag = topEl.tagName;
                      if (tag === 'IMG' || tag === 'VIDEO' || tag === 'CANVAS') {
                        break;
                      }
                      let tcs;
                      try { tcs = window.getComputedStyle(topEl); } catch (_) { tcs = null; }
                      if (tcs) {
                        const tbg = parseBgRGBA(tcs.backgroundColor);
                        if ((tbg && tbg[3] >= 0.45) || (tcs.backgroundImage && tcs.backgroundImage !== 'none')) {
                          break;
                        }
                      }
                    }
                  }
                  if (!hitRGB) {
                    failed = true;
                    break;
                  }
                  probeMatches.push(hitRGB);
                }
              }

              if (!failed && probeMatches.length === probeXs.length * probeYs.length) {
                const ref = probeMatches[2];
                let consistent = true;
                for (let i = 0; i < probeMatches.length; i++) {
                  if (colorDiffMax(probeMatches[i], ref) > 10) {
                    consistent = false;
                    break;
                  }
                }
                if (consistent) {
                  matchedRGB = ref;
                }
              }

              let effectiveFixedRGB = matchedRGB;
              if (matchedRGB && matchedRGB.length > 3 && matchedRGB[3] < 0.99) {
                let baseBg = [255, 255, 255];
                for (const bgEl of [document.body, document.documentElement]) {
                  if (!bgEl) continue;
                  try {
                    const bgRGBA = parseBgRGBA(window.getComputedStyle(bgEl).backgroundColor);
                    if (bgRGBA && bgRGBA[3] >= 0.85) {
                      baseBg = [bgRGBA[0], bgRGBA[1], bgRGBA[2]];
                      break;
                    }
                  } catch (_) {}
                }
                const a = matchedRGB[3];
                effectiveFixedRGB = [
                  Math.round(matchedRGB[0] * a + baseBg[0] * (1 - a)),
                  Math.round(matchedRGB[1] * a + baseBg[1] * (1 - a)),
                  Math.round(matchedRGB[2] * a + baseBg[2] * (1 - a)),
                  1
                ];
              }
              notify(!!matchedRGB, matchedRGB);
              if (typeof sxTopInset.setFixedEdgeColor === 'function') {
                sxTopInset.setFixedEdgeColor(effectiveFixedRGB || null);
              }

              // Also report effective page top background color immediately so the toolbar
              // matches dark/colored pages even while streaming/loading before OnLoadEnd fires.
              if (!matchedRGB && typeof reportPageBg === 'function') {
                let bgRGB = null;
                const checkBg = function(el) {
                  if (!el) return null;
                  let cs;
                  try { cs = window.getComputedStyle(el); } catch (_) { return null; }
                  if (!cs) return null;
                  const rgba = parseBgRGBA(cs.backgroundColor);
                  return (rgba && rgba[3] >= 0.85) ? rgba : null;
                };
                if (document.elementsFromPoint) {
                  const topStack = document.elementsFromPoint(vw * 0.5, barTop + 4);
                  for (let k = 0; k < topStack.length && k < 12; k++) {
                    const el = topStack[k];
                    if (!el || el.tagName === 'IMG' || el.tagName === 'VIDEO' || el.tagName === 'SVG') continue;
                    const r = el.getBoundingClientRect();
                    if (r.width >= vw * 0.65 && r.top <= barTop + 4) {
                      bgRGB = checkBg(el);
                      if (bgRGB) break;
                    }
                  }
                }
                if (!bgRGB) bgRGB = checkBg(document.body) || checkBg(document.documentElement);
                if (bgRGB) {
                  const bgKey = bgRGB[0] + ',' + bgRGB[1] + ',' + bgRGB[2];
                  if (bgKey !== lastPageBgKey) {
                    lastPageBgKey = bgKey;
                    reportPageBg(bgRGB[0] / 255, bgRGB[1] / 255, bgRGB[2] / 255);
                  }
                }
              }
            } catch (_) {}
          }

          let rafPending = false;
          let scrollSettleTimer = 0;
          let mutDebounceTimer = 0;
          function scheduleProbe() {
            if (rafPending) return;
            rafPending = true;
            requestAnimationFrame(function() {
              rafPending = false;
              probeFixedHeader();
            });
          }
          function scheduleScrollProbe() {
            scheduleProbe();
            if (scrollSettleTimer) clearTimeout(scrollSettleTimer);
            // Catch CSS-transitioned auto-hiding headers after scroll settles.
            scrollSettleTimer = setTimeout(function() {
              scrollSettleTimer = 0;
              scheduleProbe();
            }, 340);
          }
          function scheduleMutationProbe() {
            if (mutDebounceTimer) return;
            mutDebounceTimer = setTimeout(function() {
              mutDebounceTimer = 0;
              scheduleProbe();
            }, 160);
          }

          sxTopInset.onInsetChanged = scheduleProbe;
          sxTopInset.probeNow = probeFixedHeader;
          // A page restored from the back/forward cache keeps this closure's dedupe state, but the toolbar has
          // shown other pages since: report its colours again.
          sxTopInset.forgetReported = function() { lastKey = ''; lastPageBgKey = ''; };
          window.addEventListener('load', scheduleProbe, { passive: true });
          window.addEventListener('pageshow', function() {
            // Always re-sync with browser on BFCache restore so stale fixedHeaderColor never persists.
            lastKey = '';
            scheduleProbe();
          }, { passive: true });
          window.addEventListener('scroll', scheduleScrollProbe, { passive: true });
          window.addEventListener('resize', scheduleProbe, { passive: true });
          window.addEventListener('popstate', scheduleProbe, { passive: true });
          window.addEventListener('hashchange', scheduleProbe, { passive: true });
          window.addEventListener('transitionend', scheduleMutationProbe, { passive: true });
          window.addEventListener('animationend', scheduleMutationProbe, { passive: true });
          if (window.visualViewport) {
            window.visualViewport.addEventListener('resize', scheduleProbe, { passive: true });
            window.visualViewport.addEventListener('scroll', scheduleProbe, { passive: true });
          }
          window.addEventListener('yt-navigate-finish', scheduleProbe, { passive: true });
          const attachHeaderObserver = function() {
            if (!document.body || typeof MutationObserver === 'undefined') return;
            try {
              const mo = new MutationObserver(scheduleMutationProbe);
              mo.observe(document.body, {
                childList: true,
                subtree: true,
                attributes: true,
                attributeFilter: ['class', 'style', 'hidden']
              });
            } catch (_) {}
          };
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', function() {
              attachHeaderObserver();
              scheduleProbe();
            }, { once: true, passive: true });
          } else {
            attachHeaderObserver();
          }
          setTimeout(scheduleProbe, 200);
          setTimeout(scheduleProbe, 800);
        })();

        // Native macOS Safari web form controls (zero-specificity `:where(...)` so site CSS always wins)
        // + Safari macOS 27 Liquid Glass floating HUD for standard HTML5 `<video controls>` elements.
        (function installNativeMacWebElements() {
          const proto = (window.location && window.location.protocol) || '';
          if (proto === 'devtools:' || proto === 'chrome:' || proto === 'chrome-extension:') return;

          const STYLE_ID = '__sx_native_mac_controls_style__';
          function injectNativeControlStyles() {
            try {
              const parent = document.head || document.documentElement;
              if (!parent || document.getElementById(STYLE_ID)) return;
              const style = document.createElement('style');
              style.id = STYLE_ID;
              style.textContent = `
                :where(html) {
                  accent-color: #007AFF;
                }
                @media (prefers-color-scheme: dark) {
                  :where(html) { accent-color: #0A84FF; }
                }

                /* Native macOS 27 Safari Borderless Soft-Gray Push Buttons (zero specificity so site CSS always wins) */
                :where(button, input[type="button"], input[type="reset"]) {
                  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                  font-size: 12px;
                  font-weight: 400;
                  line-height: 1.25;
                  color: rgba(0, 0, 0, 0.85);
                  background: rgba(0, 0, 0, 0.08);
                  border: 0;
                  border-radius: 5.5px;
                  padding: 2.5px 9px;
                  min-height: 20px;
                  box-shadow: none;
                  cursor: default;
                }
                :where(button, input[type="button"], input[type="reset"]):active:not(:disabled) {
                  background: rgba(0, 0, 0, 0.14);
                }
                :where(button, input[type="button"], input[type="reset"]):disabled {
                  background: rgba(0, 0, 0, 0.045);
                  color: rgba(0, 0, 0, 0.30);
                }
                :where(input[type="submit"], button[type="submit"]) {
                  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                  font-size: 12px;
                  font-weight: 500;
                  line-height: 1.25;
                  color: #FFFFFF;
                  background: #007AFF;
                  border: 0;
                  border-radius: 5.5px;
                  padding: 2.5px 10px;
                  min-height: 20px;
                  box-shadow: none;
                  cursor: default;
                }
                :where(input[type="submit"], button[type="submit"]):active:not(:disabled) {
                  background: #0066D6;
                }
                :where(input[type="submit"], button[type="submit"]):disabled {
                  background: rgba(0, 122, 255, 0.35);
                  color: rgba(255, 255, 255, 0.72);
                }
                :where(button:focus-visible, input[type="button"]:focus-visible, input[type="submit"]:focus-visible, input[type="reset"]:focus-visible) {
                  outline: 3px solid rgba(0, 122, 255, 0.45);
                  outline-offset: 0px;
                }

                /* Native macOS Checkboxes */
                :where(input[type="checkbox"]) {
                  -webkit-appearance: none;
                  appearance: none;
                  width: 14px;
                  height: 14px;
                  vertical-align: -2px;
                  border-radius: 3.5px;
                  border: 0.5px solid rgba(0, 0, 0, 0.28);
                  background: linear-gradient(180deg, #FFFFFF 0%, #F4F4F6 100%);
                  box-shadow: inset 0 0.5px 1px rgba(0, 0, 0, 0.08);
                  display: inline-grid;
                  place-content: center;
                  margin: 0 4px 0 0;
                  cursor: default;
                }
                :where(input[type="checkbox"]):checked {
                  border-color: #007AFF;
                  background: #007AFF url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 12'%3E%3Cpath d='M2.4 6.2l2.3 2.4 4.9-5.1' fill='none' stroke='%23ffffff' stroke-width='1.85' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") center/10px 10px no-repeat;
                  box-shadow: none;
                }
                :where(input[type="checkbox"]):indeterminate {
                  border-color: #007AFF;
                  background: #007AFF url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 12'%3E%3Cpath d='M2.8 6h6.4' stroke='%23ffffff' stroke-width='1.9' stroke-linecap='round'/%3E%3C/svg%3E") center/10px 10px no-repeat;
                }
                :where(input[type="checkbox"]:focus-visible) {
                  outline: 3px solid rgba(0, 122, 255, 0.45);
                  outline-offset: 0px;
                }

                /* Native macOS Radio Buttons */
                :where(input[type="radio"]) {
                  -webkit-appearance: none;
                  appearance: none;
                  width: 14px;
                  height: 14px;
                  vertical-align: -2px;
                  border-radius: 50%;
                  border: 0.5px solid rgba(0, 0, 0, 0.28);
                  background: linear-gradient(180deg, #FFFFFF 0%, #F4F4F6 100%);
                  box-shadow: inset 0 0.5px 1px rgba(0, 0, 0, 0.08);
                  margin: 0 4px 0 0;
                  cursor: default;
                }
                :where(input[type="radio"]):checked {
                  border: 4.5px solid #007AFF;
                  background: #FFFFFF;
                  box-shadow: none;
                }
                :where(input[type="radio"]:focus-visible) {
                  outline: 3px solid rgba(0, 122, 255, 0.45);
                  outline-offset: 0px;
                }

                /* Hide Chromium's default gray <video controls> bar; embedded Shadow DOM Liquid Glass controls render inside static DOM host */
                video[data-sx-vp="1"]::-webkit-media-controls,
                video[data-sx-vp="1"]::-webkit-media-controls-enclosure,
                video[data-sx-vp="1"]::-webkit-media-controls-panel {
                  display: none !important;
                  opacity: 0 !important;
                  pointer-events: none !important;
                }
                .sx-vp-host {
                  position: relative !important;
                  line-height: 0 !important;
                  overflow: hidden !important;
                  box-sizing: border-box !important;
                  vertical-align: top;
                  max-width: 100%;
                }
                .sx-vp-host > video[data-sx-vp="1"] {
                  display: block !important;
                  margin: 0 !important;
                  max-width: 100%;
                }
                .sx-vp-host:fullscreen,
                .sx-vp-host:-webkit-full-screen {
                  width: 100vw !important;
                  height: 100vh !important;
                  max-width: 100vw !important;
                  max-height: 100vh !important;
                  margin: 0 !important;
                  border-radius: 0 !important;
                  background: #000 !important;
                  display: flex !important;
                  align-items: center !important;
                  justify-content: center !important;
                }
                .sx-vp-host:fullscreen > video[data-sx-vp="1"],
                .sx-vp-host:-webkit-full-screen > video[data-sx-vp="1"] {
                  width: 100% !important;
                  height: 100% !important;
                  max-width: 100% !important;
                  max-height: 100% !important;
                  object-fit: contain !important;
                  background: #000 !important;
                }
                
                /* Native macOS 27 Tahoe Pill Popup Dropdown Lists (preserves native NSMenu popup!)
                   Uses height:auto + compact 3px vertical padding so site .input-field padding never clips text or bloats height */
                select:not([multiple]):not([size]) {
                  -webkit-appearance: none;
                  appearance: none;
                  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                  font-size: 13px;
                  line-height: 1.3;
                  height: auto;
                  min-height: 24px;
                  color: rgba(0, 0, 0, 0.85);
                  background-color: rgba(0, 0, 0, 0.08);
                  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='12' viewBox='0 0 10 12'%3E%3Cpath d='M2.5 4.4L5 1.9l2.5 2.5M2.5 7.6L5 10.1l2.5-2.5' fill='none' stroke='%231d1d1f' stroke-width='1.45' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E");
                  background-repeat: no-repeat;
                  background-position: right 8px center;
                  background-size: 9px 11px;
                  border: 0;
                  border-radius: 9999px;
                  padding: 3px 26px 3px 10px;
                  box-sizing: border-box;
                  box-shadow: none;
                  cursor: default;
                }
                :where(select:not([multiple]):not([size]):active:not(:disabled)) {
                  background-color: rgba(0, 0, 0, 0.14);
                }
                :where(select:not([multiple]):not([size]):disabled) {
                  background-color: rgba(0, 0, 0, 0.045);
                  color: rgba(0, 0, 0, 0.30);
                }
                :where(select:not([multiple]):not([size]):focus-visible) {
                  outline: 2.5px solid rgba(0, 122, 255, 0.55);
                  outline-offset: 0px;
                }

                /* Native macOS Text Inputs & Textareas */
                :where(input[type="text"], input[type="search"], input[type="email"], input[type="password"], input[type="url"], input[type="number"], input[type="tel"], textarea) {
                  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                  font-size: 13px;
                  border: 0.5px solid rgba(0, 0, 0, 0.24);
                  border-top-color: rgba(0, 0, 0, 0.30);
                  border-radius: 5px;
                  padding: 3px 6px;
                  box-shadow: inset 0 0.5px 1.5px rgba(0, 0, 0, 0.06);
                }
                /* Strictly 0-specificity focus rings (pseudo-classes INSIDE :where) so site CSS always wins */
                :where(input:focus-visible, textarea:focus-visible, select:focus-visible) {
                  outline: 2.5px solid rgba(0, 122, 255, 0.55);
                  outline-offset: -1px;
                }
                :where(button:focus:not(:focus-visible), input[type="button"]:focus:not(:focus-visible), input[type="submit"]:focus:not(:focus-visible), input[type="reset"]:focus:not(:focus-visible)) {
                  outline: none;
                }
                :where(button:focus-visible, input[type="button"]:focus-visible, input[type="submit"]:focus-visible, input[type="reset"]:focus-visible) {
                  outline: 2.5px solid rgba(0, 122, 255, 0.55);
                  outline-offset: 0px;
                }

                /* Native macOS Sliders & Progress Bars */
                :where(input[type="range"]) {
                  -webkit-appearance: none;
                  appearance: none;
                  background: transparent;
                  height: 18px;
                }
                :where(input[type="range"])::-webkit-slider-runnable-track {
                  height: 4px;
                  border-radius: 2px;
                  background: rgba(0, 0, 0, 0.14);
                }
                :where(input[type="range"])::-webkit-slider-thumb {
                  -webkit-appearance: none;
                  width: 16px;
                  height: 16px;
                  border-radius: 50%;
                  background: #FFFFFF;
                  border: 0.5px solid rgba(0, 0, 0, 0.22);
                  box-shadow: 0 1px 2.5px rgba(0, 0, 0, 0.22);
                  margin-top: -6px;
                }
                :where(progress) {
                  -webkit-appearance: none;
                  appearance: none;
                  height: 6px;
                  border-radius: 3px;
                  overflow: hidden;
                }
                :where(progress)::-webkit-progress-bar {
                  background: rgba(0, 0, 0, 0.12);
                  border-radius: 3px;
                }
                :where(progress)::-webkit-progress-value {
                  background: #007AFF;
                  border-radius: 3px;
                }

                @media (prefers-color-scheme: dark) {
                  :where(button, input[type="button"], input[type="reset"]) {
                    color: rgba(255, 255, 255, 0.90);
                    background: rgba(255, 255, 255, 0.14);
                  }
                  :where(button, input[type="button"], input[type="reset"]):active:not(:disabled) {
                    background: rgba(255, 255, 255, 0.22);
                  }
                  :where(button, input[type="button"], input[type="reset"]):disabled {
                    background: rgba(255, 255, 255, 0.07);
                    color: rgba(255, 255, 255, 0.32);
                  }
                  :where(input[type="submit"], button[type="submit"]) {
                    background: #0A84FF;
                    color: #FFFFFF;
                  }
                  :where(input[type="submit"], button[type="submit"]):active:not(:disabled) {
                    background: #0070E0;
                  }
                  :where(input[type="checkbox"], input[type="radio"]) {
                    background: #2C2C2E;
                    border-color: rgba(255, 255, 255, 0.24);
                  }
                  :where(input[type="checkbox"]):checked,
                  :where(input[type="checkbox"]):indeterminate {
                    border-color: #0A84FF;
                    background-color: #0A84FF;
                  }
                  :where(input[type="radio"]):checked {
                    border-color: #0A84FF;
                    background: #FFFFFF;
                  }
                  select:not([multiple]):not([size]) {
                    color: rgba(255, 255, 255, 0.90);
                    background-color: rgba(255, 255, 255, 0.14);
                    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='12' viewBox='0 0 10 12'%3E%3Cpath d='M2.5 4.4L5 1.9l2.5 2.5M2.5 7.6L5 10.1l2.5-2.5' fill='none' stroke='%23f5f5f7' stroke-width='1.45' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E");
                  }
                  :where(select:not([multiple]):not([size])):active:not(:disabled) {
                    background-color: rgba(255, 255, 255, 0.22);
                  }
                  :where(select:not([multiple]):not([size])):disabled {
                    background-color: rgba(255, 255, 255, 0.07);
                    color: rgba(255, 255, 255, 0.32);
                  }
                  :where(input[type="text"], input[type="search"], input[type="email"], input[type="password"], input[type="url"], input[type="number"], input[type="tel"], textarea) {
                    border-color: rgba(255, 255, 255, 0.20);
                  }
                  :where(input[type="range"])::-webkit-slider-runnable-track,
                  :where(progress)::-webkit-progress-bar {
                    background: rgba(255, 255, 255, 0.18);
                  }
                  :where(progress)::-webkit-progress-value {
                    background: #0A84FF;
                  }
                }
              `;
              parent.appendChild(style);
            } catch (_) {}
          }

          // === Embedded Static-Position DOM macOS Safari Video Player + Same-Origin MP4/H.264 Fallback ===
          const supportsH264 = (function() {
            try {
              const tv = document.createElement("video");
              const res = tv.canPlayType && tv.canPlayType('video/mp4; codecs="avc1.42E01E, mp4a.40.2"');
              return res === "probably" || res === "maybe";
            } catch (_) { return false; }
          })();

          function isStandaloneMediaDoc(video) {
            try {
              if (document.contentType && document.contentType.indexOf("video/") === 0) return true;
              if (document.body && document.body.children.length === 1 &&
                  (document.body.children[0] === video ||
                   (video.parentElement && video.parentElement.hasAttribute("data-sx-vp-host") && document.body.children[0] === video.parentElement))) {
                return true;
              }
            } catch (_) {}
            return false;
          }

          function stripSXParams(url) {
            if (!url || typeof url !== "string") return url;
            try {
              const abs = new URL(url, document.baseURI).href;
              const qIdx = abs.indexOf("?");
              if (qIdx < 0) return abs;
              const hIdx = abs.indexOf("#", qIdx);
              const base = abs.slice(0, qIdx);
              const query = hIdx >= 0 ? abs.slice(qIdx + 1, hIdx) : abs.slice(qIdx + 1);
              const hash = hIdx >= 0 ? abs.slice(hIdx) : "";
              const kept = query.split("&").filter(function(p) {
                return p && p !== "__sx_tc=1" && p !== "__sx_meta=1" && p.indexOf("__sx_t=") !== 0;
              });
              return base + (kept.length ? "?" + kept.join("&") : "") + hash;
            } catch (_) { return url; }
          }

          function withSXParams(url, pairs) {
            const clean = stripSXParams(url);
            const hIdx = clean.indexOf("#");
            const base = hIdx >= 0 ? clean.slice(0, hIdx) : clean;
            const hash = hIdx >= 0 ? clean.slice(hIdx) : "";
            const extra = [];
            for (const k in pairs) {
              if (pairs[k] !== null && pairs[k] !== undefined) {
                extra.push(encodeURIComponent(k) + "=" + encodeURIComponent(String(pairs[k])));
              }
            }
            if (!extra.length) return clean;
            return base + (base.indexOf("?") >= 0 ? "&" : "?") + extra.join("&") + hash;
          }

          function resolveOriginalMediaURL(video) {
            if (video.dataset && video.dataset.sxOrigSrc) return video.dataset.sxOrigSrc;
            let raw = video.getAttribute("src") || "";
            if (!raw) {
              const srcEl = video.querySelector("source[src]");
              if (srcEl) raw = srcEl.getAttribute("src") || srcEl.src || "";
            }
            if (!raw) raw = video.currentSrc || "";
            if (!raw && document.contentType && document.contentType.indexOf("video/") === 0) {
              raw = window.location.href;
            }
            if (!raw) return "";
            return stripSXParams(raw);
          }

          function isLikelyUnsupportedFormat(url) {
            if (!url) return false;
            if (url.indexOf("http://") !== 0 && url.indexOf("https://") !== 0) return false;
            if (supportsH264) return false;
            return /\.(mp4|m4v|mov|m4a|m3u8|mpd)(\?|#|$)/i.test(url) || /[?&]format=mp4(&|#|$)/i.test(url) || /\/\/v\.redd\.it\//i.test(url);
          }

          function formatTime(sec) {
            if (!isFinite(sec) || sec < 0) return "00:00";
            const total = Math.floor(sec);
            const h = Math.floor(total / 3600);
            const m = Math.floor((total % 3600) / 60);
            const s = total % 60;
            const mm = m < 10 ? "0" + m : "" + m;
            const ss = s < 10 ? "0" + s : "" + s;
            if (h > 0) return h + ":" + mm + ":" + ss;
            return mm + ":" + ss;
          }

          const SHADOW_CSS = `
            :host {
              position: relative;
              box-sizing: border-box;
            }
            .hud {
              position: absolute;
              inset: 0;
              z-index: 2;
              pointer-events: none;
              user-select: none;
              -webkit-user-select: none;
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            }
            .backdrop {
              position: absolute;
              inset: 0;
              pointer-events: auto;
              cursor: pointer;
            }
            .chrome {
              position: absolute;
              inset: 0;
              pointer-events: none;
              opacity: 1;
              transition: opacity 0.2s ease;
            }
            .hud.hidden .chrome {
              opacity: 0;
            }
            .hud.hidden .chrome * {
              pointer-events: none !important;
            }
            .glass {
              background: rgba(68, 68, 72, 0.34);
              backdrop-filter: blur(28px) saturate(165%);
              -webkit-backdrop-filter: blur(28px) saturate(165%);
              border: none;
              box-shadow: none;
              color: #fff;
            }
            .icon-btn {
              border: 0;
              background: transparent;
              color: #fff;
              display: inline-flex;
              align-items: center;
              justify-content: center;
              padding: 0;
              margin: 0;
              width: 32px;
              height: 32px;
              border-radius: 9999px;
              cursor: pointer;
              pointer-events: auto;
              outline: none;
              flex: 0 0 auto;
            }
            .icon-btn svg {
              display: block;
              pointer-events: none;
            }
            /* Top-left pill: Fullscreen + PiP */
            .tl-pill {
              position: absolute;
              top: 16px;
              left: 16px;
              height: 44px;
              padding: 0 11px;
              gap: 6px;
              border-radius: 22px;
              display: inline-flex;
              align-items: center;
              pointer-events: auto;
              box-sizing: border-box;
            }
            /* Top-right pill: horizontal volume slider + speaker icon */
            .tr-pill {
              position: absolute;
              top: 16px;
              right: 16px;
              height: 44px;
              width: 215px;
              padding: 0 12px 0 18px;
              gap: 10px;
              border-radius: 22px;
              display: inline-flex;
              align-items: center;
              pointer-events: auto;
              box-sizing: border-box;
            }
            /* Bottom-center full Safari pill */
            .bot-pill {
              position: absolute;
              left: 50%;
              transform: translateX(-50%);
              bottom: 16px;
              width: min(calc(100% - 36px), 840px);
              height: 48px;
              padding: 0 16px;
              gap: 10px;
              border-radius: 24px;
              display: flex;
              align-items: center;
              pointer-events: auto;
              box-sizing: border-box;
            }
            .time {
              font-size: 13.5px;
              font-weight: 500;
              font-variant-numeric: tabular-nums;
              color: rgba(255, 255, 255, 0.96);
              white-space: nowrap;
              flex: 0 0 auto;
              min-width: 42px;
              text-align: center;
            }
            .slider-wrap {
              position: relative;
              flex: 1 1 auto;
              height: 28px;
              display: flex;
              align-items: center;
              cursor: pointer;
              min-width: 48px;
              pointer-events: auto;
            }
            .slider-track {
              position: relative;
              width: 100%;
              height: 7px;
              border-radius: 9999px;
              background: rgba(255, 255, 255, 0.28);
            }
            .slider-fill {
              position: absolute;
              left: 0;
              top: 0;
              bottom: 0;
              width: 0%;
              border-radius: 9999px;
              background: #fff;
            }
            .slider-knob {
              position: absolute;
              top: 50%;
              left: 0%;
              width: 18px;
              height: 18px;
              border-radius: 50%;
              background: #fff;
              transform: translate(-50%, -50%);
              box-shadow: 0 1px 4px rgba(0, 0, 0, 0.25);
              pointer-events: none;
            }
            .tr-pill .slider-track {
              height: 6.5px;
            }
            .tr-pill .slider-knob {
              width: 17px;
              height: 17px;
            }
            .stats-box {
              display: none;
              position: absolute;
              top: 50%;
              left: 50%;
              transform: translate(-50%, -50%);
              padding: 13px 18px;
              border-radius: 14px;
              background: rgba(58, 58, 66, 0.44);
              -webkit-backdrop-filter: blur(22px) saturate(160%);
              backdrop-filter: blur(22px) saturate(160%);
              border: none;
              box-shadow: 0 10px 28px rgba(0, 0, 0, 0.28);
              color: #FFFFFF;
              font-size: 12.5px;
              line-height: 1.48;
              font-variant-numeric: tabular-nums;
              pointer-events: none;
              z-index: 25;
              min-width: 220px;
              max-width: 340px;
            }
            .stats-table {
              border-collapse: collapse;
              width: 100%;
            }
            .stats-k {
              font-weight: 700;
              text-align: right;
              padding: 1px 10px 1px 0;
              color: rgba(255, 255, 255, 0.96);
              white-space: nowrap;
            }
            .stats-v {
              font-weight: 400;
              text-align: left;
              padding: 1px 0;
              color: rgba(255, 255, 255, 0.94);
              white-space: nowrap;
            }
            .stats-box.open {
              display: block;
            }
            /* Compact bottom-left rounded-square Play/Pause button (matches Safari thumbnail player) */
            .compact-play {
              display: none;
              position: absolute;
              left: 8px;
              bottom: 8px;
              width: 50px;
              height: 50px;
              border-radius: 15px;
              align-items: center;
              justify-content: center;
              padding: 0;
              cursor: pointer;
              pointer-events: auto;
              outline: none;
              transform-origin: bottom left;
            }
            .hud.compact .tl-pill {
              top: 8px;
              left: 8px;
              height: 44px;
              padding: 0 12px;
              gap: 10px;
              border-radius: 22px;
              transform-origin: top left;
            }
            .hud.compact .tl-pill .icon-btn {
              width: 32px;
              height: 32px;
            }
            .hud.compact .tr-pill,
            .hud.compact .bot-pill {
              display: none !important;
            }
            .hud.compact .compact-play {
              display: flex;
            }
            .hud.narrow .time,
            .hud.narrow .btn-back,
            .hud.narrow .btn-fwd {
              display: none !important;
            }
            .spinner {
              position: absolute;
              left: 50%;
              top: 50%;
              width: 34px;
              height: 34px;
              margin: -17px 0 0 -17px;
              border-radius: 50%;
              border: 3px solid rgba(255, 255, 255, 0.28);
              border-top-color: #fff;
              animation: sxspin 0.75s linear infinite;
              opacity: 0;
              pointer-events: none;
              z-index: 3;
              transition: opacity 0.15s ease;
            }
            .hud.loading .spinner {
              opacity: 1;
            }
            @keyframes sxspin {
              to { transform: rotate(360deg); }
            }
          `;

          const ICON_PLAY = '<svg width="19" height="19" viewBox="0 0 24 24" fill="currentColor"><path d="M7.5 4.8v14.4c0 .8.88 1.3 1.56.86l11.2-7.2a1 1 0 0 0 0-1.72l-11.2-7.2A1 1 0 0 0 7.5 4.8z"/></svg>';
          const ICON_PAUSE = '<svg width="19" height="19" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="4.5" width="4.4" height="15" rx="1.4"/><rect x="13.6" y="4.5" width="4.4" height="15" rx="1.4"/></svg>';
          const ICON_BACK15 = '<svg width="21" height="21" viewBox="0 0 24 24"><path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" d="M12 5a7 7 0 1 1-6.32 4M12 5V2.2L8.8 5.1 12 7.8"/><text x="12" y="15.3" text-anchor="middle" font-size="7.4" font-weight="700" fill="currentColor">15</text></svg>';
          const ICON_FWD15 = '<svg width="21" height="21" viewBox="0 0 24 24"><path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" d="M12 5a7 7 0 1 0 6.32 4M12 5V2.2l3.2 2.9L12 7.8"/><text x="12" y="15.3" text-anchor="middle" font-size="7.4" font-weight="700" fill="currentColor">15</text></svg>';
          const ICON_FS = '<svg width="20" height="20" viewBox="0 0 24 24"><path fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round" d="M10 4H4v6M4 4l6.5 6.5M14 20h6v-6M20 20l-6.5-6.5"/></svg>';
          const ICON_PIP = '<svg width="21" height="21" viewBox="0 0 24 24"><rect x="2.5" y="4.5" width="19" height="14.5" rx="2.6" fill="none" stroke="currentColor" stroke-width="1.9"/><rect x="11.5" y="11" width="7.8" height="5.6" rx="1.3" fill="currentColor"/><path fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" d="M6.5 8.2l3 3M9.5 8.2v3h-3"/></svg>';
          const ICON_VOL = '<svg width="19" height="19" viewBox="0 0 24 24"><path fill="currentColor" d="M11 5.5L6.5 9.2H3.5v5.6h3L11 18.5v-13z"/><path fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" d="M15 8.8a4.6 4.6 0 0 1 0 6.4M17.8 6.2a8.2 8.2 0 0 1 0 11.6"/></svg>';
          const ICON_MUTE = '<svg width="19" height="19" viewBox="0 0 24 24"><path fill="currentColor" d="M11 5.5L6.5 9.2H3.5v5.6h3L11 18.5v-13z"/><path fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" d="M15.5 9.2l5 5.6M20.5 9.2l-5 5.6"/></svg>';
          const ICON_MORE = '<svg width="18" height="18" viewBox="0 0 24 24"><path fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" d="M6 7l5 5-5 5M13 7l5 5-5 5"/></svg>';

          const embeddedVideos = new WeakSet();
          const bareFallbackVideos = new WeakSet();

          // Videos WITHOUT the `controls` attribute (autoplay/background video, custom-control players) get no HUD, but
          // they must still fall back to the same-origin transcode when the engine cannot decode their H.264/AAC.
          function installBareTranscodeFallback(video) {
            if (!video || bareFallbackVideos.has(video) || supportsH264) return;
            bareFallbackVideos.add(video);
            const fallback = function(force) {
              try {
                if (!force) {
                  const err = video.error;
                  if (!err || (err.code !== 3 && err.code !== 4)) return;
                }
                const orig = resolveOriginalMediaURL(video);
                if (!orig || (orig.indexOf("http://") !== 0 && orig.indexOf("https://") !== 0)) return;
                if ((video.currentSrc || video.src || "").indexOf("__sx_tc=1") >= 0) return;  // already the transcode
                const wasPlaying = !video.paused || video.autoplay;
                video.dataset.sxOrigSrc = orig;
                try {
                  const sources = video.querySelectorAll("source");
                  for (let i = 0; i < sources.length; i++) sources[i].remove();
                } catch (_) {}
                video.src = withSXParams(orig, { __sx_tc: 1 });
                video.load();
                if (wasPlaying) {
                  const p = video.play();
                  if (p && p.catch) p.catch(function() {});
                }
              } catch (_) {}
            };
            const checkNoVideoTrack = function() {
              if (video.readyState >= 1 && video.videoWidth === 0 && isLikelyUnsupportedFormat(resolveOriginalMediaURL(video))) {
                fallback(true);
              }
            };
            video.addEventListener("error", function() { fallback(false); });
            video.addEventListener("loadedmetadata", checkNoVideoTrack);
            if (video.error) fallback(false);
            else checkNoVideoTrack();
          }

          function embedVideoPlayer(video) {
            if (!video || !video.isConnected || embeddedVideos.has(video)) return;
            if (!video.hasAttribute("controls")) { installBareTranscodeFallback(video); return; }
            if (!video.parentNode) return;
            embeddedVideos.add(video);

            const cs = window.getComputedStyle ? window.getComputedStyle(video) : null;
            const standalone = isStandaloneMediaDoc(video);

            const host = document.createElement("div");
            host.className = "sx-vp-host";
            host.setAttribute("data-sx-vp-host", "1");

            if (standalone) {
              host.style.position = "fixed";
              host.style.inset = "0";
              host.style.display = "flex";
              host.style.alignItems = "center";
              host.style.justifyContent = "center";
              host.style.width = "100vw";
              host.style.height = "100vh";
              host.style.background = "#000";
              video.style.width = "100%";
              video.style.height = "100%";
              video.style.objectFit = "contain";
              video.style.background = "#000";
              if (document.body) {
                document.body.style.margin = "0";
                document.body.style.background = "#000";
                document.body.style.overflow = "hidden";
              }
            } else if (cs) {
              const disp = cs.display || "inline-block";
              host.style.display = (disp === "block" || disp === "flex" || disp === "grid") ? "block" : "inline-block";
              if (cs.marginTop && cs.marginTop !== "0px") host.style.marginTop = cs.marginTop;
              if (cs.marginRight && cs.marginRight !== "0px") host.style.marginRight = cs.marginRight;
              if (cs.marginBottom && cs.marginBottom !== "0px") host.style.marginBottom = cs.marginBottom;
              if (cs.marginLeft && cs.marginLeft !== "0px") host.style.marginLeft = cs.marginLeft;
              if (cs.borderRadius && cs.borderRadius !== "0px") host.style.borderRadius = cs.borderRadius;
              if (cs.float && cs.float !== "none") host.style.cssFloat = cs.float;
            } else {
              host.style.display = "inline-block";
            }

            video.setAttribute("data-sx-vp", "1");
            video.parentNode.insertBefore(host, video);
            host.appendChild(video);

            const shadow = host.attachShadow({ mode: "closed" });
            shadow.innerHTML =
              "<style>" + SHADOW_CSS + "</style>" +
              "<slot></slot>" +
              '<div class="hud">' +
                '<div class="backdrop"></div>' +
                '<div class="spinner"></div>' +
                '<div class="chrome">' +
                  '<div class="tl-pill glass">' +
                    '<button class="icon-btn btn-fs" type="button" aria-label="Fullscreen">' + ICON_FS + '</button>' +
                    '<button class="icon-btn btn-pip" type="button" aria-label="Picture in Picture">' + ICON_PIP + '</button>' +
                  '</div>' +
                  '<div class="tr-pill glass">' +
                    '<div class="slider-wrap vol-slider">' +
                      '<div class="slider-track"><div class="slider-fill vol-fill"></div><div class="slider-knob vol-knob"></div></div>' +
                    '</div>' +
                    '<button class="icon-btn vol-btn" type="button" aria-label="Mute">' + ICON_VOL + '</button>' +
                  '</div>' +
                  '<button class="compact-play glass" type="button" aria-label="Play">' + ICON_PLAY + '</button>' +
                  '<div class="bot-pill glass">' +
                    '<button class="icon-btn btn-back" type="button" aria-label="Back 15 seconds">' + ICON_BACK15 + '</button>' +
                    '<button class="icon-btn btn-play" type="button" aria-label="Play">' + ICON_PLAY + '</button>' +
                    '<button class="icon-btn btn-fwd" type="button" aria-label="Forward 15 seconds">' + ICON_FWD15 + '</button>' +
                    '<span class="time t-cur">00:00</span>' +
                    '<div class="slider-wrap scrub-slider">' +
                      '<div class="slider-track"><div class="slider-fill scrub-fill"></div><div class="slider-knob scrub-knob"></div></div>' +
                    '</div>' +
                    '<span class="time t-dur">00:00</span>' +
                    '<button class="icon-btn speed-btn" type="button" aria-label="More Options">' + ICON_MORE + '</button>' +
                  '</div>' +
                  '<div class="stats-box glass"></div>' +
                '</div>' +
              '</div>';

            const hud = shadow.querySelector(".hud");
            if (standalone) hud.classList.add("standalone");
            const backdrop = shadow.querySelector(".backdrop");
            const btnFs = shadow.querySelector(".btn-fs");
            const btnPip = shadow.querySelector(".btn-pip");
            const btnBack = shadow.querySelector(".btn-back");
            const btnPlay = shadow.querySelector(".btn-play");
            const btnCompactPlay = shadow.querySelector(".compact-play");
            const btnFwd = shadow.querySelector(".btn-fwd");
            const btnSpeed = shadow.querySelector(".speed-btn");
            const statsBox = shadow.querySelector(".stats-box");
            const tCur = shadow.querySelector(".t-cur");
            const tDur = shadow.querySelector(".t-dur");
            const scrubSlider = shadow.querySelector(".scrub-slider");
            const scrubFill = shadow.querySelector(".scrub-fill");
            const scrubKnob = shadow.querySelector(".scrub-knob");
            const volSlider = shadow.querySelector(".vol-slider");
            const volFill = shadow.querySelector(".vol-fill");
            const volKnob = shadow.querySelector(".vol-knob");
            const volBtn = shadow.querySelector(".vol-btn");

            let isScrubbing = false;
            let isDraggingVol = false;
            let isMenuOpen = false;
            let showStats = false;
            let autoHideTimer = 0;

            let transcoded = false;
            let transcodeInFlight = false;
            let seekOffset = 0;
            let knownDuration = 0;
            let metaFetched = false;

            let scrubPendingSec = null;

            function getEffectiveDuration() {
              if (knownDuration > 0) return knownDuration;
              if (isFinite(video.duration) && video.duration > 0) return seekOffset + video.duration;
              return 0;
            }

            function getEffectiveTime() {
              if (scrubPendingSec !== null) return scrubPendingSec;
              const ct = isFinite(video.currentTime) ? video.currentTime : 0;
              if (transcoded && seekOffset > 0) {
                return seekOffset + ct;
              }
              return ct;
            }

            function isInSeekableRange(localSec) {
              if (!isFinite(localSec) || localSec < 0) return false;
              try {
                for (let i = 0; i < video.seekable.length; i++) {
                  const s = video.seekable.start(i);
                  const e = video.seekable.end(i);
                  if (isFinite(e) && localSec >= s - 0.05 && localSec <= e + 0.05) {
                    return true;
                  }
                }
              } catch (_) {}
              return false;
            }

            function fetchMetaDuration(origUrl) {
              if (metaFetched) return;
              metaFetched = true;
              const metaUrl = withSXParams(origUrl, { __sx_meta: 1 });
              fetch(metaUrl).then(function(r) { return r.json(); }).then(function(data) {
                if (data && isFinite(data.duration) && data.duration > 0) {
                  knownDuration = data.duration;
                  syncUI();
                }
              }).catch(function() {});
            }

            function startTranscode(startSec, autoPlay) {
              const origUrl = resolveOriginalMediaURL(video);
              if (!origUrl || (origUrl.indexOf("http://") !== 0 && origUrl.indexOf("https://") !== 0)) return false;
              video.dataset.sxOrigSrc = origUrl;
              transcoded = true;
              transcodeInFlight = true;
              seekOffset = Math.max(0, startSec || 0);
              hud.classList.add("loading");
              fetchMetaDuration(origUrl);

              const params = { __sx_tc: 1 };
              if (seekOffset > 0.05) params.__sx_t = seekOffset.toFixed(2);
              const proxyUrl = withSXParams(origUrl, params);

              try {
                const sources = video.querySelectorAll("source");
                for (let i = 0; i < sources.length; i++) sources[i].remove();
              } catch (_) {}
              video.src = proxyUrl;
              video.load();
              if (autoPlay) {
                const p = video.play();
                if (p && p.catch) p.catch(function() {});
              }
              return true;
            }

            function cancelAutoHide() {
              if (autoHideTimer) { clearTimeout(autoHideTimer); autoHideTimer = 0; }
            }

            function scheduleAutoHide(ms) {
              cancelAutoHide();
              if (video.paused || video.ended || isScrubbing || isDraggingVol || isMenuOpen) {
                hud.classList.remove("hidden");
                return;
              }
              autoHideTimer = setTimeout(function() {
                if (!video.paused && !video.ended && !isScrubbing && !isDraggingVol && !isMenuOpen) {
                  hud.classList.add("hidden");
                }
              }, ms || 2200);
            }

            function updateLayoutMetrics() {
              const r = host.getBoundingClientRect();
              const w = r.width || 0;
              const h = r.height || 0;
              if (w < 10 || h < 10) return;
              const compact = (w < 360 || h < 180);
              hud.classList.toggle("compact", compact);
              hud.classList.toggle("narrow", !compact && w < 520);
              const tlPill = shadow.querySelector(".tl-pill");
              if (compact) {
                const s = Math.min(1, Math.max(0.65, (h - 20) / 100));
                if (tlPill) tlPill.style.transform = s < 0.99 ? ("scale(" + s.toFixed(3) + ")") : "";
                btnCompactPlay.style.transform = s < 0.99 ? ("scale(" + s.toFixed(3) + ")") : "";
              } else {
                if (tlPill) tlPill.style.transform = "";
                btnCompactPlay.style.transform = "";
              }
            }

            function syncUI() {
              const paused = !!(video.paused || video.ended);
              const icon = paused ? ICON_PLAY : ICON_PAUSE;
              btnPlay.innerHTML = icon;
              btnCompactPlay.innerHTML = icon;
              btnPlay.setAttribute("aria-label", paused ? "Play" : "Pause");
              btnCompactPlay.setAttribute("aria-label", paused ? "Play" : "Pause");

              const dur = getEffectiveDuration();
              const cur = Math.min(dur > 0 ? dur : Infinity, getEffectiveTime());
              tCur.textContent = formatTime(cur);
              tDur.textContent = formatTime(dur);
              const pct = (dur > 0) ? Math.max(0, Math.min(100, (cur / dur) * 100)) : 0;
              scrubFill.style.width = pct.toFixed(2) + "%";
              scrubKnob.style.left = pct.toFixed(2) + "%";

              const effVol = video.muted ? 0 : (isFinite(video.volume) ? video.volume : 1);
              const vpct = Math.round(effVol * 100);
              volBtn.innerHTML = (video.muted || effVol <= 0.001) ? ICON_MUTE : ICON_VOL;
              volFill.style.width = vpct + "%";
              volKnob.style.left = vpct + "%";

              if (showStats) {
                const srcUrl = resolveOriginalMediaURL(video) || "";
                const isBlobOrMse = srcUrl.startsWith("blob:") || srcUrl.startsWith("data:") || (!srcUrl && video.srcObject != null);
                const sourceType = isBlobOrMse ? "MediaSource" : "File";

                const rect = video.getBoundingClientRect();
                const vwCss = Math.round(rect.width || video.clientWidth || 0);
                const vhCss = Math.round(rect.height || video.clientHeight || 0);
                const dpr = Math.max(1, Math.round((window.devicePixelRatio || 1) * 100) / 100);
                const viewportText = (vwCss && vhCss)
                  ? (vwCss + "\u00d7" + vhCss + " (" + dpr + "\u00d7)")
                  : "\u2014";

                let totalFrames = 0;
                let droppedFrames = 0;
                if (typeof video.getVideoPlaybackQuality === "function") {
                  try {
                    const q = video.getVideoPlaybackQuality();
                    if (q) {
                      totalFrames = q.totalVideoFrames || 0;
                      droppedFrames = q.droppedVideoFrames || 0;
                    }
                  } catch (_) {}
                } else {
                  totalFrames = video.webkitDecodedFrameCount || 0;
                  droppedFrames = video.webkitDroppedFrameCount || 0;
                }
                const framesText = droppedFrames + " dropped of " + totalFrames;

                const natW = video.videoWidth || 0;
                const natH = video.videoHeight || 0;
                let fps = 30;
                if (typeof video.getVideoPlaybackQuality === "function") {
                  try {
                    const q = video.getVideoPlaybackQuality();
                    const nowMs = performance.now();
                    if (q && typeof q.totalVideoFrames === "number") {
                      if (!video.__sxFpsSample) {
                        video.__sxFpsSample = { t: nowMs, f: q.totalVideoFrames, fps: 30 };
                      } else {
                        const dtSec = (nowMs - video.__sxFpsSample.t) / 1000;
                        const df = q.totalVideoFrames - video.__sxFpsSample.f;
                        if (dtSec >= 0.4 && df >= 0) {
                          const measured = Math.round(df / dtSec);
                          if (measured >= 1 && measured <= 240) {
                            video.__sxFpsSample.fps = measured;
                          }
                          video.__sxFpsSample.t = nowMs;
                          video.__sxFpsSample.f = q.totalVideoFrames;
                        }
                      }
                      fps = video.__sxFpsSample.fps || 30;
                    }
                  } catch (_) {}
                }
                const resolutionText = (natW && natH)
                  ? (natW + "\u00d7" + natH + " (" + fps + "fps)")
                  : "\u2014";

                let codecText = "";
                try {
                  const sEl = video.querySelector("source[type]");
                  if (sEl) {
                    const tAttr = sEl.getAttribute("type") || "";
                    const m = tAttr.match(/codecs\s*=\s*["']?([^"';]+)/i);
                    if (m && m[1]) codecText = m[1].trim();
                  }
                } catch (_) {}
                if (!codecText) {
                  const low = srcUrl.toLowerCase();
                  if (low.includes(".mp4") || low.includes(".m4v") || low.includes(".mov")) codecText = "avc1.640033";
                  else if (low.includes(".webm")) codecText = "vp9";
                  else if (low.includes(".ogg") || low.includes(".ogv")) codecText = "theora";
                  else codecText = "avc1.640033";
                }

                const colorText = "bt709 / bt709 / bt709";

                const esc = function(x) {
                  return String(x)
                    .replace(/&/g, "&amp;")
                    .replace(/</g, "&lt;")
                    .replace(/>/g, "&gt;")
                    .replace(/"/g, "&quot;");
                };
                const rows = [
                  ["Source", sourceType],
                  ["Viewport", viewportText],
                  ["Frames", framesText],
                  ["Resolution", resolutionText],
                  ["Codecs", codecText],
                  ["Color", colorText]
                ];
                let html = '<table class="stats-table">';
                for (let i = 0; i < rows.length; i++) {
                  html += '<tr><td class="stats-k">' + esc(rows[i][0]) + '</td><td class="stats-v">' + esc(rows[i][1]) + '</td></tr>';
                }
                html += '</table>';
                statsBox.innerHTML = html;
              }
            }

            function togglePlay() {
              hud.classList.remove("hidden");
              if (video.paused || video.ended) {
                if (!transcoded && isLikelyUnsupportedFormat(resolveOriginalMediaURL(video))) {
                  startTranscode(0, true);
                  return;
                }
                const p = video.play();
                if (p && p.catch) {
                  p.catch(function() {
                    if (!transcoded) startTranscode(0, true);
                  });
                }
              } else {
                video.pause();
              }
            }

            function seekToSeconds(targetSec) {
              const dur = getEffectiveDuration();
              const clamped = Math.max(0, dur > 0 ? Math.min(dur, targetSec) : Math.max(0, targetSec));
              if (transcoded) {
                const localTarget = clamped - seekOffset;
                if (localTarget >= 0 && isInSeekableRange(localTarget)) {
                  try { video.currentTime = localTarget; } catch (_) {}
                  syncUI();
                  return;
                }
                startTranscode(clamped, !video.paused);
                syncUI();
                return;
              }
              try { video.currentTime = clamped; } catch (_) {}
              syncUI();
            }

            btnPlay.addEventListener("click", function(e) { e.stopPropagation(); togglePlay(); scheduleAutoHide(2200); });
            btnCompactPlay.addEventListener("click", function(e) { e.stopPropagation(); togglePlay(); scheduleAutoHide(2200); });
            btnBack.addEventListener("click", function(e) { e.stopPropagation(); seekToSeconds(getEffectiveTime() - 15); scheduleAutoHide(2200); });
            btnFwd.addEventListener("click", function(e) { e.stopPropagation(); seekToSeconds(getEffectiveTime() + 15); scheduleAutoHide(2200); });
            btnFs.addEventListener("click", function(e) {
              e.stopPropagation();
              if (document.fullscreenElement) {
                document.exitFullscreen().catch(function() {});
              } else if (host.requestFullscreen) {
                host.requestFullscreen().catch(function() {
                  if (video.requestFullscreen) video.requestFullscreen().catch(function() {});
                });
              }
            });
            btnPip.addEventListener("click", function(e) {
              e.stopPropagation();
              if (document.pictureInPictureElement === video) {
                document.exitPictureInPicture().catch(function() {});
              } else if (video.requestPictureInPicture) {
                video.requestPictureInPicture().catch(function() {});
              }
            });
            btnSpeed.addEventListener("click", function(e) {
              e.stopPropagation();
              window.__sxActiveVideoMenu = {
                setRate: function(r) {
                  video.playbackRate = r;
                  syncUI();
                },
                toggleStats: function() {
                  showStats = !showStats;
                  statsBox.classList.toggle("open", showStats);
                  syncUI();
                }
              };
              const r = btnSpeed.getBoundingClientRect();
              if (typeof reportNativeVideo === "function") {
                reportNativeVideo("menu", JSON.stringify({ rate: video.playbackRate || 1, showStats: showStats }), r.right, r.top, r.width, r.height, true, false);
              }
              scheduleAutoHide(2200);
            });
            volBtn.addEventListener("click", function(e) {
              e.stopPropagation();
              video.muted = !video.muted;
              if (!video.muted && video.volume === 0) video.volume = 0.7;
              syncUI();
              scheduleAutoHide(2200);
            });

            backdrop.addEventListener("click", function(e) {
              e.stopPropagation();
              togglePlay();
              scheduleAutoHide(2200);
            });
            backdrop.addEventListener("dblclick", function(e) {
              e.stopPropagation();
              if (document.fullscreenElement) {
                document.exitFullscreen().catch(function() {});
              } else if (host.requestFullscreen) {
                host.requestFullscreen().catch(function() {});
              }
            });

            function applyScrubEvent(e, commit) {
              const r = scrubSlider.getBoundingClientRect();
              if (r.width <= 0) return;
              const frac = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width));
              const dur = getEffectiveDuration();
              if (dur > 0) {
                const target = frac * dur;
                const localTarget = target - seekOffset;
                const canNativeSeek = !transcoded || (localTarget >= 0 && isInSeekableRange(localTarget));
                if (commit === false && !canNativeSeek) {
                  scrubPendingSec = target;
                  syncUI();
                  return;
                }
                scrubPendingSec = null;
                seekToSeconds(target);
              }
            }
            scrubSlider.addEventListener("pointerdown", function(e) {
              e.stopPropagation();
              isScrubbing = true;
              cancelAutoHide();
              try { scrubSlider.setPointerCapture(e.pointerId); } catch (_) {}
              applyScrubEvent(e, false);
            });
            scrubSlider.addEventListener("pointermove", function(e) {
              if (!isScrubbing) return;
              e.stopPropagation();
              applyScrubEvent(e, false);
            });
            scrubSlider.addEventListener("pointerup", function(e) {
              if (!isScrubbing) return;
              e.stopPropagation();
              isScrubbing = false;
              if (scrubPendingSec !== null) {
                const t = scrubPendingSec;
                scrubPendingSec = null;
                seekToSeconds(t);
              }
              scheduleAutoHide(2000);
            });

            function applyVolEvent(e) {
              const r = volSlider.getBoundingClientRect();
              if (r.width <= 0) return;
              const v = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width));
              video.muted = v <= 0.001;
              video.volume = v;
              syncUI();
            }
            volSlider.addEventListener("pointerdown", function(e) {
              e.stopPropagation();
              isDraggingVol = true;
              cancelAutoHide();
              try { volSlider.setPointerCapture(e.pointerId); } catch (_) {}
              applyVolEvent(e);
            });
            volSlider.addEventListener("pointermove", function(e) {
              if (!isDraggingVol) return;
              e.stopPropagation();
              applyVolEvent(e);
            });
            volSlider.addEventListener("pointerup", function(e) {
              if (!isDraggingVol) return;
              e.stopPropagation();
              isDraggingVol = false;
              scheduleAutoHide(2000);
            });

            host.addEventListener("mouseenter", function() {
              hud.classList.remove("hidden");
              scheduleAutoHide(2200);
            });
            host.addEventListener("mousemove", function() {
              hud.classList.remove("hidden");
              scheduleAutoHide(2200);
            });
            host.addEventListener("mouseleave", function() {
              if (!video.paused && !video.ended && !isScrubbing && !isDraggingVol) {
                scheduleAutoHide(400);
              }
            });

            const checkNoVideoTrack = function() {
              if (!transcoded && video.readyState >= 1 && video.videoWidth === 0 && isLikelyUnsupportedFormat(resolveOriginalMediaURL(video))) {
                startTranscode(0, !video.paused || video.autoplay);
              }
            };
            video.addEventListener("play", function() {
              checkNoVideoTrack();
              syncUI();
              scheduleAutoHide(2200);
            }, { passive: true });
            video.addEventListener("playing", function() {
              transcodeInFlight = false;
              hud.classList.remove("loading");
              syncUI();
              scheduleAutoHide(2200);
            }, { passive: true });
            video.addEventListener("loadeddata", function() {
              transcodeInFlight = false;
              hud.classList.remove("loading");
              syncUI();
            }, { passive: true });
            video.addEventListener("waiting", function() {
              if (transcodeInFlight) hud.classList.add("loading");
            }, { passive: true });
            video.addEventListener("pause", function() {
              cancelAutoHide();
              hud.classList.remove("hidden");
              syncUI();
            }, { passive: true });
            video.addEventListener("ended", function() {
              cancelAutoHide();
              hud.classList.remove("hidden");
              hud.classList.remove("loading");
              syncUI();
            }, { passive: true });
            ["timeupdate", "durationchange", "volumechange", "loadedmetadata"].forEach(function(ev) {
              video.addEventListener(ev, syncUI, { passive: true });
            });
            video.addEventListener("loadedmetadata", checkNoVideoTrack, { passive: true });
            checkNoVideoTrack();
            video.addEventListener("error", function() {
              hud.classList.remove("loading");
              if (!transcoded && video.error && (video.error.code === 3 || video.error.code === 4)) {
                startTranscode(0, !video.paused || video.autoplay || standalone);
              }
            }, { passive: true });

            if (typeof ResizeObserver !== "undefined") {
              try {
                new ResizeObserver(updateLayoutMetrics).observe(host);
              } catch (_) {}
            }
            updateLayoutMetrics();
            syncUI();

            // On standalone MP4 media documents, proactively start same-origin transcode immediately.
            if (standalone && isLikelyUnsupportedFormat(resolveOriginalMediaURL(video))) {
              startTranscode(0, true);
            }
          }

          function pickPackagedMediaURL(host) {
            try {
              const raw = host.getAttribute("packaged-media-json");
              if (!raw) return "";
              const pm = JSON.parse(raw);
              const perms = (pm && pm.playbackMp4s && pm.playbackMp4s.permutations) || [];
              let best = "", bestH = 0;
              for (let i = 0; i < perms.length; i++) {
                const src = perms[i] && perms[i].source;
                const u = src && src.url;
                if (!u || (u.indexOf("http://") !== 0 && u.indexOf("https://") !== 0)) continue;
                const h = (src.dimensions && src.dimensions.height) || 0;
                if (h <= 1080 && (h > bestH || !best)) { best = u; bestH = h; }
              }
              return best;
            } catch (_) { return ""; }
          }

          function hookShadowMediaHost(host) {
            if (!host || supportsH264) return;
            const video = (host.shadowRoot && host.shadowRoot.querySelector("video")) || host.querySelector("video");
            if (!video) return;
            const rawSrc = pickPackagedMediaURL(host) || host.getAttribute("src") || video.getAttribute("src") || video.currentSrc || "";
            if (!rawSrc || (rawSrc.indexOf("http://") !== 0 && rawSrc.indexOf("https://") !== 0)) return;
            const cleanSrc = stripSXParams(rawSrc);
            if (!isLikelyUnsupportedFormat(cleanSrc)) return;
            const tcURL = withSXParams(cleanSrc, { __sx_tc: 1 });
            if (video.dataset.sxTcBound === tcURL) return;
            video.dataset.sxTcBound = tcURL;
            const clearErrorOverlay = function() {
              try {
                const errEl = host.shadowRoot && host.shadowRoot.querySelector("shreddit-error-overlay");
                if (errEl) errEl.remove();
              } catch (_) {}
            };
            const swap = function(autoPlay) {
              if ((video.getAttribute("src") || "").indexOf("__sx_tc=1") >= 0) return;
              clearErrorOverlay();
              video.removeAttribute("crossorigin");
              video.src = tcURL;
              video.load();
              if (autoPlay) { const p = video.play(); if (p && p.catch) p.catch(function() {}); }
            };
            video.addEventListener("play", function() { swap(true); }, { passive: true });
            video.addEventListener("error", function() {
              if (video.error && (video.error.code === 3 || video.error.code === 4)) swap(video.autoplay || !video.paused || video.loop);
            }, { passive: true });
            const r = host.getBoundingClientRect();
            const inView = r.width > 0 && r.height > 0 && r.bottom >= -200 && r.top <= (window.innerHeight || 900) + 200;
            if (video.error || inView) {
              const cur = video.getAttribute("src") || video.currentSrc || "";
              if (video.error || !cur || cur.indexOf("blob:") === 0 || video.readyState === 0) {
                swap(video.autoplay || !video.paused || video.loop);
              }
            }
          }

          let scanRaf = 0;
          function scanVideos() {
            scanRaf = 0;
            try {
              const vids = document.querySelectorAll("video");  // embedVideoPlayer decides: HUD for [controls], bare transcode fallback otherwise
              for (let i = 0; i < vids.length; i++) {
                embedVideoPlayer(vids[i]);
              }
              if (!supportsH264) {
                const hosts = document.querySelectorAll("shreddit-player, shreddit-player-2");
                for (let j = 0; j < hosts.length; j++) hookShadowMediaHost(hosts[j]);
              }
            } catch (_) {}
          }
          function scheduleVideoSync() {
            if (!scanRaf) scanRaf = requestAnimationFrame(scanVideos);
          }

          injectNativeControlStyles();
          if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", function() {
              injectNativeControlStyles();
              scanVideos();
            }, { once: true, passive: true });
          } else {
            scanVideos();
          }
          window.addEventListener("load", scanVideos, { passive: true });
          try {
            const vmo = new MutationObserver(function(muts) {
              for (let i = 0; i < muts.length; i++) {
                if ((muts[i].addedNodes && muts[i].addedNodes.length > 0) || muts[i].type === "attributes") {
                  scheduleVideoSync();
                  break;
                }
              }
            });
            const attachVMO = function() {
              if (document.body) {
                vmo.observe(document.body, {
                  childList: true,
                  subtree: true,
                  attributes: true,
                  attributeFilter: ["controls", "src", "style", "class", "hidden"]
                });
              }
            };
            if (document.body) attachVMO();
            else document.addEventListener("DOMContentLoaded", attachVMO, { once: true, passive: true });
          } catch (_) {}
        })();

        let lastPtrX = -1, lastPtrY = -1;
        let lastCanUp = false, lastCanDown = false, lastCanInnerLeft = false, lastCanInnerRight = false;
        let lastInnerCheck = 0;

        function computeInnerScrollState(targetEl) {
          let el = targetEl;
          if (!el && lastPtrX >= 0 && lastPtrY >= 0 && document.elementFromPoint) {
            try { el = document.elementFromPoint(lastPtrX, lastPtrY); } catch (_) { el = null; }
          }
          let canUp = false;
          let canDown = false;
          let canLeft = false;
          let canRight = false;
          const root = document.scrollingElement || document.documentElement;
          while (el && el !== root && el !== document.body && el !== document.documentElement) {
            if (el.nodeType === 1) {
              const sh = el.scrollHeight || 0;
              const ch = el.clientHeight || 0;
              const sw = el.scrollWidth || 0;
              const cw = el.clientWidth || 0;
              if (sh > ch + 2 || sw > cw + 2) {
                const cs = window.getComputedStyle ? window.getComputedStyle(el) : null;
                if (sh > ch + 2 && cs) {
                  const oy = cs.overflowY || '';
                  if (oy === 'auto' || oy === 'scroll' || oy === 'overlay') {
                    if (el.scrollTop > 0.5) canUp = true;
                    if (el.scrollTop + ch < sh - 0.5) canDown = true;
                  }
                }
                if (sw > cw + 2 && cs) {
                  const ox = cs.overflowX || '';
                  if (ox === 'auto' || ox === 'scroll' || ox === 'overlay') {
                    if (el.scrollLeft > 0.5) canLeft = true;
                    if (el.scrollLeft + cw < sw - 0.5) canRight = true;
                  }
                }
                if (canUp && canDown && canLeft && canRight) break;
              }
            }
            el = el.parentElement;
          }
          lastCanUp = canUp;
          lastCanDown = canDown;
          lastCanInnerLeft = canLeft;
          lastCanInnerRight = canRight;
        }

        let lastY = -1, lastH = -1, lastVH = -1, lastS = -1, lastPinch = false;
        let pageScroller = null;
        function maybeAdoptPageScroller(el) {
          try {
            if (!el || el.nodeType !== 1) return;
            const se = document.scrollingElement || document.documentElement;
            if (el === se) return;
            const r = el.getBoundingClientRect();
            const vw = window.innerWidth || 1;
            const vh = window.innerHeight || 1;
            if (r.top <= 2 && r.width >= vw * 0.6 && r.height >= vh * 0.6 && el.scrollHeight > el.clientHeight + 4) {
              pageScroller = el;
            }
          } catch (_) {}
        }
        let lastSentCanUp = false, lastSentCanDown = false, lastSentCanLeft = false, lastSentCanRight = false;
        let pinchEndTimer = null;

        function emitMetrics(isPinching, force) {
          const se = document.scrollingElement || document.documentElement || document.body;
          const vv = window.visualViewport;
          const vvScale = (vv && vv.scale) ? vv.scale : 1.0;
          // Pinch-zoom pans the visual viewport without changing scrollY; count that pan too, or a zoomed page
          // that has slid under the toolbar is reported as "at the top" and gets no scroll-edge treatment.
          const vvPan = (vv && vvScale > 1.001)
            ? Math.max(0, vv.offsetTop || 0) : 0;
          // Pages that scroll <body> or a full-width app container keep window.scrollY at 0; use that
          // scroller's offset so the toolbar knows the content has moved under it.
          let pageScrollerTop = 0;
          if (pageScroller && pageScroller.isConnected) {
            pageScrollerTop = pageScroller.scrollTop || 0;
          } else {
            pageScroller = null;
          }
          const y = Math.max(0, Math.max(window.scrollY || (se ? se.scrollTop : 0) || 0, pageScrollerTop) + vvPan);
          const vh = Math.max(1, window.innerHeight || (se ? se.clientHeight : 0) || 1);
          const h = Math.max(vh, (se ? se.scrollHeight : 0) || (document.body ? document.body.scrollHeight : 0) || vh);
          const s = Math.round(vvScale * 1000) / 1000;

          // Horizontal scroll & pinch-zoom visualViewport X-bounds (prevents Back/Forward swipe while panning).
          const layoutW = Math.max(1, window.innerWidth || (se ? se.clientWidth : 0) || 1);
          const docScrollLeft = Math.max(0, window.scrollX || (se ? se.scrollLeft : 0) || 0);
          const docScrollWidth = Math.max(layoutW, (se ? se.scrollWidth : 0) || (document.body ? document.body.scrollWidth : 0) || layoutW);
          const docMaxLeft = Math.max(0, docScrollWidth - layoutW);
          const vvOffsetLeft = (vv && vvScale > 1.001) ? Math.max(0, vv.offsetLeft || 0) : 0;
          const vvWidth = (vv && vv.width) ? vv.width : layoutW;
          const vvMaxLeft = (vv && vvScale > 1.001) ? Math.max(0, layoutW - vvWidth) : 0;
          const canLeft = lastCanInnerLeft || docScrollLeft > 1.0 || vvOffsetLeft > 1.0;
          const canRight = lastCanInnerRight || (docScrollLeft < docMaxLeft - 1.0) || (vvScale > 1.001 && vvOffsetLeft < vvMaxLeft - 1.0);
          const consumesPinch = lastSurfaceConsumesPinch || ((performance.now() - lastCtrlWheelPreventedAt) < 8000);

          if (!force &&
              Math.abs(y - lastY) < 0.25 &&
              Math.abs(h - lastH) < 0.5 &&
              Math.abs(vh - lastVH) < 0.5 &&
              Math.abs(s - lastS) < 0.0005 &&
              !!isPinching === lastPinch &&
              lastCanUp === lastSentCanUp &&
              lastCanDown === lastSentCanDown &&
              canLeft === lastSentCanLeft &&
              canRight === lastSentCanRight &&
              consumesPinch === lastSentConsumesPinch) {
            return;
          }
          lastY = y; lastH = h; lastVH = vh; lastS = s; lastPinch = !!isPinching;
          lastSentCanUp = lastCanUp; lastSentCanDown = lastCanDown;
          lastSentCanLeft = canLeft; lastSentCanRight = canRight;
          lastSentConsumesPinch = consumesPinch;
          reportMetrics(y, h, s, !!isPinching, vh, lastCanUp, lastCanDown, canLeft, canRight, consumesPinch);
        }

        let lastCtrlWheelPreventedAt = -1e9;
        let lastSurfaceConsumesPinch = false;
        let lastSentConsumesPinch = false;
        function updatePinchSurface(target) {
          let el = (target && target.nodeType === 1) ? target : null;
          let consumes = false;
          let hops = 0;
          while (el && hops < 12) {
            const tag = el.tagName;
            if (tag === 'CANVAS' || tag === 'PDF-VIEWER' || (tag === 'EMBED' && (el.type || '').indexOf('pdf') !== -1)) {
              const r = el.getBoundingClientRect();
              if (r.width >= 200 && r.height >= 160) { consumes = true; break; }
            }
            const cs = window.getComputedStyle(el);
            if (cs && cs.touchAction === 'none') {
              const r = el.getBoundingClientRect();
              if (r.width >= 200 && r.height >= 160) { consumes = true; break; }
            }
            el = el.parentElement;
            hops++;
          }
          lastSurfaceConsumesPinch = consumes;
        }

        window.addEventListener('pointermove', function(e) {
          lastPtrX = e.clientX;
          lastPtrY = e.clientY;
          const now = performance.now();
          if (now - lastInnerCheck > 40) {
            lastInnerCheck = now;
            computeInnerScrollState(e.target);
            updatePinchSurface(e.target);
            emitMetrics(false, false);
          }
        }, { passive: true, capture: true });

        window.addEventListener('wheel', function(e) {
          lastPtrX = e.clientX;
          lastPtrY = e.clientY;
          computeInnerScrollState(e.target);
          updatePinchSurface(e.target);
          emitMetrics(false, false);
        }, { passive: true, capture: true });

        window.addEventListener('wheel', function(e) {
          if (e.ctrlKey && e.defaultPrevented) {
            lastCtrlWheelPreventedAt = performance.now();
            emitMetrics(false, false);
          }
        }, { passive: true, capture: false });

        if (window.visualViewport) {
          window.visualViewport.addEventListener('scroll', function() { emitMetrics(false, false); }, { passive: true });
        }

        window.addEventListener('scroll', function(e) {
          if (e.target && e.target !== document && e.target !== window) {
            maybeAdoptPageScroller(e.target);
            computeInnerScrollState(e.target);
          }
          emitMetrics(false, false);
        }, { passive: true, capture: true });

        window.addEventListener('resize', function() {
          emitMetrics(false, false);
        }, { passive: true });

        if (window.visualViewport) {
          window.visualViewport.addEventListener('resize', function() {
            const s = window.visualViewport.scale || 1.0;
            const pinching = Math.abs(s - lastS) > 0.001;
            emitMetrics(pinching, false);
            if (pinching) {
              clearTimeout(pinchEndTimer);
              pinchEndTimer = setTimeout(function() { emitMetrics(false, true); }, 140);
            }
          }, { passive: true });
          window.visualViewport.addEventListener('scroll', function() {
            emitMetrics(false, false);
          }, { passive: true });
        }

        window.addEventListener('load', function() {
          disableRootBlinkOverscroll();
          emitMetrics(false, true);
        }, { passive: true });
        setTimeout(function() { emitMetrics(false, true); }, 60);

        // Explicit visual-readiness signals for zero-flicker navigation handoff (sx.nav_ready v2):
        // 1. BFCache restore (`pageshow` with `event.persisted === true`) & Speculation Rules prerender
        //    activation (`prerenderingchange` / `activationStart > 0`) fire on first compositor frame.
        // 2. Cross-Document View Transitions (`pagereveal` with `event.viewTransition`) align with
        //    `viewTransition.ready` (120ms cap) so native CSS dissolves start cleanly as the shell veil lifts.
        // 3. Fresh document loads wait for `<head>` render-blocking stylesheets (180ms cap), cached web
        //    fonts (60ms cap), and First Contentful Paint / non-empty layout inside a 380ms ceiling.
        if (typeof reportNavReady === 'function') {
          let reportedReady = false;
          function emitNavReadyOnce(instantFastPath) {
            if (reportedReady) return;
            if (document.prerendering) return;
            reportedReady = true;
            // Report the page's top colour first so the toolbar retints in the same frame the page is revealed.
            try { if (typeof sxTopInset.probeNow === 'function') sxTopInset.probeNow(); } catch (_) {}
            try { reportNavReady(!!instantFastPath); } catch (_) {}
          }

          function wasPrerenderActivated() {
            try {
              const nav = performance && performance.getEntriesByType
                ? performance.getEntriesByType('navigation')[0]
                : null;
              return !!(nav && nav.activationStart > 0);
            } catch (_) {
              return false;
            }
          }

          // Ready means the new document's first contentful paint is on screen: paint-timing entries are only
          // reported after that frame was presented. Safarium keeps the previous page frozen over the web view until
          // then (like Safari), so this must not fire early. A page that never paints anything contentful is
          // released shortly after load, and everything after 2.5 s.
          let freshPipelineStarted = false;
          let freshLoadTimer = 0;
          let freshCeilingTimer = 0;
          let freshObs = null;
          function cancelFreshReadyTimers() {
            if (freshObs) { try { freshObs.disconnect(); } catch (_) {} freshObs = null; }
            if (freshLoadTimer) { clearTimeout(freshLoadTimer); freshLoadTimer = 0; }
            if (freshCeilingTimer) { clearTimeout(freshCeilingTimer); freshCeilingTimer = 0; }
          }
          function startFreshReadyPipeline() {
            if (reportedReady || freshPipelineStarted || document.prerendering) return;
            freshPipelineStarted = true;
            if (wasPrerenderActivated()) {
              requestAnimationFrame(function() { emitNavReadyOnce(true); });
              return;
            }
            const done = function() {
              cancelFreshReadyTimers();
              emitNavReadyOnce(false);
            };
            try {
              if (performance.getEntriesByName('first-contentful-paint').length > 0) { done(); return; }
              freshObs = new PerformanceObserver(function(list) {
                const entries = list.getEntries();
                for (let i = 0; i < entries.length; i++) {
                  if (entries[i].name === 'first-contentful-paint') { done(); return; }
                }
              });
              freshObs.observe({ type: 'paint', buffered: true });
            } catch (_) {}
            if (document.readyState === 'complete') {
              freshLoadTimer = setTimeout(done, 250);
            } else {
              window.addEventListener('load', function() {
                if (!reportedReady && !freshLoadTimer) {
                  freshLoadTimer = setTimeout(done, 250);
                }
              }, { once: true, passive: true });
            }
            freshCeilingTimer = setTimeout(done, 2500);
          }

          if (document.prerendering) {
            document.addEventListener('prerenderingchange', function() {
              requestAnimationFrame(function() { emitNavReadyOnce(true); });
            }, { once: true });
          }

          window.addEventListener('pagereveal', function(ev) {
            if (reportedReady || document.prerendering) return;
            if (ev && ev.viewTransition && ev.viewTransition.ready &&
                typeof ev.viewTransition.ready.then === 'function') {
              let vtDone = false;
              const finishVT = function() {
                if (vtDone) return;
                vtDone = true;
                requestAnimationFrame(function() { emitNavReadyOnce(true); });
              };
              ev.viewTransition.ready.then(finishVT, finishVT);
              setTimeout(finishVT, 120);
            }
          }, { passive: true });

          let lastBFCachePageshowAt = -1e9;
          let lastTraverseSentAt = -1e9;
          function notifyTraverseOnce() {
            if (typeof reportNavTraverse !== 'function') return;
            const now = performance.now();
            if (now - lastTraverseSentAt < 120) return;
            lastTraverseSentAt = now;
            try { reportNavTraverse(); } catch (_) {}
          }
          try {
            if (window.navigation && typeof window.navigation.addEventListener === 'function') {
              window.navigation.addEventListener('navigate', function(ev) {
                if (!ev || ev.defaultPrevented || ev.hashChange) return;
                if (ev.navigationType === 'traverse') {
                  notifyTraverseOnce();
                }
              }, { passive: true });
            }
          } catch (_) {}
          window.addEventListener('pagehide', function(ev) {
            if (ev && ev.persisted) {
              notifyTraverseOnce();
            }
          }, { passive: true });

          window.addEventListener('pageshow', function(ev) {
            if (ev && ev.persisted) {
              cancelFreshReadyTimers();
              lastBFCachePageshowAt = performance.now();
              reportedReady = false;
              try { if (typeof sxTopInset.forgetReported === 'function') sxTopInset.forgetReported(); } catch (_) {}
              // Wait two animation frames so the thawed BFCache document has painted and
              // submitted its composited IOSurface to Viz before lifting the freeze overlay.
              requestAnimationFrame(function() {
                requestAnimationFrame(function() {
                  emitNavReadyOnce(true);
                });
              });
            } else {
              startFreshReadyPipeline();
            }
          }, { passive: true });

          startFreshReadyPipeline();

          // A tab brought back to the front repaints from scratch (Chromium dropped its surface while hidden);
          // Safarium covers it until this reports that a fresh frame is on screen.
          document.addEventListener('visibilitychange', function() {
            if (document.visibilityState !== 'visible' || document.prerendering) return;
            // BFCache pageshow fires right alongside visibilitychange and already schedules a double-rAF ready.
            if (performance.now() - lastBFCachePageshowAt < 250) return;
            requestAnimationFrame(function() {
              requestAnimationFrame(function() {
                reportedReady = false;
                emitNavReadyOnce(true);
              });
            });
          }, { passive: true });
        }

        // 3b. Touchpad-grade Space / Shift+Space smooth scrolling:
        //     Runs in bubble phase so page handlers (YouTube play/pause, games, modals) that call
        //     preventDefault() or focus editable/interactive controls always take precedence.
        (function installSpaceTouchpadScroll() {
          if (typeof spaceScroll !== 'function') return;
          const INTERACTIVE_TAGS = new Set([
            'INPUT', 'TEXTAREA', 'SELECT', 'OPTION', 'BUTTON', 'SUMMARY', 'A', 'VIDEO', 'AUDIO'
          ]);
          const INTERACTIVE_ROLES = new Set([
            'textbox', 'searchbox', 'combobox', 'listbox', 'option', 'button', 'link',
            'checkbox', 'radio', 'switch', 'menuitem', 'menuitemcheckbox', 'menuitemradio',
            'slider', 'spinbutton', 'tab', 'treeitem'
          ]);
          function deepActiveElement() {
            let el = document.activeElement;
            try {
              while (el && el.shadowRoot && el.shadowRoot.activeElement) {
                el = el.shadowRoot.activeElement;
              }
            } catch (_) {}
            return el;
          }
          function isInteractiveOrEditable(el) {
            if (!el || el === document.body || el === document.documentElement) return false;
            if (el.isContentEditable) return true;
            const tag = (el.tagName || '').toUpperCase();
            if (INTERACTIVE_TAGS.has(tag)) return true;
            const role = (el.getAttribute && el.getAttribute('role') || '').toLowerCase();
            if (role && INTERACTIVE_ROLES.has(role)) return true;
            if (el.closest) {
              try {
                if (el.closest('[contenteditable="true"], [contenteditable=""], [role="textbox"], [role="searchbox"], input, textarea, select')) {
                  return true;
                }
              } catch (_) {}
            }
            return false;
          }
          window.addEventListener('keydown', function(e) {
            if (!e || e.defaultPrevented) return;
            if (e.code !== 'Space' && e.key !== ' ') return;
            if (e.metaKey || e.ctrlKey || e.altKey) return;
            if (isInteractiveOrEditable(deepActiveElement()) || isInteractiveOrEditable(e.target)) return;
            e.preventDefault();
            emitMetrics(false, true);
            spaceScroll(e.shiftKey ? 1 : -1, !!e.repeat);
          }, false);
        })();

        // 4. Chrome Web Store 1-click native installer (ONLY on chromewebstore.google.com).
        let onCwsState = function() {};
        const host = (window.location && window.location.hostname) || '';
        const isCws = host === 'chromewebstore.google.com' ||
          (host === 'chrome.google.com' && (window.location.pathname || '').startsWith('/webstore'));
        if (isCws) {
          const EXT_RE = /\/detail\/(?:[^/]+\/)?([a-p]{32})(?:\/|$|\?)/i;
          const CWS_BTN_RE = /^(add to chrome|available on chrome|switch to chrome|remove from chrome|add to safarium|remove from safarium|installing…|installing\.\.\.|removing…|removing\.\.\.)$/i;
          let curId = '';
          let st = { installed: false, busy: false, busyAction: '', busySince: 0, error: '' };
          let lastBusyPoll = 0;
          function readId() {
            const m = EXT_RE.exec(window.location.pathname || '');
            return m ? m[1].toLowerCase() : '';
          }
          function triggerCws() {
            if (!curId || st.busy) return;
            st.busy = true;
            st.busyAction = st.installed ? 'uninstall' : 'install';
            st.busySince = Date.now();
            lastBusyPoll = Date.now();
            st.error = '';
            patchButtons();
            cwsAction(st.busyAction, curId);
          }
          function setButtonLabel(b, desired) {
            const walker = document.createTreeWalker(b, NodeFilter.SHOW_TEXT);
            let done = false, node;
            while ((node = walker.nextNode())) {
              if (node.nodeValue && node.nodeValue.trim().length > 2) {
                if (node.nodeValue !== desired) node.nodeValue = desired;
                done = true;
                break;
              }
            }
            if (!done && b.textContent !== desired) b.textContent = desired;
          }
          function patchButtons() {
            if (!curId) return;
            const desired = st.busy
              ? (st.busyAction === 'uninstall' ? 'Removing…' : 'Installing…')
              : (st.installed ? 'Remove from Safarium' : 'Add to Safarium');
            const btns = document.querySelectorAll('button, [role="button"], a');
            for (const b of btns) {
              const txt = (b.textContent || '').trim();
              const isBound = b.dataset && b.dataset.sxCwsBound === '1';
              if (isBound || CWS_BTN_RE.test(txt)) {
                if (b.hasAttribute('disabled')) b.removeAttribute('disabled');
                if (b.getAttribute('aria-disabled') !== 'false') b.setAttribute('aria-disabled', 'false');
                if (b.style.pointerEvents !== 'auto') b.style.pointerEvents = 'auto';
                if (b.style.cursor !== 'pointer') b.style.cursor = 'pointer';
                if (b.style.opacity !== '1') b.style.opacity = '1';
                if (txt !== desired) {
                  setButtonLabel(b, desired);
                }
                if (!isBound) {
                  b.dataset.sxCwsBound = '1';
                  b.addEventListener('click', function(ev) {
                    ev.preventDefault();
                    ev.stopImmediatePropagation();
                    triggerCws();
                  }, true);
                }
              }
            }
          }
          onCwsState = function(storeId, installed, busy, err) {
            if (storeId && curId && storeId.toLowerCase() !== curId) return;
            const nextInstalled = !!installed;
            // If we are polling during an active install/uninstall, keep busy until
            // the expected state flips OR the explicit completion arrives (busy=false & state matched or error).
            if (st.busy && !busy) {
              st.busy = false;
              st.busyAction = '';
            }
            st.installed = nextInstalled;
            st.error = err || '';
            patchButtons();
          };
          setInterval(function() {
            const nextId = readId();
            if (nextId !== curId) {
              curId = nextId;
              st = { installed: false, busy: false, busyAction: '', busySince: 0, error: '' };
              if (curId) cwsAction('query', curId);
            }
            if (curId) {
              const now = Date.now();
              if (st.busy && now - st.busySince > 35000) {
                st.busy = false;
                st.busyAction = '';
                cwsAction('query', curId);
              } else if (st.busy && now - lastBusyPoll > 1500) {
                lastBusyPoll = now;
                cwsAction('query', curId);
              }
              patchButtons();
            }
          }, 400);
        }


        return [onScrollPhase, settle, onCwsState];
      })
    )JS";

    if (context->Eval(kInstallerJS, CefString(), 0, installer, exception) &&
        installer && installer->IsFunction()) {
      CefRefPtr<CefV8Handler> handler = new SXTelemetryV8Handler(browser, frame);
      CefV8ValueList args;
      args.push_back(CefV8Value::CreateFunction("reportMetrics", handler));
      args.push_back(CefV8Value::CreateFunction("reportOverscroll", handler));
      args.push_back(CefV8Value::CreateFunction("triggerPullRefresh", handler));
      args.push_back(CefV8Value::CreateFunction("cwsAction", handler));
      args.push_back(CefV8Value::CreateFunction("spaceScroll", handler));
      args.push_back(CefV8Value::CreateFunction("reportFixedHeader", handler));
      args.push_back(CefV8Value::CreateFunction("reportPageBg", handler));
      args.push_back(CefV8Value::CreateFunction("reportNativeVideo", handler));
      args.push_back(CefV8Value::CreateFunction("reportAuthEvent", handler));
      CefRefPtr<CefCommandLine> cmdLine = CefCommandLine::GetGlobalCommandLine();
      std::string proxyPort = cmdLine ? cmdLine->GetSwitchValue("sx-media-proxy-port").ToString() : "";
      std::string proxyToken = cmdLine ? cmdLine->GetSwitchValue("sx-media-proxy-token").ToString() : "";
      args.push_back(CefV8Value::CreateString(proxyPort));
      args.push_back(CefV8Value::CreateString(proxyToken));
      args.push_back(CefV8Value::CreateFunction("reportNavReady", handler));
      {
        int topInset = 0;
        auto pit = privacy_configs_.find(browser->GetIdentifier());
        if (pit != privacy_configs_.end()) topInset = pit->second.top_inset;
        args.push_back(CefV8Value::CreateInt(topInset));
      }
      args.push_back(CefV8Value::CreateFunction("reportNavTraverse", handler));
      CefRefPtr<CefV8Value> ret = installer->ExecuteFunction(nullptr, args);
      if (ret && ret->IsArray() && ret->GetArrayLength() >= 3) {
        SXFrameHooks hooks;
        hooks.context = context;
        hooks.onScrollPhaseFn = ret->GetValue(0);
        hooks.onResetOverscrollFn = ret->GetValue(1);
        hooks.onCwsStateFn = ret->GetValue(2);
        frame_hooks_[browser->GetIdentifier()] = std::move(hooks);
      }

      if (frameURL.rfind("chrome-extension://", 0) != 0 && frameURL.rfind("chrome://", 0) != 0 && frameURL.rfind("devtools://", 0) != 0) {
        CefRefPtr<CefV8Value> authInstaller;
        CefRefPtr<CefV8Exception> authEx;
        if (context->Eval(kUnifiedSafariAuthBridgeJS, CefString(), 0, authInstaller, authEx) &&
            authInstaller && authInstaller->IsFunction()) {
          CefV8ValueList authArgs;
          authArgs.push_back(CefV8Value::CreateFunction("reportAuthEvent", handler));
          authInstaller->ExecuteFunction(nullptr, authArgs);
        }
      }
    }

    context->Exit();
  }

  void OnContextReleased(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         CefRefPtr<CefV8Context> context) override {
    if (!browser || !frame || !frame->IsMain()) {
      return;
    }
    auto it = frame_hooks_.find(browser->GetIdentifier());
    if (it != frame_hooks_.end() && it->second.context &&
        it->second.context->IsSame(context)) {
      frame_hooks_.erase(it);
    }
  }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    if (!browser || !message) {
      return false;
    }
    const std::string name = message->GetName().ToString();
    if (name == "sx.top_inset") {
      CefRefPtr<CefListValue> args = message->GetArgumentList();
      if (args && args->GetSize() >= 1) {
        int inset = std::max(0, args->GetInt(0));
        auto pit = privacy_configs_.find(browser->GetIdentifier());
        if (pit != privacy_configs_.end()) pit->second.top_inset = inset;
        CefRefPtr<CefFrame> main = browser->GetMainFrame();
        if (main) {
          main->ExecuteJavaScript("window.__sxSetTopInset && window.__sxSetTopInset(" + std::to_string(inset) + ");",
                                  CefString(), 0);
        }
      }
      return true;
    }
    if (name == "sx_privacy_config_update") {
      CefRefPtr<CefListValue> args = message->GetArgumentList();
      if (args && args->GetSize() >= 1 && args->GetType(0) == VTYPE_DICTIONARY) {
        CefRefPtr<CefDictionaryValue> dict = args->GetDictionary(0);
        if (dict) {
          int bid = browser->GetIdentifier();
          auto pit = privacy_configs_.find(bid);
          if (pit == privacy_configs_.end()) {
            SXPrivacyRenderConfig initial = SXLaunchPrivacyConfig();
            initial.ref_count = 1;
            pit = privacy_configs_.emplace(bid, std::move(initial)).first;
          }
          SXPrivacyRenderConfig& pcfg = pit->second;
          if (dict->HasKey("is_private") && dict->GetType("is_private") == VTYPE_BOOL) {
            pcfg.is_private = dict->GetBool("is_private");
          }
          if (dict->HasKey("session_salt") && dict->GetType("session_salt") == VTYPE_STRING) {
            std::string s = dict->GetString("session_salt").ToString();
            if (!s.empty()) pcfg.session_salt = std::move(s);
          }
          if (pcfg.session_salt.empty()) {
            pcfg.session_salt = SXDefaultSessionSalt();
          }
          if (dict->HasKey("fp_enabled") && dict->GetType("fp_enabled") == VTYPE_BOOL) {
            pcfg.fp_enabled = dict->GetBool("fp_enabled");
          }
          if (dict->HasKey("fp_scope") && dict->GetType("fp_scope") == VTYPE_INT) {
            pcfg.fp_scope = dict->GetInt("fp_scope");
          }
          if (dict->HasKey("gpc_enabled") && dict->GetType("gpc_enabled") == VTYPE_BOOL) {
            pcfg.gpc_enabled = dict->GetBool("gpc_enabled");
          }
          if (dict->HasKey("level") && dict->GetType("level") == VTYPE_INT) {
            pcfg.level = dict->GetInt("level");
          }
          if (dict->HasKey("cb_default") && dict->GetType("cb_default") == VTYPE_INT) {
            pcfg.cb_default = dict->GetInt("cb_default");
          }
          if (dict->HasKey("mic_default") && dict->GetType("mic_default") == VTYPE_INT) {
            pcfg.mic_default = dict->GetInt("mic_default");
          }
          if (dict->HasKey("cam_default") && dict->GetType("cam_default") == VTYPE_INT) {
            pcfg.cam_default = dict->GetInt("cam_default");
          }
          auto loadHostList = [&](const char* key, std::unordered_set<std::string>& dest) {
            if (dict->HasKey(key) && dict->GetType(key) == VTYPE_LIST) {
              dest.clear();
              CefRefPtr<CefListValue> list = dict->GetList(key);
              if (list) {
                size_t count = list->GetSize();
                for (size_t i = 0; i < count; ++i) {
                  if (list->GetType(i) == VTYPE_STRING) {
                    std::string h = SXNormalizeHost(list->GetString(i).ToString());
                    if (!h.empty()) dest.insert(std::move(h));
                  }
                }
              }
            }
          };
          loadHostList("disabled_hosts", pcfg.disabled_hosts);
          loadHostList("enabled_hosts", pcfg.enabled_hosts);
          loadHostList("mic_allowed_hosts", pcfg.mic_allowed_hosts);
          loadHostList("cam_allowed_hosts", pcfg.cam_allowed_hosts);
        }
      }
      return true;
    }
    if (name != "sx.scroll_phase" && name != "sx.reset_overscroll" &&
        name != "sx.cws_state") {
      return false;
    }
    auto it = frame_hooks_.find(browser->GetIdentifier());
    if (it == frame_hooks_.end() || !it->second.context) {
      return true;
    }
    CefRefPtr<CefV8Context> ctx = it->second.context;
    if (!ctx->Enter()) {
      return true;
    }
    if (name == "sx.scroll_phase" && it->second.onScrollPhaseFn &&
        it->second.onScrollPhaseFn->IsFunction()) {
      CefRefPtr<CefListValue> args = message->GetArgumentList();
      if (args && args->GetSize() >= 1) {
        CefV8ValueList v8Args;
        v8Args.push_back(CefV8Value::CreateString(args->GetString(0)));
        it->second.onScrollPhaseFn->ExecuteFunction(nullptr, v8Args);
      }
    } else if (name == "sx.reset_overscroll" && it->second.onResetOverscrollFn &&
               it->second.onResetOverscrollFn->IsFunction()) {
      CefV8ValueList v8Args;
      it->second.onResetOverscrollFn->ExecuteFunction(nullptr, v8Args);
    } else if (name == "sx.cws_state" && it->second.onCwsStateFn &&
               it->second.onCwsStateFn->IsFunction()) {
      CefRefPtr<CefListValue> args = message->GetArgumentList();
      if (args && args->GetSize() >= 4) {
        CefV8ValueList v8Args;
        v8Args.push_back(CefV8Value::CreateString(args->GetString(0)));
        v8Args.push_back(CefV8Value::CreateBool(args->GetBool(1)));
        v8Args.push_back(CefV8Value::CreateBool(args->GetBool(2)));
        v8Args.push_back(CefV8Value::CreateString(args->GetString(3)));
        it->second.onCwsStateFn->ExecuteFunction(nullptr, v8Args);
      }
    }
    ctx->Exit();
    return true;
  }

 private:
  void InstallPrivacyProtectionsIfNeeded(CefRefPtr<CefBrowser> browser,
                                         CefRefPtr<CefFrame> frame,
                                         CefRefPtr<CefV8Context> context) {
    if (!browser || !frame || !context) return;
    const int bid = browser->GetIdentifier();
    if (popup_contexts_.find(bid) != popup_contexts_.end()) {
      return;
    }

    const std::string frameURL = frame->GetURL().ToString();
    if (SXIsInternalScheme(frameURL)) {
      return;
    }

    CefRefPtr<CefFrame> mainFrame = browser->GetMainFrame();
    const std::string topURL =
        (frame->IsMain() || !mainFrame) ? frameURL : mainFrame->GetURL().ToString();
    if (SXIsInternalScheme(topURL)) {
      return;
    }

    if (frame->IsMain()) {
      if (frameURL.empty() || SXStartsWithCaseInsensitive(frameURL, "about:") ||
          !SXIsHttpScheme(frameURL)) {
        return;
      }
    } else {
      if (!SXIsHttpScheme(topURL)) {
        return;
      }
      if (!SXIsHttpScheme(frameURL) &&
          !frameURL.empty() &&
          !SXStartsWithCaseInsensitive(frameURL, "about:blank") &&
          !SXStartsWithCaseInsensitive(frameURL, "about:srcdoc") &&
          !SXStartsWithCaseInsensitive(frameURL, "blob:") &&
          !SXStartsWithCaseInsensitive(frameURL, "data:")) {
        return;
      }
    }

    SXPrivacyRenderConfig cfg = SXLaunchPrivacyConfig();
    auto cfgIt = privacy_configs_.find(bid);
    if (cfgIt != privacy_configs_.end()) {
      cfg = cfgIt->second;
    }
    if (cfg.session_salt.empty()) {
      cfg.session_salt = SXDefaultSessionSalt();
    }

    const std::string topHost = SXExtractHostFromURL(topURL);
    const std::string frameHost = SXExtractHostFromURL(frameURL);
    bool siteProtectionsActive = (cfg.cb_default == 0);
    if (!topHost.empty()) {
      if (cfg.disabled_hosts.find(topHost) != cfg.disabled_hosts.end()) {
        siteProtectionsActive = false;
      } else if (cfg.enabled_hosts.find(topHost) != cfg.enabled_hosts.end()) {
        siteProtectionsActive = true;
      }
    }
    const bool applyGpc = cfg.gpc_enabled;
    const bool applyFp =
        cfg.fp_enabled && (cfg.fp_scope == 1 || cfg.is_private) && siteProtectionsActive;
    if (!applyGpc && !applyFp) {
      return;
    }

    std::string navNonce;
    if (frame->IsMain()) {
      navNonce = SXGenerateNavNonce();
      main_frame_nav_nonces_[bid] = navNonce;
    } else {
      auto nit = main_frame_nav_nonces_.find(bid);
      if (nit != main_frame_nav_nonces_.end() && !nit->second.empty()) {
        navNonce = nit->second;
      } else {
        navNonce = SXGenerateNavNonce();
        main_frame_nav_nonces_[bid] = navNonce;
      }
    }

    const std::string siteHost = !topHost.empty() ? topHost : (!frameHost.empty() ? frameHost : "local");
    const std::string siteReg = SXRegistrableDomain(siteHost);
    const std::string siteKey = !siteReg.empty() ? siteReg : siteHost;
    const std::string siteSeedStr = cfg.session_salt + "|" + siteKey;
    const std::string docSeedStr = siteSeedStr + "|" + navNonce;
    const bool mediaAllowedAudio =
        (cfg.mic_default == 2) || (!topHost.empty() && cfg.mic_allowed_hosts.count(topHost) > 0);
    const bool mediaAllowedVideo =
        (cfg.cam_default == 2) || (!topHost.empty() && cfg.cam_allowed_hosts.count(topHost) > 0);

    static const char* const kPrivacyJS = R"JS(
      (function(applyGpc, applyFp, fpLevel, siteSeedStr, docSeedStr, pageHost, frameHost, mediaAllowedAudio, mediaAllowedVideo, reportFpEvent) {
        'use strict';

        // --- Deterministic PRNG helpers ---
        function hashSeed32(str) {
          let h = 0x811c9dc5;
          for (let i = 0; i < str.length; i++) {
            h ^= str.charCodeAt(i);
            h = Math.imul(h, 0x01000193);
          }
          h ^= h >>> 16;
          h = Math.imul(h, 0x85ebca6b);
          h ^= h >>> 13;
          h = Math.imul(h, 0xc2b2ae35);
          h ^= h >>> 16;
          return (h >>> 0) || 0x9e3779b9;
        }

        function mulberry32(seed) {
          let a = seed >>> 0;
          return function() {
            a = (a + 0x6D2B79F5) >>> 0;
            let t = Math.imul(a ^ (a >>> 15), 1 | a);
            t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
            return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
          };
        }

        const siteSeed = hashSeed32(siteSeedStr || 'default');
        const docSeed = hashSeed32(docSeedStr || siteSeedStr || 'default');

        // Shared across parent document & all same-origin iframe realms.
        const reportedApis = new Set();
        function reportFp(api) {
          if (typeof reportFpEvent !== 'function') return;
          if (reportedApis.has(api)) return;
          reportedApis.add(api);
          try {
            reportFpEvent(JSON.stringify({
              api: api,
              pageHost: pageHost || '',
              frameHost: frameHost || ''
            }));
          } catch (_) {}
        }

        const mediaGrantState = {
          audio: !!mediaAllowedAudio,
          video: !!mediaAllowedVideo
        };

        const patchedRealms = new WeakSet();
        // Single shared WeakMap across top window and all patched same-origin iframe realms
        // so cross-realm Function.prototype.toString.call(...) always sees [native code].
        const nativeStrings = new WeakMap();

        function farblePixels(data, width, height) {
          const total = (width | 0) * (height | 0);
          if (!data || total < 16 || data.length < total * 4) return false;
          const prng = mulberry32(
            (docSeed ^ Math.imul(width | 0, 0x9e3779b1) ^ Math.imul(height | 0, 0x85ebca6b)) >>> 0
          );
          const targetNudges = Math.min(8, Math.max(2, total >> 8));
          let nudged = 0;
          const visited = new Set();
          const maxProbes = Math.min(total, 128);
          for (let i = 0; i < maxProbes && nudged < targetNudges; i++) {
            const px = Math.floor(prng() * total);
            if (visited.has(px)) continue;
            visited.add(px);
            const off = px * 4;
            if (data[off + 3] > 0) {
              const ch = Math.floor(prng() * 3);
              const dir = prng() < 0.5 ? -1 : 1;
              const v = data[off + ch];
              data[off + ch] = (v + dir >= 0 && v + dir <= 255) ? (v + dir) : (v - dir);
              nudged++;
            }
          }
          if (nudged === 0) {
            const stride = Math.max(1, Math.floor(total / 128));
            const start = Math.floor(prng() * stride);
            for (let px = start; px < total && nudged < targetNudges; px += stride) {
              const off = px * 4;
              if (data[off + 3] > 0) {
                const ch = Math.floor(prng() * 3);
                const dir = prng() < 0.5 ? -1 : 1;
                const v = data[off + ch];
                data[off + ch] = (v + dir >= 0 && v + dir <= 255) ? (v + dir) : (v - dir);
                nudged++;
              }
            }
          }
          if (nudged === 0 && total <= 131072) {
            for (let px = 0; px < total && nudged < 2; px++) {
              const off = px * 4;
              if (data[off + 3] > 0) {
                const ch = Math.floor(prng() * 3);
                const dir = prng() < 0.5 ? -1 : 1;
                const v = data[off + ch];
                data[off + ch] = (v + dir >= 0 && v + dir <= 255) ? (v + dir) : (v - dir);
                nudged++;
              }
            }
          }
          return nudged > 0;
        }

        function audioDeltaAt(channelSeed, idx) {
          let h = (channelSeed ^ Math.imul(idx | 0, 0x9e3779b1)) >>> 0;
          h ^= h >>> 16;
          h = Math.imul(h, 0x85ebca6b);
          h ^= h >>> 13;
          h = Math.imul(h, 0xc2b2ae35);
          h ^= h >>> 16;
          return (((h >>> 0) / 4294967296) - 0.5) * 2e-7;
        }

        function audioChannelParams(bufLen, ch) {
          const channelSeed = (docSeed ^ Math.imul(bufLen | 0, 0x9e3779b1) ^ Math.imul((ch | 0) + 1, 0x85ebca6b)) >>> 0;
          const stride = Math.max(1, Math.min(16, (bufLen | 0) >> 4));
          const start = (channelSeed >>> 0) % stride;
          return { channelSeed, stride, start };
        }

        function hasNonZeroSamples(arr) {
          const checkStep = Math.max(1, Math.floor(arr.length / 256));
          for (let i = 0; i < arr.length; i += checkStep) {
            if (arr[i] !== 0) return true;
          }
          return false;
        }

        // Deterministic site-scoped benign plugin metadata (prevents cross-site plugin correlation
        // while keeping native PDF viewers and PluginArray WebIDL semantics 100% intact).
        const kPluginWordsA = [
          'WebKit', 'Core', 'Quartz', 'Apple', 'Document', 'Media', 'Graphic', 'Vector',
          'Standard', 'Portable', 'Universal', 'System', 'Native', 'Open', 'Modern', 'Secure',
          'Digital', 'Rich', 'Smart', 'Adaptive', 'Clean', 'Unified', 'Classic', 'Dynamic',
          'Compact', 'Trusted', 'Direct', 'Modular', 'Express', 'Quick', 'Lite', 'Pro'
        ];
        const kPluginWordsB = [
          'Document', 'Content', 'Layout', 'Format', 'Display', 'Render', 'Canvas', 'Stream',
          'Asset', 'Page', 'Print', 'Sheet', 'Frame', 'Text', 'Font', 'Vector',
          'Codec', 'Buffer', 'Surface', 'Bridge', 'Engine', 'Handler', 'Module', 'Service',
          'Viewer', 'Reader', 'Helper', 'Support', 'Runtime', 'Adapter', 'Filter', 'Loader'
        ];
        function buildSitePluginDescriptor() {
          const p = mulberry32((siteSeed ^ 0x504c5547) >>> 0);
          const w1 = kPluginWordsA[Math.floor(p() * kPluginWordsA.length)];
          const w2 = kPluginWordsB[Math.floor(p() * kPluginWordsB.length)];
          const tag = Math.floor(p() * 900 + 100);
          const name = w1 + ' ' + w2 + ' Viewer ' + tag;
          const description = w1 + ' ' + w2 + ' Document Handler';
          const filename = ('internal-' + w1 + '-' + w2 + '-' + tag).toLowerCase();
          return { name, description, filename };
        }
        const sitePluginMeta = buildSitePluginDescriptor();

        function installIntoRealm(win) {
          if (!win) return;
          let realmObject = null;
          let realmFunction = null;
          try {
            realmObject = win.Object;
            realmFunction = win.Function;
            if (!realmObject || !realmFunction) return;
            if (patchedRealms.has(realmObject)) return;
            patchedRealms.add(realmObject);
          } catch (_) {
            return;
          }

          const origFnToString = realmFunction.prototype.toString;

          function maskAsNative(fn, name, length) {
            try {
              realmObject.defineProperty(fn, 'name', {
                value: name,
                writable: false,
                enumerable: false,
                configurable: true
              });
            } catch (_) {}
            if (typeof length === 'number') {
              try {
                realmObject.defineProperty(fn, 'length', {
                  value: length,
                  writable: false,
                  enumerable: false,
                  configurable: true
                });
              } catch (_) {}
            }
            nativeStrings.set(fn, 'function ' + name + '() { [native code] }');
            return fn;
          }

          const wrappedToString = ({
            toString() {
              if (typeof this === 'function' && nativeStrings.has(this)) {
                return nativeStrings.get(this);
              }
              return origFnToString.call(this);
            }
          }).toString;
          maskAsNative(wrappedToString, 'toString', 0);

          try {
            realmObject.defineProperty(realmFunction.prototype, 'toString', {
              value: wrappedToString,
              writable: true,
              enumerable: false,
              configurable: true
            });
          } catch (_) {}

          function wrapMethod(proto, prop, impl) {
            if (!proto) return null;
            const desc = realmObject.getOwnPropertyDescriptor(proto, prop);
            if (!desc || typeof desc.value !== 'function') return null;
            const orig = desc.value;
            const wrapped = ({
              [prop]() {
                return impl.call(this, orig, arguments);
              }
            })[prop];
            maskAsNative(wrapped, prop, orig.length);
            try {
              realmObject.defineProperty(proto, prop, {
                value: wrapped,
                writable: desc.writable,
                enumerable: desc.enumerable,
                configurable: desc.configurable
              });
            } catch (_) {}
            return orig;
          }

          function wrapGetter(proto, prop, impl) {
            if (!proto) return null;
            const desc = realmObject.getOwnPropertyDescriptor(proto, prop);
            if (!desc || typeof desc.get !== 'function') return null;
            const origGet = desc.get;
            const getterName = 'get ' + prop;
            const wrappedGet = ({
              [getterName]() {
                return impl.call(this, origGet);
              }
            })[getterName];
            maskAsNative(wrappedGet, getterName, 0);
            try {
              realmObject.defineProperty(proto, prop, {
                get: wrappedGet,
                set: desc.set,
                enumerable: desc.enumerable,
                configurable: desc.configurable
              });
            } catch (_) {}
            return origGet;
          }

          // --- Synchronously protect same-origin iframes (closes #canvas-iframe / #rtc-iframe escapes) ---
          function hookFrameElement(ctor) {
            const proto = ctor && ctor.prototype;
            if (!proto) return;
            wrapGetter(proto, 'contentWindow', function(origGet) {
              const cw = origGet.call(this);
              try {
                if (cw && cw !== win) installIntoRealm(cw);
              } catch (_) {}
              return cw;
            });
            wrapGetter(proto, 'contentDocument', function(origGet) {
              const cd = origGet.call(this);
              try {
                const cw = cd && cd.defaultView;
                if (cw && cw !== win) installIntoRealm(cw);
              } catch (_) {}
              return cd;
            });
          }
          hookFrameElement(win.HTMLIFrameElement);
          hookFrameElement(win.HTMLFrameElement);
          hookFrameElement(win.HTMLObjectElement);

          // --- Early Document-Start Global Privacy Control (GPC) ---
          const navCtor = win.Navigator;
          const navProto = navCtor ? navCtor.prototype : null;
          if (applyGpc && navProto) {
            const existingGpc = realmObject.getOwnPropertyDescriptor(navProto, 'globalPrivacyControl');
            const gpcGet = ({
              ['get globalPrivacyControl']() {
                if (!this || (!(this instanceof navCtor) &&
                    realmObject.prototype.toString.call(this) !== '[object Navigator]')) {
                  throw new win.TypeError('Illegal invocation');
                }
                return true;
              }
            })['get globalPrivacyControl'];
            maskAsNative(gpcGet, 'get globalPrivacyControl', 0);
            try {
              realmObject.defineProperty(navProto, 'globalPrivacyControl', {
                get: gpcGet,
                set: existingGpc ? existingGpc.set : undefined,
                enumerable: true,
                configurable: true
              });
            } catch (_) {}
          }

          if (!applyFp) return;

          // --- 1. Canvas 2D & OffscreenCanvas Readback Farbling ---
          const MAX_FARBLE_PIXELS = 2048 * 2048;
          const htmlCanvasProto = win.HTMLCanvasElement ? win.HTMLCanvasElement.prototype : null;
          const ctx2dProto = win.CanvasRenderingContext2D ? win.CanvasRenderingContext2D.prototype : null;
          const canvasColorSpaces = new WeakMap();
          const origGetContext = wrapMethod(htmlCanvasProto, 'getContext', function(orig, args) {
            const ctx = orig.apply(this, args);
            if (ctx && args[0] === '2d' && typeof ctx.getContextAttributes === 'function') {
              try {
                const attrs = ctx.getContextAttributes();
                if (attrs && attrs.colorSpace) {
                  canvasColorSpaces.set(this, attrs.colorSpace);
                }
              } catch (_) {}
            }
            return ctx;
          });
          const origDrawImage = ctx2dProto && typeof ctx2dProto.drawImage === 'function'
            ? ctx2dProto.drawImage
            : null;
          const origPutImageData = ctx2dProto && typeof ctx2dProto.putImageData === 'function'
            ? ctx2dProto.putImageData
            : null;
          const origGetImageData = wrapMethod(ctx2dProto, 'getImageData', function(orig, args) {
            const img = orig.apply(this, args);
            if (img && img.data && (img.width | 0) * (img.height | 0) >= 16) {
              if (farblePixels(img.data, img.width, img.height)) {
                reportFp('canvas');
              }
            }
            return img;
          });

          function createCloneContext2d(clone, origGetCtx, colorSpace) {
            if (colorSpace) {
              try {
                const csCtx = origGetCtx.call(clone, '2d', { willReadFrequently: true, colorSpace: colorSpace });
                if (csCtx) return csCtx;
              } catch (_) {}
            }
            return origGetCtx.call(clone, '2d', { willReadFrequently: true });
          }

          function cloneAndFarbleCanvas(canvas, w, h) {
            const doc = canvas.ownerDocument || win.document;
            if (!doc || typeof doc.createElement !== 'function') return null;
            const clone = doc.createElement('canvas');
            clone.width = w;
            clone.height = h;
            const ctx = createCloneContext2d(clone, origGetContext, canvasColorSpaces.get(canvas));
            if (!ctx) return null;
            origDrawImage.call(ctx, canvas, 0, 0);
            const img = origGetImageData.call(ctx, 0, 0, w, h);
            if (!farblePixels(img.data, w, h)) return null;
            origPutImageData.call(ctx, img, 0, 0);
            return clone;
          }

          wrapMethod(htmlCanvasProto, 'toDataURL', function(orig, args) {
            let w = 0, h = 0;
            try {
              w = this.width | 0;
              h = this.height | 0;
            } catch (_) {
              return orig.apply(this, args);
            }
            const pxCount = w * h;
            if (w <= 0 || h <= 0 || pxCount < 16 || pxCount > MAX_FARBLE_PIXELS ||
                !origGetContext || !origDrawImage || !origGetImageData || !origPutImageData) {
              return orig.apply(this, args);
            }
            try {
              const clone = cloneAndFarbleCanvas(this, w, h);
              if (!clone) return orig.apply(this, args);
              reportFp('canvas');
              return orig.apply(clone, args);
            } catch (_) {
              return orig.apply(this, args);
            }
          });

          wrapMethod(htmlCanvasProto, 'toBlob', function(orig, args) {
            let w = 0, h = 0;
            try {
              w = this.width | 0;
              h = this.height | 0;
            } catch (_) {
              return orig.apply(this, args);
            }
            const pxCount = w * h;
            if (w <= 0 || h <= 0 || pxCount < 16 || pxCount > MAX_FARBLE_PIXELS ||
                !origGetContext || !origDrawImage || !origGetImageData || !origPutImageData) {
              return orig.apply(this, args);
            }
            try {
              const clone = cloneAndFarbleCanvas(this, w, h);
              if (!clone) return orig.apply(this, args);
              reportFp('canvas');
              return orig.apply(clone, args);
            } catch (_) {
              return orig.apply(this, args);
            }
          });

          const OrigOffscreenCanvas = win.OffscreenCanvas || null;
          if (OrigOffscreenCanvas) {
            const offProto = OrigOffscreenCanvas.prototype;
            const offCtxProto = win.OffscreenCanvasRenderingContext2D
              ? win.OffscreenCanvasRenderingContext2D.prototype
              : null;
            const offColorSpaces = new WeakMap();
            const origOffGetContext = wrapMethod(offProto, 'getContext', function(orig, args) {
              const ctx = orig.apply(this, args);
              if (ctx && args[0] === '2d' && typeof ctx.getContextAttributes === 'function') {
                try {
                  const attrs = ctx.getContextAttributes();
                  if (attrs && attrs.colorSpace) {
                    offColorSpaces.set(this, attrs.colorSpace);
                  }
                } catch (_) {}
              }
              return ctx;
            });
            const origOffDrawImage = offCtxProto && typeof offCtxProto.drawImage === 'function'
              ? offCtxProto.drawImage
              : null;
            const origOffPutImageData = offCtxProto && typeof offCtxProto.putImageData === 'function'
              ? offCtxProto.putImageData
              : null;
            const origOffGetImageData = wrapMethod(offCtxProto, 'getImageData', function(orig, args) {
              const img = orig.apply(this, args);
              if (img && img.data && (img.width | 0) * (img.height | 0) >= 16) {
                if (farblePixels(img.data, img.width, img.height)) {
                  reportFp('canvas');
                }
              }
              return img;
            });
            wrapMethod(offProto, 'convertToBlob', function(orig, args) {
              let w = 0, h = 0;
              try {
                w = this.width | 0;
                h = this.height | 0;
              } catch (_) {
                return orig.apply(this, args);
              }
              const pxCount = w * h;
              if (w <= 0 || h <= 0 || pxCount < 16 || pxCount > MAX_FARBLE_PIXELS ||
                  !origOffGetContext || !origOffDrawImage || !origOffGetImageData || !origOffPutImageData) {
                return orig.apply(this, args);
              }
              try {
                const clone = new OrigOffscreenCanvas(w, h);
                const ctx = createCloneContext2d(clone, origOffGetContext, offColorSpaces.get(this));
                if (!ctx) return orig.apply(this, args);
                origOffDrawImage.call(ctx, this, 0, 0);
                const img = origOffGetImageData.call(ctx, 0, 0, w, h);
                if (!farblePixels(img.data, w, h)) return orig.apply(this, args);
                origOffPutImageData.call(ctx, img, 0, 0);
                reportFp('canvas');
                return orig.apply(clone, args);
              } catch (_) {
                return orig.apply(this, args);
              }
            });
          }

          // --- 2. WebGL / WebGL2 Mitigation ---
          function wrapWebGL(proto) {
            if (!proto) return;
            wrapMethod(proto, 'getParameter', function(orig, args) {
              const pname = args[0];
              const val = orig.apply(this, args);
              if (pname === 0x9245) {
                if (val !== null && val !== undefined) {
                  reportFp('webgl');
                  return 'Apple Inc.';
                }
                return val;
              }
              if (pname === 0x9246) {
                if (val !== null && val !== undefined) {
                  reportFp('webgl');
                  return 'Apple GPU';
                }
                return val;
              }
              if (fpLevel === 1 && val !== null && val !== undefined) {
                if (typeof val === 'number') {
                  switch (pname) {
                    case 0x0D33: return Math.min(val, 16384);
                    case 0x851C: return Math.min(val, 8192);
                    case 0x84E8: return Math.min(val, 8192);
                    case 0x8872: return Math.min(val, 16);
                    case 0x8B4C: return Math.min(val, 16);
                    case 0x8B4D: return Math.min(val, 32);
                    case 0x8869: return Math.min(val, 16);
                    case 0x8DFC: return Math.min(val, 30);
                    case 0x8DFB: return Math.min(val, 1024);
                    case 0x8DFD: return Math.min(val, 1024);
                    case 0x8D57: return Math.min(val, 4);
                    default: break;
                  }
                } else if (pname === 0x0D3A && typeof val.length === 'number' && val.length >= 2) {
                  val[0] = Math.min(val[0], 16384);
                  val[1] = Math.min(val[1], 16384);
                }
              }
              return val;
            });

            wrapMethod(proto, 'getSupportedExtensions', function(orig, args) {
              const exts = orig.apply(this, args);
              if (!Array.isArray(exts) || exts.length <= 1) return exts;
              const out = exts.slice();
              const prng = mulberry32((siteSeed ^ 0x57474c45) >>> 0);
              for (let i = out.length - 1; i > 0; i--) {
                const j = Math.floor(prng() * (i + 1));
                const tmp = out[i];
                out[i] = out[j];
                out[j] = tmp;
              }
              reportFp('webgl');
              return out;
            });

            wrapMethod(proto, 'readPixels', function(orig, args) {
              const res = orig.apply(this, args);
              const width = args[2] | 0;
              const height = args[3] | 0;
              const pixels = args[6];
              const dstOffset = args.length >= 8 ? (args[7] >>> 0) : 0;
              const isByteView = pixels && ArrayBuffer.isView(pixels) && pixels.BYTES_PER_ELEMENT === 1;
              if (isByteView && width > 0 && height > 0 &&
                  width * height >= 16 && dstOffset < pixels.length) {
                const view = dstOffset > 0 ? pixels.subarray(dstOffset) : pixels;
                if (view.length >= width * height * 4) {
                  if (farblePixels(view, width, height)) {
                    reportFp('webgl');
                  }
                } else if (view.length >= 16) {
                  const prng = mulberry32(
                    (docSeed ^ Math.imul(width, 0x9e3779b1) ^ Math.imul(height, 0x85ebca6b)) >>> 0
                  );
                  const nudges = Math.min(8, Math.max(2, view.length >> 8));
                  for (let i = 0; i < nudges; i++) {
                    const idx = Math.floor(prng() * view.length);
                    const dir = prng() < 0.5 ? -1 : 1;
                    const v = view[idx];
                    view[idx] = (v + dir >= 0 && v + dir <= 255) ? (v + dir) : (v - dir);
                  }
                  reportFp('webgl');
                }
              }
              return res;
            });
          }

          if (win.WebGLRenderingContext) {
            wrapWebGL(win.WebGLRenderingContext.prototype);
          }
          if (win.WebGL2RenderingContext) {
            wrapWebGL(win.WebGL2RenderingContext.prototype);
          }

          // --- 3. AudioContext Fingerprint Mitigation ---
          const farbledAudioBuffers = new WeakMap();
          const audioBufProto = win.AudioBuffer ? win.AudioBuffer.prototype : null;
          wrapMethod(audioBufProto, 'getChannelData', function(orig, args) {
            const buf = orig.apply(this, args);
            if (buf && buf.length >= 16) {
              const ch = args[0] | 0;
              let chSet = farbledAudioBuffers.get(this);
              if ((!chSet || !chSet.has(ch)) && hasNonZeroSamples(buf)) {
                const p = audioChannelParams(buf.length, ch);
                for (let i = p.start; i < buf.length; i += p.stride) {
                  buf[i] += audioDeltaAt(p.channelSeed, i);
                }
                if (!chSet) {
                  chSet = new Set();
                  farbledAudioBuffers.set(this, chSet);
                }
                chSet.add(ch);
                reportFp('audio');
              }
            }
            return buf;
          });

          wrapMethod(audioBufProto, 'copyFromChannel', function(orig, args) {
            orig.apply(this, args);
            const dst = args[0];
            const ch = args[1] | 0;
            const bufferOffset = args.length >= 3 ? (args[2] >>> 0) : 0;
            const bufLen = this && typeof this.length === 'number' ? (this.length | 0) : 0;
            const isFloatView = dst && ArrayBuffer.isView(dst) && dst.BYTES_PER_ELEMENT === 4;
            if (isFloatView && dst.length > 0 && bufLen >= 16) {
              const chSet = farbledAudioBuffers.get(this);
              if ((!chSet || !chSet.has(ch)) && hasNonZeroSamples(dst)) {
                const p = audioChannelParams(bufLen, ch);
                const end = Math.min(bufLen, bufferOffset + dst.length);
                if (end > bufferOffset) {
                  let first = p.start;
                  if (first < bufferOffset) {
                    const rem = (bufferOffset - first) % p.stride;
                    first = rem === 0 ? bufferOffset : (bufferOffset + p.stride - rem);
                  }
                  for (let i = first; i < end; i += p.stride) {
                    dst[i - bufferOffset] += audioDeltaAt(p.channelSeed, i);
                  }
                  reportFp('audio');
                }
              }
            }
          });

          const analyserProto = win.AnalyserNode ? win.AnalyserNode.prototype : null;
          wrapMethod(analyserProto, 'getFloatFrequencyData', function(orig, args) {
            orig.apply(this, args);
            const arr = args[0];
            if (arr && ArrayBuffer.isView(arr) && arr.BYTES_PER_ELEMENT === 4 && arr.length > 0) {
              const prng = mulberry32((docSeed ^ Math.imul(arr.length, 0xc2b2ae35)) >>> 0);
              const stride = Math.max(1, Math.min(8, arr.length >> 4));
              const start = Math.floor(prng() * stride);
              for (let i = start; i < arr.length; i += stride) {
                if (Number.isFinite(arr[i])) {
                  arr[i] += (prng() - 0.5) * 2e-7;
                }
              }
              reportFp('audio');
            }
          });

          wrapMethod(analyserProto, 'getByteFrequencyData', function(orig, args) {
            orig.apply(this, args);
            const arr = args[0];
            if (arr && ArrayBuffer.isView(arr) && arr.BYTES_PER_ELEMENT === 1 && arr.length > 0) {
              const prng = mulberry32((docSeed ^ Math.imul(arr.length, 0x85ebca6b)) >>> 0);
              const stride = Math.max(1, Math.min(8, arr.length >> 4));
              const start = Math.floor(prng() * stride);
              let touched = false;
              for (let i = start; i < arr.length; i += stride) {
                const v = arr[i];
                if (v > 0) {
                  const dir = prng() < 0.5 ? -1 : 1;
                  arr[i] = (v + dir >= 0 && v + dir <= 255) ? (v + dir) : (v - dir);
                  touched = true;
                }
              }
              if (touched) reportFp('audio');
            }
          });

          // --- 4. WebRTC MediaDevices Enumeration Scrubbing (zero mic label / groupId leak) ---
          const mediaDevicesProto = win.MediaDevices ? win.MediaDevices.prototype : null;
          if (mediaDevicesProto) {
            wrapMethod(mediaDevicesProto, 'getUserMedia', function(orig, args) {
              const constraints = args[0];
              const promise = orig.apply(this, args);
              if (promise && typeof promise.then === 'function') {
                return promise.then(function(stream) {
                  try {
                    if (constraints && constraints.audio) mediaGrantState.audio = true;
                    if (constraints && constraints.video) mediaGrantState.video = true;
                    if (stream && typeof stream.getAudioTracks === 'function' && stream.getAudioTracks().length > 0) {
                      mediaGrantState.audio = true;
                    }
                    if (stream && typeof stream.getVideoTracks === 'function' && stream.getVideoTracks().length > 0) {
                      mediaGrantState.video = true;
                    }
                  } catch (_) {}
                  return stream;
                });
              }
              return promise;
            });

            const mdiProto = win.MediaDeviceInfo ? win.MediaDeviceInfo.prototype : realmObject.prototype;
            function makeScrubbedDevice(kind) {
              const dev = realmObject.create(mdiProto);
              const defRO = function(k, v) {
                realmObject.defineProperty(dev, k, {
                  value: v,
                  writable: false,
                  enumerable: true,
                  configurable: true
                });
              };
              defRO('deviceId', '');
              defRO('groupId', '');
              defRO('kind', kind);
              defRO('label', '');
              const toJsonFn = maskAsNative(({
                toJSON() {
                  return { deviceId: '', kind: kind, label: '', groupId: '' };
                }
              }).toJSON, 'toJSON', 0);
              realmObject.defineProperty(dev, 'toJSON', {
                value: toJsonFn,
                writable: true,
                enumerable: false,
                configurable: true
              });
              return dev;
            }

            wrapMethod(mediaDevicesProto, 'enumerateDevices', function(orig, args) {
              const promise = orig.apply(this, args);
              if (!promise || typeof promise.then !== 'function') return promise;
              return promise.then(function(devices) {
                if (!Array.isArray(devices)) return devices;
                if (mediaGrantState.audio && mediaGrantState.video) return devices;
                const out = [];
                let sawAudioIn = false;
                let sawVideoIn = false;
                let scrubbed = false;
                for (let i = 0; i < devices.length; i++) {
                  const d = devices[i];
                  if (!d) continue;
                  const kind = d.kind;
                  if (kind === 'audioinput') {
                    if (mediaGrantState.audio) {
                      out.push(d);
                    } else {
                      if (d.label || d.deviceId || d.groupId || sawAudioIn) scrubbed = true;
                      if (!sawAudioIn) {
                        sawAudioIn = true;
                        out.push(makeScrubbedDevice('audioinput'));
                      }
                    }
                  } else if (kind === 'videoinput') {
                    if (mediaGrantState.video) {
                      out.push(d);
                    } else {
                      if (d.label || d.deviceId || d.groupId || sawVideoIn) scrubbed = true;
                      if (!sawVideoIn) {
                        sawVideoIn = true;
                        out.push(makeScrubbedDevice('videoinput'));
                      }
                    }
                  } else if (kind === 'audiooutput') {
                    if (mediaGrantState.audio) {
                      out.push(d);
                    } else {
                      scrubbed = true;
                    }
                  }
                }
                if (scrubbed) reportFp('mediaDevices');
                return out;
              });
            });
          }

          // --- 5. Hardware, Plugins, Battery & Timing Hardening ---
          if (navProto) {
            if (typeof navProto.getBattery === 'function') {
              const addL = maskAsNative(({ addEventListener() {} }).addEventListener, 'addEventListener', 2);
              const remL = maskAsNative(({ removeEventListener() {} }).removeEventListener, 'removeEventListener', 2);
              const dispE = maskAsNative(({ dispatchEvent() { return true; } }).dispatchEvent, 'dispatchEvent', 1);
              wrapMethod(navProto, 'getBattery', function(orig, args) {
                if (!this || (!(this instanceof navCtor) &&
                    realmObject.prototype.toString.call(this) !== '[object Navigator]')) {
                  return orig.apply(this, args);
                }
                reportFp('battery');
                return Promise.resolve({
                  charging: true,
                  chargingTime: 0,
                  dischargingTime: Infinity,
                  level: 1.0,
                  onchargingchange: null,
                  onchargingtimechange: null,
                  ondischargingtimechange: null,
                  onlevelchange: null,
                  addEventListener: addL,
                  removeEventListener: remL,
                  dispatchEvent: dispE
                });
              });
            }

            wrapGetter(navProto, 'hardwareConcurrency', function(origGet) {
              const val = origGet.call(this);
              reportFp('hardware');
              const real = (typeof val === 'number' && val >= 2) ? val : 8;
              const basePool = fpLevel === 1 ? [2, 4] : [2, 4, 6, 8];
              const pool = basePool.filter(function(c) { return c <= Math.max(4, real); });
              const choices = pool.length > 0 ? pool : [4];
              const prng = mulberry32((siteSeed ^ 0x48574343) >>> 0);
              return choices[Math.floor(prng() * choices.length)];
            });

            wrapGetter(navProto, 'deviceMemory', function(origGet) {
              origGet.call(this);
              reportFp('hardware');
              return 8;
            });

            // Per-site farbled PluginArray proxy (preserves native PDF viewers & WebIDL identity)
            const pluginArrayCache = new WeakMap();
            const pluginProto = win.Plugin ? win.Plugin.prototype : realmObject.prototype;
            function createFarbledPlugin() {
              const fp = realmObject.create(pluginProto);
              const defProp = function(k, v) {
                realmObject.defineProperty(fp, k, {
                  value: v,
                  writable: false,
                  enumerable: true,
                  configurable: true
                });
              };
              defProp('name', sitePluginMeta.name);
              defProp('description', sitePluginMeta.description);
              defProp('filename', sitePluginMeta.filename);
              defProp('length', 0);
              const itemFn = maskAsNative(({ item() { return null; } }).item, 'item', 1);
              const namedItemFn = maskAsNative(({ namedItem() { return null; } }).namedItem, 'namedItem', 1);
              realmObject.defineProperty(fp, 'item', { value: itemFn, writable: true, enumerable: false, configurable: true });
              realmObject.defineProperty(fp, 'namedItem', { value: namedItemFn, writable: true, enumerable: false, configurable: true });
              realmObject.defineProperty(fp, Symbol.iterator, {
                value: function*() {},
                writable: true,
                enumerable: false,
                configurable: true
              });
              return fp;
            }
            const realmFakePlugin = createFarbledPlugin();

            wrapGetter(navProto, 'plugins', function(origGet) {
              const realPlugins = origGet.call(this);
              if (!realPlugins || typeof Proxy === 'undefined') return realPlugins;
              let cached = pluginArrayCache.get(realPlugins);
              if (cached) return cached;
              try {
                const origLen = realPlugins.length | 0;
                const extraIdxStr = String(origLen);
                const itemMethod = maskAsNative(({
                  item(index) {
                    const idx = index >>> 0;
                    if (idx === origLen) return realmFakePlugin;
                    return realPlugins.item(idx);
                  }
                }).item, 'item', 1);
                const namedItemMethod = maskAsNative(({
                  namedItem(name) {
                    if (String(name) === sitePluginMeta.name) return realmFakePlugin;
                    return realPlugins.namedItem(name);
                  }
                }).namedItem, 'namedItem', 1);
                const iterMethod = function*() {
                  for (let i = 0; i < origLen; i++) {
                    yield realPlugins[i];
                  }
                  yield realmFakePlugin;
                };
                cached = new Proxy(realPlugins, {
                  get(target, prop) {
                    if (prop === 'length') return origLen + 1;
                    if (prop === extraIdxStr || prop === sitePluginMeta.name) return realmFakePlugin;
                    if (prop === 'item') return itemMethod;
                    if (prop === 'namedItem') return namedItemMethod;
                    if (prop === Symbol.iterator) return iterMethod;
                    const v = Reflect.get(target, prop, target);
                    return typeof v === 'function' ? v.bind(target) : v;
                  },
                  has(target, prop) {
                    if (prop === extraIdxStr || prop === sitePluginMeta.name) return true;
                    return Reflect.has(target, prop);
                  },
                  ownKeys(target) {
                    const keys = Reflect.ownKeys(target);
                    if (keys.indexOf(extraIdxStr) === -1) keys.push(extraIdxStr);
                    return keys;
                  },
                  getOwnPropertyDescriptor(target, prop) {
                    if (prop === extraIdxStr) {
                      return {
                        value: realmFakePlugin,
                        writable: false,
                        enumerable: true,
                        configurable: true
                      };
                    }
                    return Reflect.getOwnPropertyDescriptor(target, prop);
                  }
                });
                pluginArrayCache.set(realPlugins, cached);
                return cached;
              } catch (_) {
                return realPlugins;
              }
            });

            if (fpLevel === 1) {
              const addConnL = maskAsNative(({ addEventListener() {} }).addEventListener, 'addEventListener', 2);
              const remConnL = maskAsNative(({ removeEventListener() {} }).removeEventListener, 'removeEventListener', 2);
              const dispConnE = maskAsNative(({ dispatchEvent() { return true; } }).dispatchEvent, 'dispatchEvent', 1);
              const neutralConnection = {
                effectiveType: '4g',
                rtt: 50,
                downlink: 10,
                saveData: false,
                onchange: null,
                addEventListener: addConnL,
                removeEventListener: remConnL,
                dispatchEvent: dispConnE
              };
              wrapGetter(navProto, 'connection', function(origGet) {
                origGet.call(this);
                reportFp('hardware');
                return neutralConnection;
              });
            }
          }

          wrapMethod(win.Performance ? win.Performance.prototype : null, 'now', function(orig) {
            const t = orig.call(this);
            return Math.round(t * 10) / 10;
          });
        }

        installIntoRealm(window);
      })
    )JS";

    if (context->Enter()) {
      CefRefPtr<CefV8Value> privacyInstaller;
      CefRefPtr<CefV8Exception> privacyEx;
      if (context->Eval(kPrivacyJS, CefString(), 0, privacyInstaller, privacyEx) &&
          privacyInstaller && privacyInstaller->IsFunction()) {
        CefRefPtr<CefV8Handler> handler = new SXTelemetryV8Handler(browser, frame);
        CefV8ValueList args;
        args.push_back(CefV8Value::CreateBool(applyGpc));
        args.push_back(CefV8Value::CreateBool(applyFp));
        args.push_back(CefV8Value::CreateInt(cfg.level));
        args.push_back(CefV8Value::CreateString(siteSeedStr));
        args.push_back(CefV8Value::CreateString(docSeedStr));
        args.push_back(CefV8Value::CreateString(topHost));
        args.push_back(CefV8Value::CreateString(frameHost));
        args.push_back(CefV8Value::CreateBool(mediaAllowedAudio));
        args.push_back(CefV8Value::CreateBool(mediaAllowedVideo));
        args.push_back(CefV8Value::CreateFunction("reportPrivacyFpEvent", handler));
        privacyInstaller->ExecuteFunction(nullptr, args);
      }
      context->Exit();
    }
  }

  void UpdateProcessNameForFrame(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame) {
    if (!browser || !frame) return;
    std::string url = frame->GetURL().ToString();
    std::string label = SXFormatDisplayNameForURL(url);
    if (label.empty()) return;
    int bid = browser->GetIdentifier();
    if (frame->IsMain()) {
      main_frame_names_[bid] = label;
    } else {
      subframe_names_[bid] = label;
    }
    RefreshProcessDisplayName();
  }

  void RefreshProcessDisplayName() {
    if (!main_frame_names_.empty()) {
      SXSetProcessDisplayName(main_frame_names_.begin()->second);
      return;
    }
    if (!subframe_names_.empty()) {
      SXSetProcessDisplayName(subframe_names_.begin()->second);
      return;
    }
    SXSetProcessDisplayName(SXLS().default_name);
  }

  std::unordered_map<int, SXFrameHooks> frame_hooks_;
  std::unordered_map<int, SXPopupContextInfo> popup_contexts_;
  std::unordered_map<int, SXPrivacyRenderConfig> privacy_configs_;
  std::unordered_map<int, std::string> main_frame_nav_nonces_;
  std::unordered_map<int, std::string> main_frame_names_;
  std::unordered_map<int, std::string> subframe_names_;
  IMPLEMENT_REFCOUNTING(SXHelperApp);
};

}  // namespace

int main(int argc, char* argv[]) {
  // Parse live privacy switches synchronously (pure C++ — zero ObjC/CF/GCD calls)
  // before V8 contexts can ever initialize.
  SXInitLaunchPrivacyConfig(argc, argv);

  // Initialize macOS Chromium sandbox BEFORE loading CEF framework (required by CEF macOS sandbox).
  bool noSandbox = false;
  for (int i = 1; i < argc; ++i) {
    if (argv[i] && strcmp(argv[i], "--no-sandbox") == 0) {
      noSandbox = true;
      break;
    }
  }
  CefScopedSandboxContext sandbox_context;
  if (!noSandbox) {
    if (!sandbox_context.Initialize(argc, argv)) {
      return 1;
    }
  }

  // Load Chromium Embedded Framework dynamically while the process is still single-threaded.
  // Calling LaunchServices/CoreFoundation BEFORE cef_load_library spawns a background GCD
  // utility thread (`com.apple.root.utility-qos.overcommit`) that races with Chromium's
  // PartitionAlloc malloc-zone installation during dlopen and triggers SIGTRAP in _CFRelease.
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    const char* overridePath = std::getenv("SAFARIUM_CEF_FRAMEWORK_BINARY");
    if (!overridePath || !cef_load_library(overridePath)) {
      return 1;
    }
  }

  // Check in with LaunchServices AFTER CEF (and PartitionAlloc) is fully loaded, and BEFORE
  // CefExecuteProcess engages Chromium's Seatbelt sandbox profile.
  SXInitLaunchServicesForSubprocess(argc, argv);

  CefMainArgs main_args(argc, argv);
  CefRefPtr<SXHelperApp> app(new SXHelperApp());
  return CefExecuteProcess(main_args, app, nullptr);
}
