// SXPrivacyEngineTests.mm
// Standalone C++ / Objective-C++ unit tests verifying SXPrivacyEngine invariants.

#import "SXPrivacyEngine.h"

#include <cstdio>
#include <cstdlib>
#include <string>

namespace {

int gAssertions = 0;
int gFailures = 0;

void Check(bool cond, const char* expr, int line) {
  gAssertions++;
  if (!cond) {
    gFailures++;
    std::fprintf(stderr, "FAIL line %d: %s\n", line, expr);
  }
}

#define EXPECT_TRUE(cond) Check((cond), #cond, __LINE__)
#define EXPECT_FALSE(cond) Check(!(cond), "!(" #cond ")", __LINE__)
#define EXPECT_EQ(a, b) Check((a) == (b), #a " == " #b, __LINE__)

void TestRegistrableDomain() {
  using namespace sx::privacy;
  EXPECT_EQ(RegistrableDomain("www.google.com"), "google.com");
  EXPECT_EQ(RegistrableDomain("news.bbc.co.uk"), "bbc.co.uk");
  EXPECT_EQ(RegistrableDomain("a.b.c.com.au"), "c.com.au");
  EXPECT_EQ(RegistrableDomain("sub.domain.co.jp"), "domain.co.jp");
  EXPECT_EQ(RegistrableDomain("shop.example.com.tr"), "example.com.tr");
  EXPECT_EQ(RegistrableDomain("127.0.0.1"), "127.0.0.1");
  EXPECT_EQ(RegistrableDomain("[::1]"), "::1");
  EXPECT_EQ(RegistrableDomain("localhost"), "localhost");
}

void TestSameEntityExemption() {
  auto& eng = sx::privacy::SXPrivacyEngine::Shared();
  // Explicit entity_domain
  EXPECT_TRUE(eng.IsSameEntity("youtube.com", "doubleclick.net", "google.com"));
  EXPECT_TRUE(eng.IsSameEntity("instagram.com", "connect.facebook.net", "facebook.com"));
  EXPECT_FALSE(eng.IsSameEntity("nytimes.com", "doubleclick.net", "google.com"));

  // Empty entity_domain reverse lookup map (critical for third-party cookie exemption)
  EXPECT_TRUE(eng.IsSameEntity("youtube.com", "accounts.google.com", ""));
  EXPECT_TRUE(eng.IsSameEntity("mail.google.com", "youtube.com", ""));
  EXPECT_TRUE(eng.IsSameEntity("outlook.com", "xbox.com", ""));
  EXPECT_TRUE(eng.IsSameEntity("office.com", "live.com", ""));
  EXPECT_TRUE(eng.IsSameEntity("instagram.com", "facebook.com", ""));
  EXPECT_TRUE(eng.IsSameEntity("primevideo.com", "twitch.tv", ""));
  EXPECT_FALSE(eng.IsSameEntity("nytimes.com", "youtube.com", ""));
}

void TestStandardVsStrictCalibrationAndAllowlist() {
  auto& eng = sx::privacy::SXPrivacyEngine::Shared();
  sx::privacy::PolicySnapshot standardPolicy;
  standardPolicy.protection_level = 0;

  sx::privacy::PolicySnapshot strictPolicy;
  strictPolicy.protection_level = 1;

  // Checkout fraud, anti-bot, paywall, and HubSpot meetings/forms must NOT break in Standard mode.
  EXPECT_FALSE(eng.EvaluateSubresourceBlock("https://forter.com/script.js", "forter.com", "shop.example.com", standardPolicy).matched);
  EXPECT_FALSE(eng.EvaluateSubresourceBlock("https://px-cloud.net/api.js", "px-cloud.net", "shop.example.com", standardPolicy).matched);
  EXPECT_FALSE(eng.EvaluateSubresourceBlock("https://perimeterx.net/init.js", "perimeterx.net", "shop.example.com", standardPolicy).matched);
  EXPECT_FALSE(eng.EvaluateSubresourceBlock("https://siftscience.com/s.js", "siftscience.com", "shop.example.com", standardPolicy).matched);
  EXPECT_FALSE(eng.EvaluateSubresourceBlock("https://piano.io/x.js", "piano.io", "news.example.com", standardPolicy).matched);
  EXPECT_FALSE(eng.EvaluateSubresourceBlock("https://meetings.hubspot.com/book", "meetings.hubspot.com", "saas.example.com", standardPolicy).matched);
  EXPECT_FALSE(eng.EvaluateSubresourceBlock("https://forms.hubspot.com/submit", "forms.hubspot.com", "saas.example.com", standardPolicy).matched);

  // Facebook Login SDK exempted in Standard mode, blocked in Strict mode; fbevents.js blocked + surrogate in both.
  EXPECT_FALSE(eng.EvaluateSubresourceBlock("https://connect.facebook.net/en_US/sdk.js", "connect.facebook.net", "app.example.com", standardPolicy).matched);
  EXPECT_TRUE(eng.EvaluateSubresourceBlock("https://connect.facebook.net/en_US/sdk.js", "connect.facebook.net", "app.example.com", strictPolicy).matched);
  auto fbPixel = eng.EvaluateSubresourceBlock("https://connect.facebook.net/en_US/fbevents.js", "connect.facebook.net", "app.example.com", standardPolicy);
  EXPECT_TRUE(fbPixel.matched);
  EXPECT_TRUE(fbPixel.is_surrogate_eligible);

  // Strict mode enables checkout/fraud/telemetry domains.
  EXPECT_TRUE(eng.EvaluateSubresourceBlock("https://forter.com/script.js", "forter.com", "shop.example.com", strictPolicy).matched);
  EXPECT_TRUE(eng.EvaluateSubresourceBlock("https://track.hubspot.com/t.gif", "track.hubspot.com", "saas.example.com", standardPolicy).matched);

  // Essential SSO / payments / CAPTCHAs / static CDNs never blocked even in Strict mode.
  EXPECT_FALSE(eng.EvaluateSubresourceBlock("https://accounts.google.com/gsi/client", "accounts.google.com", "app.example.com", strictPolicy).matched);
  EXPECT_FALSE(eng.EvaluateSubresourceBlock("https://appleid.apple.com/auth.js", "appleid.apple.com", "app.example.com", strictPolicy).matched);
  EXPECT_FALSE(eng.EvaluateSubresourceBlock("https://js.stripe.com/v3/", "js.stripe.com", "shop.example.com", strictPolicy).matched);
  EXPECT_FALSE(eng.EvaluateSubresourceBlock("https://challenges.cloudflare.com/turnstile.js", "challenges.cloudflare.com", "app.example.com", strictPolicy).matched);
  EXPECT_FALSE(eng.EvaluateSubresourceBlock("https://hcaptcha.com/1/api.js", "hcaptcha.com", "app.example.com", strictPolicy).matched);
  EXPECT_FALSE(eng.EvaluateSubresourceBlock("https://cdn.jsdelivr.net/npm/pkg", "cdn.jsdelivr.net", "app.example.com", strictPolicy).matched);
}

void TestTrackingParamStripping() {
  auto& eng = sx::privacy::SXPrivacyEngine::Shared();

  // SPA hash-router URL must NOT be corrupted!
  auto spa = eng.StripTrackingParamsFromURL("https://app.example.com/#/dashboard?id=42&utm_source=email");
  EXPECT_FALSE(spa.modified);

  // Normal query params stripped, fragment preserved, Stripe pk_live / pk_test preserved, Matomo pk_campaign stripped.
  auto res = eng.StripTrackingParamsFromURL("https://shop.example.com/pay?pk_live=abc&pk_campaign=spring&utm_medium=cpc&fbclid=123#/done");
  EXPECT_TRUE(res.modified);
  EXPECT_EQ(res.cleaned_url, "https://shop.example.com/pay?pk_live=abc#/done");
  EXPECT_EQ(res.stripped_params.size(), static_cast<size_t>(3));

  // Host-scoped si only on YouTube/Spotify
  auto yt = eng.StripTrackingParamsFromURL("https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=xyz");
  EXPECT_TRUE(yt.modified);
  EXPECT_EQ(yt.cleaned_url, "https://www.youtube.com/watch?v=dQw4w9WgXcQ");

  auto otherSi = eng.StripTrackingParamsFromURL("https://example.com/page?si=keepme");
  EXPECT_FALSE(otherSi.modified);
}

void TestHTTPSFirstAndLocalNetwork() {
  using namespace sx::privacy;
  auto& eng = SXPrivacyEngine::Shared();
  PolicySnapshot policy;
  policy.https_only_mode = true;

  // Ports: only empty or :80 upgrade, and :80 is stripped on upgrade.
  EXPECT_TRUE(eng.ShouldUpgradeMainFrameToHTTPS("http://example.com/a", "example.com", policy, false));
  EXPECT_TRUE(eng.ShouldUpgradeMainFrameToHTTPS("http://example.com:80/a", "example.com", policy, false));
  EXPECT_EQ(UpgradeURLSchemeToHTTPS("http://example.com:80/a"), "https://example.com/a");
  EXPECT_EQ(UpgradeURLSchemeToHTTPS("http://user@example.com:80/a"), "https://user@example.com/a");
  EXPECT_FALSE(eng.ShouldUpgradeMainFrameToHTTPS("http://example.com:8080/a", "example.com", policy, false));
  EXPECT_FALSE(eng.ShouldUpgradeMainFrameToHTTPS("http://example.com:3000/a", "example.com", policy, false));

  // Private / local / single-label / RFC6598 / IPv4-mapped IPv6
  EXPECT_TRUE(IsPrivateOrLocalNetworkHost("localhost"));
  EXPECT_TRUE(IsPrivateOrLocalNetworkHost("printer.local"));
  EXPECT_TRUE(IsPrivateOrLocalNetworkHost("nas.lan"));
  EXPECT_TRUE(IsPrivateOrLocalNetworkHost("router.home.arpa"));
  EXPECT_TRUE(IsPrivateOrLocalNetworkHost("api.internal"));
  EXPECT_TRUE(IsPrivateOrLocalNetworkHost("intranet"));
  EXPECT_TRUE(IsPrivateOrLocalNetworkHost("10.0.0.1"));
  EXPECT_TRUE(IsPrivateOrLocalNetworkHost("192.168.1.50"));
  EXPECT_TRUE(IsPrivateOrLocalNetworkHost("172.16.0.1"));
  EXPECT_TRUE(IsPrivateOrLocalNetworkHost("100.64.0.1"));
  EXPECT_TRUE(IsPrivateOrLocalNetworkHost("100.127.255.254"));
  EXPECT_FALSE(IsPrivateOrLocalNetworkHost("100.128.0.1"));
  EXPECT_TRUE(IsPrivateOrLocalNetworkHost("::ffff:192.168.1.1"));
  EXPECT_TRUE(IsPrivateOrLocalNetworkHost("::ffff:c0a8:0101"));
  EXPECT_FALSE(IsPrivateOrLocalNetworkHost("::ffff:8.8.8.8"));
  EXPECT_FALSE(IsPrivateOrLocalNetworkHost("example.com"));

  // Normal vs Incognito fallback isolation + ResetIncognitoState()
  eng.AddSessionHTTPSFallbackHost("http-only-private.example", true);
  EXPECT_FALSE(eng.ShouldUpgradeMainFrameToHTTPS("http://http-only-private.example/", "http-only-private.example", policy, true));
  EXPECT_TRUE(eng.ShouldUpgradeMainFrameToHTTPS("http://http-only-private.example/", "http-only-private.example", policy, false));
  eng.ResetIncognitoState();
  EXPECT_TRUE(eng.ShouldUpgradeMainFrameToHTTPS("http://http-only-private.example/", "http-only-private.example", policy, true));
}

void TestBounceTrackersAndSurrogates() {
  using namespace sx::privacy;
  auto& eng = SXPrivacyEngine::Shared();

  // Subdomain matching for bounce trackers
  EXPECT_TRUE(eng.IsBounceTrackerHost("l.facebook.com"));
  EXPECT_TRUE(eng.IsBounceTrackerHost("www.googleadservices.com"));
  EXPECT_TRUE(eng.IsBounceTrackerHost("adclick.g.doubleclick.net"));
  EXPECT_TRUE(eng.IsBounceTrackerHost("www.shareasale.com"));
  EXPECT_TRUE(eng.IsBounceTrackerHost("www.awin1.com"));
  EXPECT_FALSE(eng.IsBounceTrackerHost("example.com"));

  // All 5 JS surrogates non-empty & contain key shims
  std::string gtag = SXPrivacyEngine::SurrogateScriptBody(SurrogateKind::kGtag);
  std::string gtm = SXPrivacyEngine::SurrogateScriptBody(SurrogateKind::kGtm);
  std::string analytics = SXPrivacyEngine::SurrogateScriptBody(SurrogateKind::kAnalytics);
  std::string ga = SXPrivacyEngine::SurrogateScriptBody(SurrogateKind::kGa);
  std::string fb = SXPrivacyEngine::SurrogateScriptBody(SurrogateKind::kFbEvents);

  EXPECT_TRUE(gtag.find("event_callback") != std::string::npos);
  EXPECT_TRUE(gtm.find("eventCallback") != std::string::npos);
  EXPECT_TRUE(analytics.find("hitCallback") != std::string::npos);
  EXPECT_TRUE(ga.find("_gat") != std::string::npos);
  EXPECT_TRUE(fb.find("fbq") != std::string::npos);
}

void TestFingerprintingScopeAndMediaDefaults() {
  auto& eng = sx::privacy::SXPrivacyEngine::Shared();

  // Default PolicySnapshot must enable anti-fingerprinting in ALL browsing (scope == 1)
  // and keep camera/microphone permissions in Ask mode (0) with empty allowlists.
  sx::privacy::PolicySnapshot freshDefault;
  EXPECT_TRUE(freshDefault.advanced_fingerprint);
  EXPECT_EQ(freshDefault.advanced_fingerprint_scope, 1);
  EXPECT_EQ(freshDefault.microphone_default, 0);
  EXPECT_EQ(freshDefault.camera_default, 0);
  EXPECT_TRUE(freshDefault.microphone_allowed_hosts.empty());
  EXPECT_TRUE(freshDefault.camera_allowed_hosts.empty());

  auto emptySnap = eng.UpdatePolicyFromDictionary(@{});
  EXPECT_TRUE(emptySnap->advanced_fingerprint);
  EXPECT_EQ(emptySnap->advanced_fingerprint_scope, 1);
  EXPECT_EQ(emptySnap->microphone_default, 0);
  EXPECT_EQ(emptySnap->camera_default, 0);

  auto customSnap = eng.UpdatePolicyFromDictionary(@{
    @"advancedFingerprintScope": @0,
    @"microphoneDefault": @1,
    @"cameraDefault": @2,
    @"microphoneAllowedHosts": @[ @"www.Meet.Google.com", @"discord.com" ],
    @"cameraAllowedHosts": @[ @"zoom.us" ],
  });
  EXPECT_EQ(customSnap->advanced_fingerprint_scope, 0);
  EXPECT_EQ(customSnap->microphone_default, 1);
  EXPECT_EQ(customSnap->camera_default, 2);
  EXPECT_TRUE(customSnap->microphone_allowed_hosts.count("meet.google.com") == 1);
  EXPECT_TRUE(customSnap->microphone_allowed_hosts.count("discord.com") == 1);
  EXPECT_TRUE(customSnap->camera_allowed_hosts.count("zoom.us") == 1);
}

}  // namespace

int main() {
  @autoreleasepool {
    TestRegistrableDomain();
    TestSameEntityExemption();
    TestStandardVsStrictCalibrationAndAllowlist();
    TestTrackingParamStripping();
    TestHTTPSFirstAndLocalNetwork();
    TestBounceTrackersAndSurrogates();
    TestFingerprintingScopeAndMediaDefaults();
  }
  std::printf("BrowserCorePrivacyTests: %d assertions, %d failures\n", gAssertions, gFailures);
  return gFailures == 0 ? 0 : 1;
}
