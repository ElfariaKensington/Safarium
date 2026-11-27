// SXPrivacyEngine.h
// Thread-safe C++/Objective-C++ privacy policy snapshot, eTLD+1 classifier,
// 250+ tracker entity dataset, tracking param stripper, and surrogate generator.

#pragma once

#import <Foundation/Foundation.h>

#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace sx::privacy {

struct PolicySnapshot {
  bool prevent_cross_site_tracking = true;
  bool block_all_cookies = false;
  bool advanced_fingerprint = true;
  int advanced_fingerprint_scope = 1;  // 0 = Private Only, 1 = All Browsing
  bool global_privacy_control = false;
  bool https_only_mode = true;
  bool warn_http = false;
  bool strip_tracking_params = true;
  bool referrer_trimming = true;
  bool webrtc_ip_protection = true;
  int protection_level = 0;         // 0 = Standard, 1 = Strict
  int content_blockers_default = 0;  // 0 = On, 1 = Off
  int microphone_default = 0;       // 0 = Ask, 1 = Deny, 2 = Allow
  int camera_default = 0;           // 0 = Ask, 1 = Deny, 2 = Allow
  std::unordered_set<std::string> content_blockers_disabled_hosts;
  std::unordered_set<std::string> content_blockers_enabled_hosts;
  std::unordered_set<std::string> microphone_allowed_hosts;
  std::unordered_set<std::string> camera_allowed_hosts;

  bool IsSiteProtectionEnabled(std::string_view page_host) const;
};

struct TrackerMatch {
  bool matched = false;
  bool is_surrogate_eligible = false;
  std::string matched_domain;
  std::string entity_domain;
  std::string owner_name;
  std::string category;
};

struct ParamStripResult {
  bool modified = false;
  std::string cleaned_url;
  std::vector<std::string> stripped_params;
};

enum class SurrogateKind {
  kNone = 0,
  kGtag,
  kGtm,
  kAnalytics,
  kGa,
  kFbEvents,
};

// Host & URL utilities (pure C++, safe on TID_IO / TID_UI / main thread)
std::string ToLowerASCII(std::string_view s);
std::string NormalizeHost(std::string_view host);
std::string NormalizeHostRaw(std::string_view host);
std::string ExtractSchemeFromURL(std::string_view url);
std::string ExtractHostFromURL(std::string_view url);
std::string ExtractPortFromURL(std::string_view url);
std::string ExtractOriginFromURL(std::string_view url);
std::string RegistrableDomain(std::string_view host);
bool IsIPAddressOrLocalhost(std::string_view host);
bool IsPrivateOrLocalNetworkHost(std::string_view host);
bool IsSameOriginURL(std::string_view url_a, std::string_view url_b);
std::string UpgradeURLSchemeToHTTPS(std::string_view http_url);

class SXPrivacyEngine {
 public:
  static SXPrivacyEngine& Shared();

  // Reads initial policy from NSUserDefaults; call from main thread during runtime init.
  void InitializeDefaultsFromUserDefaults();

  // Replaces the immutable policy snapshot atomically from an Objective-C dictionary.
  std::shared_ptr<const PolicySnapshot> UpdatePolicyFromDictionary(NSDictionary<NSString*, id>* policy);

  // Fast thread-safe snapshot accessor for TID_IO / TID_UI.
  std::shared_ptr<const PolicySnapshot> Snapshot() const;

  // Session salts (32-char lowercase hex strings) for renderer anti-fingerprinting.
  std::string NormalSessionSalt() const;
  std::string IncognitoSessionSalt() const;
  std::string ResetIncognitoSessionSalt();
  void ResetIncognitoState();

  // Allowlist & entity queries.
  bool IsEssentialAllowlistedHost(std::string_view req_host) const;
  bool IsSameEntity(std::string_view page_host, std::string_view req_host, std::string_view entity_domain) const;

  // Tracker classification & blocking decision.
  TrackerMatch ClassifyTrackerHost(std::string_view req_host, int protection_level, bool include_strict) const;
  TrackerMatch EvaluateSubresourceBlock(std::string_view req_url,
                                        std::string_view req_host,
                                        std::string_view page_host,
                                        const PolicySnapshot& policy) const;

  // Surrogate JS detection for high-breakage analytics/tag scripts.
  SurrogateKind DetectSurrogateKind(std::string_view req_url) const;
  static const char* SurrogateScriptBody(SurrogateKind kind);

  // Tracking query parameter stripping.
  ParamStripResult StripTrackingParamsFromURL(std::string_view raw_url) const;

  // Bounce-tracking intermediary detection.
  bool IsBounceTrackerHost(std::string_view host) const;

  // HTTPS-First upgrade & session fallback state (strictly isolated between Normal and Incognito).
  void AllowInsecureHTTPForHost(std::string_view host, bool is_private = false);
  void AddSessionHTTPSFallbackHost(std::string_view host, bool is_private = false);
  bool IsHostAllowedInsecureHTTP(std::string_view host, bool is_private = false) const;
  bool ShouldUpgradeMainFrameToHTTPS(std::string_view url,
                                     std::string_view host,
                                     const PolicySnapshot& policy,
                                     bool is_private = false) const;

 private:
  SXPrivacyEngine();
  static std::string GenerateRandomHexSalt32();

  mutable std::mutex policy_mutex_;
  std::shared_ptr<const PolicySnapshot> snapshot_;

  mutable std::mutex salt_mutex_;
  std::string normal_session_salt_;
  std::string incognito_session_salt_;

  mutable std::mutex http_mutex_;
  std::unordered_set<std::string> normal_allowed_http_hosts_;
  std::unordered_set<std::string> normal_http_fallback_hosts_;
  std::unordered_set<std::string> incognito_allowed_http_hosts_;
  std::unordered_set<std::string> incognito_http_fallback_hosts_;
};

}  // namespace sx::privacy
