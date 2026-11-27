// SXPrivacyEngine.mm
// Comprehensive C++/Objective-C++ privacy engine for Safarium BrowserCore.

#import "SXPrivacyEngine.h"

#include <stdlib.h>
#include <algorithm>
#include <cctype>
#include <cstring>

namespace sx::privacy {

namespace {

struct TrackerEntry {
  const char* entity_domain;
  const char* owner_name;
  const char* category;
  bool strict_only;
};

// Multi-part public suffixes for accurate eTLD+1 extraction without external PSL files.
const std::unordered_set<std::string>& MultiPartPublicSuffixes() {
  static const std::unordered_set<std::string>* suffixes = new std::unordered_set<std::string>({
      // UK
      "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk", "ltd.uk", "plc.uk", "sch.uk",
      // Australia
      "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
      // Japan
      "co.jp", "ne.jp", "or.jp", "ac.jp", "ad.jp", "ed.jp", "go.jp", "gr.jp", "lg.jp",
      // Brazil
      "com.br", "net.br", "org.br", "gov.br", "edu.br", "art.br",
      // Turkey
      "com.tr", "org.tr", "net.tr", "gov.tr", "edu.tr", "gen.tr", "biz.tr", "info.tr",
      "web.tr", "bel.tr", "pol.tr", "k12.tr",
      // New Zealand
      "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz", "maori.nz",
      // Mexico
      "com.mx", "org.mx", "net.mx", "gob.mx", "edu.mx",
      // India
      "co.in", "com.in", "net.in", "org.in", "gov.in", "ac.in", "ernet.in", "gen.in", "ind.in",
      // China / Hong Kong / Taiwan / Singapore / Korea
      "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
      "com.sg", "net.sg", "org.sg", "gov.sg", "edu.sg",
      "com.hk", "net.hk", "org.hk", "gov.hk", "edu.hk",
      "co.kr", "or.kr", "ne.kr", "go.kr", "ac.kr", "re.kr",
      "com.tw", "net.tw", "org.tw", "gov.tw", "edu.tw",
      // South Africa / Israel
      "co.za", "org.za", "net.za", "gov.za", "ac.za", "web.za",
      "co.il", "org.il", "net.il", "ac.il", "gov.il", "muni.il",
      // LatAm / Europe / Asia / Africa
      "com.ar", "org.ar", "net.ar", "gov.ar",
      "com.co", "org.co", "net.co", "gov.co",
      "com.pe", "org.pe", "net.pe", "gob.pe",
      "com.ve", "com.ec", "com.uy", "com.py", "com.bo", "com.cl",
      "com.ua", "org.ua", "net.ua", "gov.ua",
      "com.pl", "org.pl", "net.pl", "gov.pl",
      "co.id", "or.id", "ac.id", "go.id", "web.id",
      "co.th", "in.th", "ac.th", "or.th", "go.th",
      "com.my", "net.my", "org.my", "gov.my", "edu.my",
      "com.ph", "org.ph", "net.ph", "gov.ph",
      "com.vn", "net.vn", "org.vn", "gov.vn", "edu.vn",
      "com.eg", "com.sa", "com.ae", "co.ke", "com.ng", "co.ma",
      "co.cr", "com.do", "com.gt", "com.pa", "com.sv", "com.ni",
      "com.ru", "org.ru", "net.ru",
      // Platform shared suffixes
      "github.io", "gitlab.io", "pages.dev", "netlify.app", "vercel.app",
      "herokuapp.com", "appspot.com", "web.app", "firebaseapp.com",
  });
  return *suffixes;
}

// Curated high-signal dataset of 250+ cross-site tracker domains.
const std::unordered_map<std::string, TrackerEntry>& TrackerDataset() {
  static const std::unordered_map<std::string, TrackerEntry>* db = []() {
    auto* m = new std::unordered_map<std::string, TrackerEntry>();
    auto add = [&](const char* domain, const char* entity, const char* owner, const char* cat, bool strict = false) {
      (*m)[domain] = TrackerEntry{entity, owner, cat, strict};
    };

    // --- Google (Advertising & Analytics) ---
    add("doubleclick.net", "google.com", "Google", "advertising");
    add("googlesyndication.com", "google.com", "Google", "advertising");
    add("googleadservices.com", "google.com", "Google", "advertising");
    add("adservice.google.com", "google.com", "Google", "advertising");
    add("pagead2.googlesyndication.com", "google.com", "Google", "advertising");
    add("tpc.googlesyndication.com", "google.com", "Google", "advertising");
    add("imasdk.googleapis.com", "google.com", "Google", "advertising", true);
    add("google-analytics.com", "google.com", "Google", "analytics");
    add("ssl.google-analytics.com", "google.com", "Google", "analytics");
    add("www.google-analytics.com", "google.com", "Google", "analytics");
    add("googletagmanager.com", "google.com", "Google", "analytics");
    add("googletagservices.com", "google.com", "Google", "advertising");
    add("fundingchoicesmessages.google.com", "google.com", "Google", "analytics");
    add("analytics.google.com", "google.com", "Google", "analytics");
    add("firebaseanalytics.googleapis.com", "google.com", "Google", "analytics");
    add("app-measurement.com", "google.com", "Google", "analytics");
    add("dartsearch.net", "google.com", "Google", "advertising");
    add("invitemedia.com", "google.com", "Google", "advertising");
    add("admeld.com", "google.com", "Google", "advertising");
    add("urchin.com", "google.com", "Google", "analytics");
    add("2mdn.net", "google.com", "Google", "advertising");
    add("crashlyticsreports-pa.googleapis.com", "google.com", "Google", "analytics");

    // --- Meta / Facebook (Advertising & Social) ---
    add("connect.facebook.net", "facebook.com", "Meta", "social");
    add("pixel.facebook.com", "facebook.com", "Meta", "advertising");
    add("an.facebook.com", "facebook.com", "Meta", "advertising");
    add("graph.facebook.com", "facebook.com", "Meta", "social", true);
    add("atlassolutions.com", "facebook.com", "Meta", "advertising");
    add("atdmt.com", "facebook.com", "Meta", "advertising");
    add("liverail.com", "facebook.com", "Meta", "advertising");
    add("fbcdn.net", "facebook.com", "Meta", "social", true);

    // --- Microsoft (Advertising, Analytics, Session Replay) ---
    add("clarity.ms", "microsoft.com", "Microsoft", "sessionReplay");
    add("bat.bing.com", "microsoft.com", "Microsoft", "advertising");
    add("c.bing.com", "microsoft.com", "Microsoft", "advertising");
    add("ads.msn.com", "microsoft.com", "Microsoft", "advertising");
    add("ads1.msn.com", "microsoft.com", "Microsoft", "advertising");
    add("c.msn.com", "microsoft.com", "Microsoft", "analytics");
    add("flex.msn.com", "microsoft.com", "Microsoft", "advertising");
    add("adnxs.com", "microsoft.com", "Xandr (Microsoft)", "advertising");
    add("appnexus.com", "microsoft.com", "Xandr (Microsoft)", "advertising");
    add("adnxs-simple.com", "microsoft.com", "Xandr (Microsoft)", "advertising");
    add("dc.services.visualstudio.com", "microsoft.com", "Microsoft", "analytics");
    add("browser.events.data.msn.com", "microsoft.com", "Microsoft", "analytics");
    add("mobileads.msn.com", "microsoft.com", "Microsoft", "advertising");
    add("r.msn.com", "microsoft.com", "Microsoft", "analytics");

    // --- Amazon (Advertising & Analytics) ---
    add("amazon-adsystem.com", "amazon.com", "Amazon", "advertising");
    add("aax-us-east.amazon-adsystem.com", "amazon.com", "Amazon", "advertising");
    add("fls-na.amazon-adsystem.com", "amazon.com", "Amazon", "advertising");
    add("serving-sys.com", "amazon.com", "Amazon", "advertising");
    add("sizmek.com", "amazon.com", "Amazon", "advertising");
    add("peer39.com", "amazon.com", "Amazon", "advertising");
    add("associates-amazon.com", "amazon.com", "Amazon", "advertising");
    add("alexa.com", "amazon.com", "Amazon", "analytics");
    add("alexametrics.com", "amazon.com", "Amazon", "analytics");
    add("fls-na.amazon.com", "amazon.com", "Amazon", "analytics");

    // --- ByteDance / TikTok ---
    add("analytics.tiktok.com", "bytedance.com", "ByteDance", "analytics");
    add("ads.tiktok.com", "bytedance.com", "ByteDance", "advertising");
    add("business-api.tiktok.com", "bytedance.com", "ByteDance", "advertising");
    add("log.tiktokv.com", "bytedance.com", "ByteDance", "analytics");
    add("mon.tiktokv.com", "bytedance.com", "ByteDance", "analytics");
    add("mcs.tiktokw.us", "bytedance.com", "ByteDance", "analytics");
    add("pangle.io", "bytedance.com", "ByteDance", "advertising");

    // --- X / Twitter ---
    add("ads-twitter.com", "x.com", "X Corp", "advertising");
    add("ads.twitter.com", "x.com", "X Corp", "advertising");
    add("analytics.twitter.com", "x.com", "X Corp", "analytics");
    add("static.ads-twitter.com", "x.com", "X Corp", "advertising");
    add("ads-api.twitter.com", "x.com", "X Corp", "advertising");
    add("syndication.twitter.com", "x.com", "X Corp", "social", true);
    add("platform.twitter.com", "x.com", "X Corp", "social", true);

    // --- Adobe ---
    add("demdex.net", "adobe.com", "Adobe", "dataBroker");
    add("omtrdc.net", "adobe.com", "Adobe", "analytics");
    add("2o7.net", "adobe.com", "Adobe", "analytics");
    add("everesttech.net", "adobe.com", "Adobe", "advertising");
    add("everestjs.net", "adobe.com", "Adobe", "advertising");
    add("adobedtm.com", "adobe.com", "Adobe", "analytics");
    add("assets.adobedtm.com", "adobe.com", "Adobe", "analytics");
    add("tubemogul.com", "adobe.com", "Adobe", "advertising");
    add("marketo.net", "adobe.com", "Adobe (Marketo)", "emailTracking");
    add("marketo.com", "adobe.com", "Adobe (Marketo)", "emailTracking");
    add("mktoresp.com", "adobe.com", "Adobe (Marketo)", "emailTracking");
    add("mktdns.com", "adobe.com", "Adobe (Marketo)", "emailTracking");

    // --- Oracle ---
    add("bluekai.com", "oracle.com", "Oracle", "dataBroker");
    add("bkrtx.com", "oracle.com", "Oracle", "dataBroker");
    add("addthis.com", "oracle.com", "Oracle", "social");
    add("addthisedge.com", "oracle.com", "Oracle", "social");
    add("moatads.com", "oracle.com", "Oracle", "analytics");
    add("moatpixel.com", "oracle.com", "Oracle", "analytics");
    add("adsymptotic.com", "oracle.com", "Oracle", "dataBroker");
    add("eloqua.com", "oracle.com", "Oracle", "emailTracking");
    add("en25.com", "oracle.com", "Oracle", "emailTracking");
    add("responsys.net", "oracle.com", "Oracle", "emailTracking");
    add("maxymiser.net", "oracle.com", "Oracle", "analytics");
    add("grapeshot.co.uk", "oracle.com", "Oracle", "advertising");

    // --- Salesforce ---
    add("krxd.net", "salesforce.com", "Salesforce", "dataBroker");
    add("pardot.com", "salesforce.com", "Salesforce", "emailTracking");
    add("exacttarget.com", "salesforce.com", "Salesforce", "emailTracking");
    add("salesforceiq.com", "salesforce.com", "Salesforce", "emailTracking");
    add("evergage.com", "salesforce.com", "Salesforce", "analytics");
    add("evgnet.com", "salesforce.com", "Salesforce", "analytics");
    add("igodigital.com", "salesforce.com", "Salesforce", "analytics");

    // --- Major AdTech / DSP / SSP / Exchanges ---
    add("criteo.com", "criteo.com", "Criteo", "advertising");
    add("criteo.net", "criteo.com", "Criteo", "advertising");
    add("taboola.com", "taboola.com", "Taboola", "advertising");
    add("taboolasyndication.com", "taboola.com", "Taboola", "advertising");
    add("outbrain.com", "outbrain.com", "Outbrain", "advertising");
    add("outbrainimg.com", "outbrain.com", "Outbrain", "advertising");
    add("zemanta.com", "outbrain.com", "Outbrain", "advertising");
    add("scorecardresearch.com", "comscore.com", "comScore", "analytics");
    add("voicefive.com", "comscore.com", "comScore", "analytics");
    add("imrworldwide.com", "nielsen.com", "Nielsen", "analytics");
    add("exelator.com", "nielsen.com", "Nielsen", "dataBroker");
    add("quantserve.com", "quantcast.com", "Quantcast", "analytics");
    add("quantcount.com", "quantcast.com", "Quantcast", "analytics");
    add("pubmatic.com", "pubmatic.com", "PubMatic", "advertising");
    add("rubiconproject.com", "magnite.com", "Magnite", "advertising");
    add("telaria.com", "magnite.com", "Magnite", "advertising");
    add("spotxchange.com", "magnite.com", "Magnite", "advertising");
    add("openx.net", "openx.com", "OpenX", "advertising");
    add("openx.com", "openx.com", "OpenX", "advertising");
    add("adsrvr.org", "thetradedesk.com", "The Trade Desk", "advertising");
    add("casalemedia.com", "indexexchange.com", "Index Exchange", "advertising");
    add("indexww.com", "indexexchange.com", "Index Exchange", "advertising");
    add("3lift.com", "triplelift.com", "TripleLift", "advertising");
    add("bidswitch.net", "iponweb.com", "BidSwitch", "advertising");
    add("sharethrough.com", "sharethrough.com", "Sharethrough", "advertising");
    add("smartadserver.com", "equativ.com", "Equativ", "advertising");
    add("yieldmo.com", "yieldmo.com", "Yieldmo", "advertising");
    add("sovrn.com", "sovrn.com", "Sovrn", "advertising");
    add("lijit.com", "sovrn.com", "Sovrn", "advertising");
    add("mediamath.com", "mediamath.com", "MediaMath", "advertising");
    add("mathtag.com", "mediamath.com", "MediaMath", "advertising");
    add("rlcdn.com", "liveramp.com", "LiveRamp", "dataBroker");
    add("pippio.com", "liveramp.com", "LiveRamp", "dataBroker");
    add("acxiom-online.com", "acxiom.com", "Acxiom", "dataBroker");
    add("myvisualiq.net", "nielsen.com", "Nielsen", "analytics");
    add("media.net", "media.net", "Media.net", "advertising");
    add("adform.net", "adform.com", "Adform", "advertising");
    add("adroll.com", "nextroll.com", "NextRoll", "advertising");
    add("d.adroll.com", "nextroll.com", "NextRoll", "advertising");
    add("contextweb.com", "pulsepoint.com", "PulsePoint", "advertising");
    add("rhythmone.com", "rhythmone.com", "RhythmOne", "advertising");
    add("1rx.io", "rhythmone.com", "RhythmOne", "advertising");
    add("undertone.com", "undertone.com", "Undertone", "advertising");
    add("gumgum.com", "gumgum.com", "GumGum", "advertising");
    add("teads.tv", "teads.com", "Teads", "advertising");
    add("kargo.com", "kargo.com", "Kargo", "advertising");
    add("medianet.com", "media.net", "Media.net", "advertising");
    add("adition.com", "adition.com", "Adition", "advertising");
    add("ipredictive.com", "adelphic.com", "Adelphic", "advertising");
    add("revcontent.com", "revcontent.com", "Revcontent", "advertising");
    add("mgid.com", "mgid.com", "MGID", "advertising");
    add("nativo.com", "nativo.com", "Nativo", "advertising");
    add("postrelease.com", "nativo.com", "Nativo", "advertising");
    add("adblade.com", "adblade.com", "Adblade", "advertising");
    add("doubleverify.com", "doubleverify.com", "DoubleVerify", "analytics");
    add("integralads.com", "integralads.com", "Integral Ad Science", "analytics");
    add("adsafeprotected.com", "integralads.com", "Integral Ad Science", "analytics");
    add("spot.im", "openweb.com", "OpenWeb", "social", true);
    add("simpli.fi", "simpli.fi", "Simpli.fi", "advertising");
    add("eyeota.net", "eyeota.com", "Eyeota", "dataBroker");
    add("crwdcntrl.net", "lotame.com", "Lotame", "dataBroker");
    add("agkn.com", "neustar.biz", "Neustar", "dataBroker");
    add("nexac.com", "epsilon.com", "Epsilon", "dataBroker");
    add("dotomi.com", "epsilon.com", "Epsilon", "advertising");
    add("conversantmedia.com", "epsilon.com", "Epsilon", "advertising");
    add("ojrq.net", "cj.com", "CJ Affiliate", "advertising");
    add("anrdoezrs.net", "cj.com", "CJ Affiliate", "advertising");
    add("tkqlhce.com", "cj.com", "CJ Affiliate", "advertising");
    add("dpbolvw.net", "cj.com", "CJ Affiliate", "advertising");
    add("kqzyfj.com", "cj.com", "CJ Affiliate", "advertising");
    add("jdoqocy.com", "cj.com", "CJ Affiliate", "advertising");
    add("awltovhc.com", "cj.com", "CJ Affiliate", "advertising");
    add("click.linksynergy.com", "rakuten.com", "Rakuten Advertising", "advertising");
    add("shareasale.com", "awin.com", "Awin", "advertising");
    add("awin1.com", "awin.com", "Awin", "advertising");
    add("zenaps.com", "awin.com", "Awin", "advertising");
    add("go.skimresources.com", "skimlinks.com", "Skimlinks", "advertising");
    add("redirect.viglink.com", "sovrn.com", "Sovrn Commerce", "advertising");
    add("prf.hn", "partnerize.com", "Partnerize", "advertising");
    add("turn.com", "amobee.com", "Amobee", "advertising");
    add("tapad.com", "tapad.com", "Tapad", "dataBroker");
    add("drawbridge.com", "linkedin.com", "Drawbridge", "dataBroker");
    add("blueconic.net", "blueconic.com", "BlueConic", "dataBroker");
    add("permutive.com", "permutive.com", "Permutive", "dataBroker");
    add("permutive.app", "permutive.com", "Permutive", "dataBroker");
    add("id5-sync.com", "id5.io", "ID5", "dataBroker");
    add("liadm.com", "liveintent.com", "LiveIntent", "dataBroker");
    add("liveintent.com", "liveintent.com", "LiveIntent", "advertising");
    add("c1exchange.com", "c1exchange.com", "C1X", "advertising");
    add("sonobi.com", "sonobi.com", "Sonobi", "advertising");
    add("districtm.io", "sharethrough.com", "District M", "advertising");
    add("amazon-adsystem.co.uk", "amazon.com", "Amazon", "advertising");
    add("smartclip.net", "smartclip.tv", "Smartclip", "advertising");
    add("innovid.com", "innovid.com", "Innovid", "advertising");
    add("flashtalking.com", "mediaocean.com", "Flashtalking", "advertising");
    add("celtra.com", "celtra.com", "Celtra", "advertising");
    add("adscale.de", "stroeer.com", "Stroeer", "advertising");
    add("adswizz.com", "adswizz.com", "AdsWizz", "advertising");
    add("bidr.io", "beeswax.com", "Beeswax", "advertising");
    add("extend.tv", "extend.tv", "ZypMedia", "advertising");
    add("richaudience.com", "richaudience.com", "Rich Audience", "advertising");
    add("seedtag.com", "seedtag.com", "Seedtag", "advertising");
    add("connatix.com", "connatix.com", "Connatix", "advertising");
    add("anyclip.com", "anyclip.com", "AnyClip", "advertising");
    add("primis.tech", "primis.tech", "Primis", "advertising");
    add("jwpltx.com", "jwplayer.com", "JW Player", "analytics");

    // --- Session Replay & Heatmaps ---
    add("hotjar.com", "hotjar.com", "Hotjar", "sessionReplay");
    add("static.hotjar.com", "hotjar.com", "Hotjar", "sessionReplay");
    add("script.hotjar.com", "hotjar.com", "Hotjar", "sessionReplay");
    add("vars.hotjar.com", "hotjar.com", "Hotjar", "sessionReplay");
    add("fullstory.com", "fullstory.com", "FullStory", "sessionReplay");
    add("rs.fullstory.com", "fullstory.com", "FullStory", "sessionReplay");
    add("edge.fullstory.com", "fullstory.com", "FullStory", "sessionReplay");
    add("mouseflow.com", "mouseflow.com", "Mouseflow", "sessionReplay");
    add("cdn.mouseflow.com", "mouseflow.com", "Mouseflow", "sessionReplay");
    add("crazyegg.com", "crazyegg.com", "Crazy Egg", "sessionReplay");
    add("script.crazyegg.com", "crazyegg.com", "Crazy Egg", "sessionReplay");
    add("luckyorange.com", "luckyorange.com", "Lucky Orange", "sessionReplay");
    add("luckyorange.net", "luckyorange.com", "Lucky Orange", "sessionReplay");
    add("logrocket.io", "logrocket.com", "LogRocket", "sessionReplay");
    add("lr-ingest.io", "logrocket.com", "LogRocket", "sessionReplay");
    add("lr-in.com", "logrocket.com", "LogRocket", "sessionReplay");
    add("smartlook.com", "smartlook.com", "Smartlook", "sessionReplay");
    add("rec.smartlook.com", "smartlook.com", "Smartlook", "sessionReplay");
    add("inspectlet.com", "inspectlet.com", "Inspectlet", "sessionReplay");
    add("sessioncam.com", "sessioncam.com", "SessionCam", "sessionReplay");
    add("clicktale.net", "contentsquare.com", "Contentsquare", "sessionReplay");
    add("contentsquare.net", "contentsquare.com", "Contentsquare", "sessionReplay");
    add("quantummetric.com", "quantummetric.com", "Quantum Metric", "sessionReplay");
    add("glassboxdigital.io", "glassbox.com", "Glassbox", "sessionReplay");
    add("decibelinsight.net", "medallia.com", "Medallia", "sessionReplay");
    add("loggly.com", "solarwinds.com", "Loggly", "sessionReplay", true);

    // --- Product / Web Analytics & CDPs ---
    add("mixpanel.com", "mixpanel.com", "Mixpanel", "analytics");
    add("api.mixpanel.com", "mixpanel.com", "Mixpanel", "analytics");
    add("cdn.mxpnl.com", "mixpanel.com", "Mixpanel", "analytics");
    add("amplitude.com", "amplitude.com", "Amplitude", "analytics");
    add("api.amplitude.com", "amplitude.com", "Amplitude", "analytics");
    add("api2.amplitude.com", "amplitude.com", "Amplitude", "analytics");
    add("cdn.amplitude.com", "amplitude.com", "Amplitude", "analytics");
    add("segment.io", "twilio.com", "Segment", "analytics");
    add("segment.com", "twilio.com", "Segment", "analytics");
    add("api.segment.io", "twilio.com", "Segment", "analytics");
    add("cdn.segment.com", "twilio.com", "Segment", "analytics");
    add("heapanalytics.com", "heap.io", "Heap", "analytics");
    add("cdn.heapanalytics.com", "heap.io", "Heap", "analytics");
    add("pendo.io", "pendo.io", "Pendo", "analytics");
    add("cdn.pendo.io", "pendo.io", "Pendo", "analytics");
    add("data.pendo.io", "pendo.io", "Pendo", "analytics");
    add("posthog.com", "posthog.com", "PostHog", "analytics");
    add("app.posthog.com", "posthog.com", "PostHog", "analytics");
    add("us.i.posthog.com", "posthog.com", "PostHog", "analytics");
    add("eu.i.posthog.com", "posthog.com", "PostHog", "analytics");
    add("kissmetrics.com", "kissmetrics.io", "Kissmetrics", "analytics");
    add("kissmetrics.io", "kissmetrics.io", "Kissmetrics", "analytics");
    add("chartbeat.com", "chartbeat.com", "Chartbeat", "analytics");
    add("chartbeat.net", "chartbeat.com", "Chartbeat", "analytics");
    add("ping.chartbeat.net", "chartbeat.com", "Chartbeat", "analytics");
    add("parsely.com", "parse.ly", "Parse.ly", "analytics");
    add("pixel.parsely.com", "parse.ly", "Parse.ly", "analytics");
    add("clicky.com", "clicky.com", "Clicky", "analytics");
    add("getclicky.com", "clicky.com", "Clicky", "analytics");
    add("statcounter.com", "statcounter.com", "StatCounter", "analytics");
    add("matomo.cloud", "matomo.org", "Matomo", "analytics");
    add("piwik.pro", "piwik.pro", "Piwik PRO", "analytics");
    add("optimizely.com", "optimizely.com", "Optimizely", "analytics");
    add("logx.optimizely.com", "optimizely.com", "Optimizely", "analytics");
    add("visualwebsiteoptimizer.com", "vwo.com", "VWO", "analytics");
    add("dev.visualwebsiteoptimizer.com", "vwo.com", "VWO", "analytics");
    add("ab-tasty.com", "abtasty.com", "AB Tasty", "analytics");
    add("ariane.abtasty.com", "abtasty.com", "AB Tasty", "analytics");
    add("kameleoon.eu", "kameleoon.com", "Kameleoon", "analytics");
    add("launchdarkly.com", "launchdarkly.com", "LaunchDarkly", "analytics", true);
    add("snowplowanalytics.com", "snowplow.io", "Snowplow", "analytics");
    add("rudderlabs.com", "rudderstack.com", "RudderStack", "analytics");
    add("tealiumiq.com", "tealium.com", "Tealium", "analytics");
    add("tiqcdn.com", "tealium.com", "Tealium", "analytics");
    add("ensighten.com", "ensighten.com", "Ensighten", "analytics");
    add("nexus.ensighten.com", "ensighten.com", "Ensighten", "analytics");
    add("mparticle.com", "mparticle.com", "mParticle", "analytics");
    add("lytics.io", "lytics.com", "Lytics", "dataBroker");
    add("treasuredata.com", "treasuredata.com", "Treasure Data", "dataBroker");
    add("webtrekk.net", "mapp.com", "Mapp", "analytics");
    add("atinternet.com", "piano.io", "Piano / AT Internet", "analytics");
    add("xiti.com", "piano.io", "Piano / AT Internet", "analytics");
    add("tinypass.com", "piano.io", "Piano", "analytics", true);
    add("piano.io", "piano.io", "Piano", "analytics", true);

    // --- Mobile / Attribution / Marketing / CRM / Email Tracking ---
    add("braze.com", "braze.com", "Braze", "analytics");
    add("sdk.iad-01.braze.com", "braze.com", "Braze", "analytics");
    add("appboycdn.com", "braze.com", "Braze", "analytics");
    add("branch.io", "branch.io", "Branch", "analytics");
    add("bnc.lt", "branch.io", "Branch", "analytics");
    add("app.link", "branch.io", "Branch", "analytics");
    add("appsflyer.com", "appsflyer.com", "AppsFlyer", "analytics");
    add("websdk.appsflyer.com", "appsflyer.com", "AppsFlyer", "analytics");
    add("adjust.com", "adjust.com", "Adjust", "analytics");
    add("app.adjust.com", "adjust.com", "Adjust", "analytics");
    add("kochava.com", "kochava.com", "Kochava", "analytics");
    add("singular.net", "singular.net", "Singular", "analytics");
    add("onesignal.com", "onesignal.com", "OneSignal", "analytics");
    add("cdn.onesignal.com", "onesignal.com", "OneSignal", "analytics");
    add("hubspot.com", "hubspot.com", "HubSpot", "emailTracking", true);
    add("hs-analytics.net", "hubspot.com", "HubSpot", "analytics");
    add("js.hs-analytics.net", "hubspot.com", "HubSpot", "analytics");
    add("hs-scripts.com", "hubspot.com", "HubSpot", "analytics");
    add("hsforms.com", "hubspot.com", "HubSpot", "analytics", true);
    add("hsadspixel.net", "hubspot.com", "HubSpot", "advertising");
    add("track.hubspot.com", "hubspot.com", "HubSpot", "emailTracking");
    add("intercom.io", "intercom.io", "Intercom", "analytics", true);
    add("widget.intercom.io", "intercom.io", "Intercom", "analytics", true);
    add("api-iam.intercom.io", "intercom.io", "Intercom", "analytics", true);
    add("drift.com", "salesloft.com", "Drift", "analytics", true);
    add("js.driftt.com", "salesloft.com", "Drift", "analytics", true);
    add("klaviyo.com", "klaviyo.com", "Klaviyo", "emailTracking");
    add("static.klaviyo.com", "klaviyo.com", "Klaviyo", "emailTracking");
    add("a.klaviyo.com", "klaviyo.com", "Klaviyo", "emailTracking");
    add("list-manage.com", "mailchimp.com", "Mailchimp", "emailTracking");
    add("chimpstatic.com", "mailchimp.com", "Mailchimp", "emailTracking");
    add("sendgrid.net", "twilio.com", "SendGrid", "emailTracking");
    add("ct.sendgrid.net", "twilio.com", "SendGrid", "emailTracking");
    add("mandrillapp.com", "mailchimp.com", "Mailchimp", "emailTracking");
    add("mailgun.org", "sinch.com", "Mailgun", "emailTracking");
    add("constantcontact.com", "constantcontact.com", "Constant Contact", "emailTracking");
    add("campaignmonitor.com", "campaignmonitor.com", "Campaign Monitor", "emailTracking");
    add("createsend.com", "campaignmonitor.com", "Campaign Monitor", "emailTracking");
    add("drip.com", "drip.com", "Drip", "emailTracking");
    add("getdrip.com", "drip.com", "Drip", "emailTracking");
    add("activehosted.com", "activecampaign.com", "ActiveCampaign", "emailTracking");
    add("trackcmp.net", "activecampaign.com", "ActiveCampaign", "emailTracking");
    add("omnisend.com", "omnisend.com", "Omnisend", "emailTracking");
    add("sailthru.com", "sailthru.com", "Sailthru", "emailTracking");
    add("bounceexchange.com", "wunderkind.co", "Wunderkind", "advertising");
    add("wunderkind.co", "wunderkind.co", "Wunderkind", "advertising");
    add("attn.tv", "attentivemobile.com", "Attentive", "advertising");
    add("attentivemobile.com", "attentivemobile.com", "Attentive", "advertising");
    add("yotpo.com", "yotpo.com", "Yotpo", "analytics", true);
    add("iterable.com", "iterable.com", "Iterable", "emailTracking");
    add("customer.io", "customer.io", "Customer.io", "emailTracking");
    add("track.customer.io", "customer.io", "Customer.io", "emailTracking");
    add("clevertap.com", "clevertap.com", "CleverTap", "analytics");
    add("wzrk.co", "clevertap.com", "CleverTap", "analytics");
    add("moengage.com", "moengage.com", "MoEngage", "analytics");

    // --- Social Platforms & Pixels ---
    add("ct.pinterest.com", "pinterest.com", "Pinterest", "advertising");
    add("s.pinimg.com", "pinterest.com", "Pinterest", "social", true);
    add("trk.pinterest.com", "pinterest.com", "Pinterest", "analytics");
    add("log.pinterest.com", "pinterest.com", "Pinterest", "analytics");
    add("sc-static.net", "snap.com", "Snap", "advertising");
    add("tr.snapchat.com", "snap.com", "Snap", "advertising");
    add("px.ads.linkedin.com", "linkedin.com", "LinkedIn (Microsoft)", "advertising");
    add("snap.licdn.com", "linkedin.com", "LinkedIn (Microsoft)", "advertising");
    add("platform.linkedin.com", "linkedin.com", "LinkedIn (Microsoft)", "social", true);
    add("alb.reddit.com", "reddit.com", "Reddit", "advertising");
    add("events.reddit.com", "reddit.com", "Reddit", "advertising");
    add("events.redditmedia.com", "reddit.com", "Reddit", "advertising");
    add("redditstatic.com", "reddit.com", "Reddit", "advertising", true);
    add("pixel.reddit.com", "reddit.com", "Reddit", "advertising");
    add("ads.reddit.com", "reddit.com", "Reddit", "advertising");
    add("pixel.spotify.com", "spotify.com", "Spotify", "advertising");
    add("ads.yahoo.com", "yahoo.com", "Yahoo", "advertising");
    add("analytics.yahoo.com", "yahoo.com", "Yahoo", "analytics");
    add("sp.analytics.yahoo.com", "yahoo.com", "Yahoo", "analytics");
    add("advertising.com", "yahoo.com", "Yahoo", "advertising");
    add("yimg.com", "yahoo.com", "Yahoo", "advertising", true);
    add("gemini.yahoo.com", "yahoo.com", "Yahoo", "advertising");
    add("mc.yandex.ru", "yandex.ru", "Yandex", "analytics");
    add("an.yandex.ru", "yandex.ru", "Yandex", "advertising");
    add("yandexadexchange.net", "yandex.ru", "Yandex", "advertising");
    add("hm.baidu.com", "baidu.com", "Baidu", "analytics");
    add("cpro.baidu.com", "baidu.com", "Baidu", "advertising");
    add("pos.baidu.com", "baidu.com", "Baidu", "advertising");
    add("top-fwz1.mail.ru", "vk.com", "VK", "analytics");
    add("vk.com", "vk.com", "VK", "social", true);
    add("ad.mail.ru", "vk.com", "VK", "advertising");
    add("t.co", "x.com", "X Corp", "advertising");
    add("quora.com", "quora.com", "Quora", "advertising", true);
    add("q.quora.com", "quora.com", "Quora", "advertising");
    add("a.quora.com", "quora.com", "Quora", "advertising");
    add("px.tvpixel.com", "tvpixel.com", "TVPixel", "advertising");
    add("px.mountain.com", "mountain.com", "MNTN", "advertising");

    // --- Fingerprinting ---
    add("fpjs.io", "fingerprint.com", "FingerprintJS", "fingerprinting");
    add("fpcdn.io", "fingerprint.com", "FingerprintJS", "fingerprinting");
    add("api.fpjs.io", "fingerprint.com", "FingerprintJS", "fingerprinting");
    add("fingerprintjs.com", "fingerprint.com", "FingerprintJS", "fingerprinting");
    add("fpt.dfp.microsoft.com", "microsoft.com", "Microsoft", "fingerprinting");
    add("iovation.com", "transunion.com", "TransUnion (iovation)", "fingerprinting", true);
    add("mpsnare.iesnare.com", "transunion.com", "TransUnion (iovation)", "fingerprinting", true);
    add("threatmetrix.com", "lexisnexis.com", "LexisNexis ThreatMetrix", "fingerprinting", true);
    add("online-metrix.net", "lexisnexis.com", "LexisNexis ThreatMetrix", "fingerprinting", true);
    add("maxmind.com", "maxmind.com", "MaxMind", "fingerprinting");
    add("device.maxmind.com", "maxmind.com", "MaxMind", "fingerprinting");
    add("px-cloud.net", "humansecurity.com", "HUMAN Security", "fingerprinting", true);
    add("perimeterx.net", "humansecurity.com", "HUMAN Security", "fingerprinting", true);
    add("kaptcha.com", "kount.com", "Kount", "fingerprinting", true);
    add("siftscience.com", "sift.com", "Sift", "fingerprinting", true);
    add("cdn.siftscience.com", "sift.com", "Sift", "fingerprinting", true);
    add("forter.com", "forter.com", "Forter", "fingerprinting", true);

    // --- Cryptomining ---
    add("coinhive.com", "coinhive.com", "Coinhive", "cryptomining");
    add("coin-hive.com", "coinhive.com", "Coinhive", "cryptomining");
    add("authedmine.com", "coinhive.com", "Coinhive", "cryptomining");
    add("crypto-loot.com", "crypto-loot.com", "CryptoLoot", "cryptomining");
    add("cryptoloot.pro", "crypto-loot.com", "CryptoLoot", "cryptomining");
    add("jsecoin.com", "jsecoin.com", "JSEcoin", "cryptomining");
    add("minero.cc", "minero.cc", "Minero", "cryptomining");
    add("coinimp.com", "coinimp.com", "CoinIMP", "cryptomining");
    add("webminepool.com", "webminepool.com", "WebMinePool", "cryptomining");
    add("monerominer.rocks", "monerominer.rocks", "MoneroMiner", "cryptomining");

    // --- Strict-only Error Monitoring / RUM Telemetry ---
    add("sentry.io", "sentry.io", "Sentry", "analytics", true);
    add("ingest.sentry.io", "sentry.io", "Sentry", "analytics", true);
    add("ingest.us.sentry.io", "sentry.io", "Sentry", "analytics", true);
    add("browser.sentry-cdn.com", "sentry.io", "Sentry", "analytics", true);
    add("browser-intake-datadoghq.com", "datadoghq.com", "Datadog", "analytics", true);
    add("rum.browser-intake-datadoghq.com", "datadoghq.com", "Datadog", "analytics", true);
    add("datadoghq-browser-agent.com", "datadoghq.com", "Datadog", "analytics", true);
    add("nr-data.net", "newrelic.com", "New Relic", "analytics", true);
    add("js-agent.newrelic.com", "newrelic.com", "New Relic", "analytics", true);
    add("bam.nr-data.net", "newrelic.com", "New Relic", "analytics", true);
    add("bugsnag.com", "smartbear.com", "Bugsnag", "analytics", true);
    add("notify.bugsnag.com", "smartbear.com", "Bugsnag", "analytics", true);
    add("sessions.bugsnag.com", "smartbear.com", "Bugsnag", "analytics", true);
    add("rollbar.com", "rollbar.com", "Rollbar", "analytics", true);
    add("api.rollbar.com", "rollbar.com", "Rollbar", "analytics", true);
    add("raygun.io", "raygun.com", "Raygun", "analytics", true);
    add("api.raygun.io", "raygun.com", "Raygun", "analytics", true);
    add("dynatrace.com", "dynatrace.com", "Dynatrace", "analytics", true);
    add("js-cdn.dynatrace.com", "dynatrace.com", "Dynatrace", "analytics", true);
    add("appdynamics.com", "cisco.com", "AppDynamics", "analytics", true);
    add("eum-appdynamics.com", "cisco.com", "AppDynamics", "analytics", true);
    add("honeybadger.io", "honeybadger.io", "Honeybadger", "analytics", true);
    add("trackjs.com", "trackjs.com", "TrackJS", "analytics", true);

    return m;
  }();
  return *db;
}

// Parent entity -> owned first-party registrable domains for Zero-Breakage Same-Entity Exemption.
const std::unordered_map<std::string, std::unordered_set<std::string>>& EntityOwnedDomains() {
  static const std::unordered_map<std::string, std::unordered_set<std::string>>* map =
      new std::unordered_map<std::string, std::unordered_set<std::string>>({
          {"google.com",
           {"google.com", "youtube.com", "youtu.be", "gmail.com", "google.co.uk", "google.de",
            "google.fr", "google.co.jp", "google.ca", "google.com.au", "google.com.br",
            "google.com.tr", "google.es", "google.it", "google.nl", "google.co.in",
            "blogger.com", "blogspot.com", "android.com", "withgoogle.com", "waze.com",
            "chromium.org", "firebase.google.com", "chromebook.com"}},
          {"facebook.com",
           {"facebook.com", "fb.com", "instagram.com", "threads.net", "whatsapp.com",
            "messenger.com", "oculus.com", "meta.com", "workplace.com"}},
          {"microsoft.com",
           {"microsoft.com", "bing.com", "msn.com", "live.com", "outlook.com", "office.com",
            "office365.com", "xbox.com", "linkedin.com", "github.com", "skype.com", "azure.com",
            "visualstudio.com"}},
          {"amazon.com",
           {"amazon.com", "amazon.co.uk", "amazon.de", "amazon.fr", "amazon.co.jp", "amazon.ca",
            "amazon.in", "amazon.com.au", "amazon.es", "amazon.it", "twitch.tv", "imdb.com",
            "audible.com", "goodreads.com", "wholefoodsmarket.com", "zappos.com", "ring.com",
            "primevideo.com", "aws.amazon.com"}},
          {"bytedance.com", {"tiktok.com", "bytedance.com", "capcut.com", "lemon8-app.com"}},
          {"x.com", {"twitter.com", "x.com", "t.co"}},
          {"adobe.com", {"adobe.com", "behance.net", "typekit.net", "marketo.com"}},
          {"oracle.com", {"oracle.com", "java.com"}},
          {"salesforce.com", {"salesforce.com", "slack.com", "tableau.com", "heroku.com"}},
          {"yahoo.com", {"yahoo.com", "aol.com", "engadget.com", "techcrunch.com", "autoblog.com"}},
          {"pinterest.com", {"pinterest.com", "pinterest.co.uk", "pinterest.de", "pinterest.fr"}},
          {"snap.com", {"snapchat.com", "snap.com"}},
          {"reddit.com", {"reddit.com", "redd.it"}},
          {"yandex.ru", {"yandex.ru", "yandex.com", "ya.ru", "yandex.com.tr"}},
          {"baidu.com", {"baidu.com"}},
          {"vk.com", {"vk.com", "mail.ru"}},
          {"linkedin.com", {"linkedin.com", "microsoft.com"}},
          {"spotify.com", {"spotify.com"}},
          {"quora.com", {"quora.com"}},
          {"hubspot.com", {"hubspot.com"}},
          {"intercom.io", {"intercom.com", "intercom.io"}},
      });
  return *map;
}

const std::unordered_map<std::string, std::string>& DomainToEntityMap() {
  static const std::unordered_map<std::string, std::string>* rev = []() {
    auto* m = new std::unordered_map<std::string, std::string>();
    for (const auto& kv : EntityOwnedDomains()) {
      (*m)[kv.first] = kv.first;
      for (const auto& owned : kv.second) {
        (*m)[owned] = kv.first;
      }
    }
    return m;
  }();
  return *rev;
}

// Essential SSO / Auth / Payments / CAPTCHA / Static CDNs that must NEVER break.
const std::unordered_set<std::string>& EssentialAllowlistedExactOrSuffixHosts() {
  static const std::unordered_set<std::string>* allow = new std::unordered_set<std::string>({
      "accounts.google.com",
      "apis.google.com",
      "appleid.apple.com",
      "idmsa.apple.com",
      "appleid.cdn-apple.com",
      "gsa.apple.com",
      "icloud.com",
      "js.stripe.com",
      "checkout.stripe.com",
      "stripe.com",
      "challenges.cloudflare.com",
      "hcaptcha.com",
      "recaptcha.net",
      "paypal.com",
      "paypalobjects.com",
      "login.microsoftonline.com",
      "auth0.com",
      "okta.com",
      "fonts.googleapis.com",
      "fonts.gstatic.com",
      "ajax.googleapis.com",
      "cdn.jsdelivr.net",
      "cdnjs.cloudflare.com",
      "unpkg.com",
      "gstatic.com",
  });
  return *allow;
}

const std::unordered_set<std::string>& TrackingQueryParamsExact() {
  static const std::unordered_set<std::string>* params = new std::unordered_set<std::string>({
      "fbclid", "fb_action_ids", "fb_action_types", "fb_source", "fb_ref",
      "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "srsltid",
      "_ga", "_gl", "_gac",
      "msclkid", "ms_clkid",
      "mc_cid", "mc_eid",
      "_hsenc", "_hsmi", "hsctatracking", "mkt_tok",
      "oly_enc_id", "oly_anon_id",
      "ttclid", "twclid",
      "igshid", "igsh",
      "yclid", "ymclid", "_openstat",
      "vero_id", "wickedid", "rb_clickid", "s_cid", "irclickid", "epik",
      "guccounter", "guce_referrer", "guce_referrer_sig", "spm",
      "ef_id", "s_kwcid", "scid",
      "trk", "trk_contact", "trk_msg", "trk_module", "trk_sid",
      "vgo_ee", "__s", "ck_subscriber_id", "dm_i",
      "ml_subscriber", "ml_subscriber_hash",
      "zanpid", "sscid", "nb_klid", "_ke",
      "icid", "ncid", "cmpid",
      "ga_source", "ga_medium", "ga_campaign", "ga_term", "ga_content", "ga_place",
      "li_fat_id", "rdt_cid", "sc_cid",
      "elqtrackid", "elqtrack",
      "pk_campaign", "pk_kwd", "pk_source", "pk_medium", "pk_content", "pk_cid", "pk_cpn",
  });
  return *params;
}

const std::unordered_set<std::string>& BounceTrackerHosts() {
  static const std::unordered_set<std::string>* bounce = new std::unordered_set<std::string>({
      "l.facebook.com",
      "lm.facebook.com",
      "l.instagram.com",
      "l.messenger.com",
      "l.threads.net",
      "t.co",
      "click.linksynergy.com",
      "googleadservices.com",
      "doubleclick.net",
      "ad.doubleclick.net",
      "ojrq.net",
      "anrdoezrs.net",
      "tkqlhce.com",
      "dpbolvw.net",
      "kqzyfj.com",
      "jdoqocy.com",
      "awltovhc.com",
      "shareasale.com",
      "awin1.com",
      "go.skimresources.com",
      "redirect.viglink.com",
      "go.redirectingat.com",
      "clickserve.dartsearch.net",
      "out.reddit.com",
      "away.vk.com",
      "prf.hn",
  });
  return *bounce;
}

bool IsDecimalDigits(std::string_view s) {
  if (s.empty()) return false;
  for (char c : s) {
    if (c < '0' || c > '9') return false;
  }
  return true;
}

bool ParseIPv4Octets(std::string_view host, int out[4]) {
  size_t pos = 0;
  for (int i = 0; i < 4; ++i) {
    size_t dot = (i < 3) ? host.find('.', pos) : host.size();
    if (dot == std::string_view::npos || dot <= pos) return false;
    std::string_view part = host.substr(pos, dot - pos);
    if (part.size() > 3 || !IsDecimalDigits(part)) return false;
    int val = 0;
    for (char c : part) {
      val = val * 10 + (c - '0');
    }
    if (val < 0 || val > 255) return false;
    out[i] = val;
    pos = dot + 1;
  }
  return pos == host.size() + 1;
}

std::string URLDecodeLower(std::string_view s) {
  std::string out;
  out.reserve(s.size());
  for (size_t i = 0; i < s.size(); ++i) {
    char c = s[i];
    if (c == '%' && i + 2 < s.size() &&
        std::isxdigit(static_cast<unsigned char>(s[i + 1])) &&
        std::isxdigit(static_cast<unsigned char>(s[i + 2]))) {
      auto hexVal = [](char h) -> int {
        if (h >= '0' && h <= '9') return h - '0';
        if (h >= 'a' && h <= 'f') return h - 'a' + 10;
        return h - 'A' + 10;
      };
      char decoded = static_cast<char>((hexVal(s[i + 1]) << 4) | hexVal(s[i + 2]));
      out.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(decoded))));
      i += 2;
    } else {
      out.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
    }
  }
  return out;
}

bool ReadBoolDefault(NSUserDefaults* ud, NSString* key, bool fallback) {
  id val = [ud objectForKey:key];
  if (val == nil) return fallback;
  return [ud boolForKey:key] ? true : false;
}

int ReadIntDefault(NSUserDefaults* ud, NSString* key, int fallback) {
  id val = [ud objectForKey:key];
  if (val == nil) return fallback;
  return static_cast<int>([ud integerForKey:key]);
}

bool BoolFromPolicy(NSDictionary<NSString*, id>* policy, NSString* key, bool fallback) {
  id val = policy[key];
  if ([val isKindOfClass:[NSNumber class]]) {
    return [(NSNumber*)val boolValue] ? true : false;
  }
  return fallback;
}

int IntFromPolicy(NSDictionary<NSString*, id>* policy, NSString* key, int fallback) {
  id val = policy[key];
  if ([val isKindOfClass:[NSNumber class]]) {
    return [(NSNumber*)val intValue];
  }
  return fallback;
}

void PopulateHostSetFromPolicy(NSDictionary<NSString*, id>* policy,
                               NSString* key,
                               std::unordered_set<std::string>& out) {
  id arr = policy[key];
  if (![arr isKindOfClass:[NSArray class]]) return;
  for (id item in (NSArray*)arr) {
    if (![item isKindOfClass:[NSString class]]) continue;
    const char* utf8 = [(NSString*)item UTF8String];
    if (!utf8) continue;
    std::string norm = NormalizeHost(utf8);
    if (!norm.empty()) {
      out.insert(std::move(norm));
    }
  }
}

bool HostMatchesDomainOrSubdomain(std::string_view host, std::string_view domain) {
  if (host == domain) return true;
  if (host.size() > domain.size() &&
      host[host.size() - domain.size() - 1] == '.' &&
      host.compare(host.size() - domain.size(), domain.size(), domain) == 0) {
    return true;
  }
  return false;
}

}  // namespace

std::string ToLowerASCII(std::string_view s) {
  std::string out;
  out.reserve(s.size());
  for (char c : s) {
    out.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
  }
  return out;
}

std::string NormalizeHostRaw(std::string_view host) {
  std::string h = ToLowerASCII(host);
  while (!h.empty() && h.back() == '.') {
    h.pop_back();
  }
  if (h.size() >= 2 && h.front() == '[' && h.back() == ']') {
    h = h.substr(1, h.size() - 2);
  }
  return h;
}

std::string NormalizeHost(std::string_view host) {
  std::string h = NormalizeHostRaw(host);
  if (h.size() > 4 && h.rfind("www.", 0) == 0) {
    h.erase(0, 4);
  }
  return h;
}

std::string ExtractSchemeFromURL(std::string_view url) {
  size_t colon = url.find(':');
  if (colon == std::string_view::npos || colon == 0) return "";
  for (size_t i = 0; i < colon; ++i) {
    unsigned char c = static_cast<unsigned char>(url[i]);
    if (!std::isalnum(c) && c != '+' && c != '-' && c != '.') {
      return "";
    }
  }
  return ToLowerASCII(url.substr(0, colon));
}

static std::string_view ExtractAuthorityView(std::string_view url) {
  size_t scheme_end = url.find("://");
  if (scheme_end == std::string_view::npos) return "";
  size_t auth_start = scheme_end + 3;
  size_t auth_end = url.find_first_of("/?#", auth_start);
  if (auth_end == std::string_view::npos) auth_end = url.size();
  std::string_view authority = url.substr(auth_start, auth_end - auth_start);
  size_t at_pos = authority.rfind('@');
  if (at_pos != std::string_view::npos) {
    authority = authority.substr(at_pos + 1);
  }
  return authority;
}

std::string ExtractHostFromURL(std::string_view url) {
  std::string_view authority = ExtractAuthorityView(url);
  if (authority.empty()) return "";
  if (authority.front() == '[') {
    size_t close = authority.find(']');
    if (close != std::string_view::npos) {
      return NormalizeHostRaw(authority.substr(0, close + 1));
    }
  }
  size_t colon = authority.rfind(':');
  if (colon != std::string_view::npos) {
    authority = authority.substr(0, colon);
  }
  return NormalizeHostRaw(authority);
}

std::string ExtractPortFromURL(std::string_view url) {
  std::string_view authority = ExtractAuthorityView(url);
  if (authority.empty()) return "";
  if (authority.front() == '[') {
    size_t close = authority.find(']');
    if (close == std::string_view::npos) return "";
    if (close + 1 < authority.size() && authority[close + 1] == ':') {
      return std::string(authority.substr(close + 2));
    }
    return "";
  }
  size_t colon = authority.rfind(':');
  if (colon != std::string_view::npos) {
    return std::string(authority.substr(colon + 1));
  }
  return "";
}

std::string ExtractOriginFromURL(std::string_view url) {
  std::string scheme = ExtractSchemeFromURL(url);
  if (scheme.empty()) return "";
  std::string_view authority = ExtractAuthorityView(url);
  if (authority.empty()) return "";

  std::string host;
  std::string port;
  if (authority.front() == '[') {
    size_t close = authority.find(']');
    if (close == std::string_view::npos) return "";
    host = ToLowerASCII(authority.substr(0, close + 1));
    if (close + 1 < authority.size() && authority[close + 1] == ':') {
      port = std::string(authority.substr(close + 2));
    }
  } else {
    size_t colon = authority.rfind(':');
    if (colon != std::string_view::npos) {
      host = NormalizeHostRaw(authority.substr(0, colon));
      port = std::string(authority.substr(colon + 1));
    } else {
      host = NormalizeHostRaw(authority);
    }
  }
  if (host.empty()) return "";

  if ((scheme == "https" && port == "443") || (scheme == "http" && port == "80")) {
    port.clear();
  }
  std::string origin = scheme + "://" + host;
  if (!port.empty()) {
    origin += ":" + port;
  }
  origin.push_back('/');
  return origin;
}

bool IsIPAddressOrLocalhost(std::string_view host) {
  std::string h = NormalizeHostRaw(host);
  if (h.empty()) return false;
  if (h == "localhost" ||
      (h.size() > 10 && h.compare(h.size() - 10, 10, ".localhost") == 0) ||
      (h.size() > 6 && h.compare(h.size() - 6, 6, ".local") == 0)) {
    return true;
  }
  if (h.find(':') != std::string::npos) {
    return true;  // IPv6
  }
  int octets[4] = {};
  return ParseIPv4Octets(h, octets);
}

static bool IsPrivateIPv4Octets(const int oct[4]) {
  if (oct[0] == 127 || oct[0] == 10 || oct[0] == 0) return true;
  if (oct[0] == 192 && oct[1] == 168) return true;
  if (oct[0] == 172 && oct[1] >= 16 && oct[1] <= 31) return true;
  if (oct[0] == 169 && oct[1] == 254) return true;
  if (oct[0] == 100 && oct[1] >= 64 && oct[1] <= 127) return true;  // RFC 6598 CGNAT
  return false;
}

static bool HasDomainSuffix(std::string_view host, std::string_view suffix) {
  return host.size() > suffix.size() &&
         host.compare(host.size() - suffix.size(), suffix.size(), suffix) == 0;
}

bool IsPrivateOrLocalNetworkHost(std::string_view host) {
  std::string h = NormalizeHostRaw(host);
  if (h.empty()) return false;
  if (h == "localhost" ||
      HasDomainSuffix(h, ".localhost") ||
      HasDomainSuffix(h, ".local") ||
      HasDomainSuffix(h, ".lan") ||
      HasDomainSuffix(h, ".home.arpa") ||
      HasDomainSuffix(h, ".internal")) {
    return true;
  }
  if (h == "::1" || h == "0:0:0:0:0:0:0:1" || h == "::") {
    return true;
  }
  if (h.find(':') != std::string::npos) {
    if (h.rfind("fe80:", 0) == 0 || h.rfind("fc", 0) == 0 || h.rfind("fd", 0) == 0) {
      return true;
    }
    // Check IPv4-mapped IPv6 ::ffff:a.b.c.d or ::ffff:xxxx:yyyy
    if (h.rfind("::ffff:", 0) == 0) {
      std::string tail = h.substr(7);
      int oct[4] = {};
      if (ParseIPv4Octets(tail, oct)) {
        return IsPrivateIPv4Octets(oct);
      }
      size_t colon = tail.find(':');
      if (colon != std::string::npos) {
        std::string hiStr = tail.substr(0, colon);
        std::string loStr = tail.substr(colon + 1);
        auto parseHex16 = [](const std::string& s, int& out) -> bool {
          if (s.empty() || s.size() > 4) return false;
          int v = 0;
          for (char c : s) {
            if (!std::isxdigit(static_cast<unsigned char>(c))) return false;
            int d = (c >= '0' && c <= '9') ? (c - '0')
                    : ((c >= 'a' && c <= 'f') ? (c - 'a' + 10) : (c - 'A' + 10));
            v = (v << 4) | d;
          }
          out = v;
          return true;
        };
        int hi = 0, lo = 0;
        if (parseHex16(hiStr, hi) && parseHex16(loStr, lo)) {
          oct[0] = (hi >> 8) & 0xFF;
          oct[1] = hi & 0xFF;
          oct[2] = (lo >> 8) & 0xFF;
          oct[3] = lo & 0xFF;
          return IsPrivateIPv4Octets(oct);
        }
      }
    }
    return false;
  }
  // Single-label LAN host (no dots and not IPv6)
  if (h.find('.') == std::string::npos) {
    return true;
  }
  int oct[4] = {};
  if (!ParseIPv4Octets(h, oct)) {
    return false;
  }
  return IsPrivateIPv4Octets(oct);
}

std::string RegistrableDomain(std::string_view host) {
  std::string h = NormalizeHostRaw(host);
  if (h.empty()) return "";
  if (IsIPAddressOrLocalhost(h)) return h;

  std::vector<std::string> labels;
  size_t start = 0;
  while (start < h.size()) {
    size_t dot = h.find('.', start);
    if (dot == std::string::npos) dot = h.size();
    if (dot > start) {
      labels.push_back(h.substr(start, dot - start));
    }
    start = dot + 1;
  }
  if (labels.size() <= 2) {
    return h;
  }

  const size_t n = labels.size();
  std::string tail2 = labels[n - 2] + "." + labels[n - 1];
  if (MultiPartPublicSuffixes().count(tail2) > 0 && n >= 3) {
    return labels[n - 3] + "." + tail2;
  }
  return tail2;
}

bool IsSameOriginURL(std::string_view url_a, std::string_view url_b) {
  std::string oa = ExtractOriginFromURL(url_a);
  std::string ob = ExtractOriginFromURL(url_b);
  return !oa.empty() && oa == ob;
}

std::string UpgradeURLSchemeToHTTPS(std::string_view http_url) {
  if (http_url.size() >= 7 && ToLowerASCII(http_url.substr(0, 7)) == "http://") {
    std::string upgraded = std::string("https://") + std::string(http_url.substr(7));
    size_t auth_start = 8;  // after "https://"
    size_t auth_end = upgraded.find_first_of("/?#", auth_start);
    if (auth_end == std::string::npos) auth_end = upgraded.size();
    std::string_view authority(upgraded.data() + auth_start, auth_end - auth_start);
    size_t at_pos = authority.rfind('@');
    size_t host_rel_start = (at_pos == std::string_view::npos) ? 0 : (at_pos + 1);
    std::string_view hostport = authority.substr(host_rel_start);
    size_t port_colon = std::string_view::npos;
    if (!hostport.empty() && hostport.front() == '[') {
      size_t close = hostport.find(']');
      if (close != std::string_view::npos && close + 1 < hostport.size() && hostport[close + 1] == ':') {
        port_colon = close + 1;
      }
    } else {
      port_colon = hostport.rfind(':');
    }
    if (port_colon != std::string_view::npos && hostport.substr(port_colon + 1) == "80") {
      size_t abs_colon = auth_start + host_rel_start + port_colon;
      upgraded.erase(abs_colon, 3);  // strip ":80"
    }
    return upgraded;
  }
  return std::string(http_url);
}

bool PolicySnapshot::IsSiteProtectionEnabled(std::string_view page_host) const {
  std::string norm = NormalizeHost(page_host);
  if (!norm.empty()) {
    if (content_blockers_disabled_hosts.count(norm) > 0) return false;
    if (content_blockers_enabled_hosts.count(norm) > 0) return true;
  }
  return content_blockers_default == 0;
}

SXPrivacyEngine& SXPrivacyEngine::Shared() {
  static SXPrivacyEngine* instance = new SXPrivacyEngine();
  return *instance;
}

SXPrivacyEngine::SXPrivacyEngine()
    : snapshot_(std::make_shared<PolicySnapshot>()),
      normal_session_salt_(GenerateRandomHexSalt32()),
      incognito_session_salt_(GenerateRandomHexSalt32()) {}

std::string SXPrivacyEngine::GenerateRandomHexSalt32() {
  uint8_t bytes[16] = {};
  arc4random_buf(bytes, sizeof(bytes));
  static constexpr char kHex[] = "0123456789abcdef";
  std::string out;
  out.reserve(32);
  for (uint8_t b : bytes) {
    out.push_back(kHex[(b >> 4) & 0xF]);
    out.push_back(kHex[b & 0xF]);
  }
  return out;
}

void SXPrivacyEngine::InitializeDefaultsFromUserDefaults() {
  @autoreleasepool {
    NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
    auto next = std::make_shared<PolicySnapshot>();
    next->prevent_cross_site_tracking = ReadBoolDefault(ud, @"Safarium.Pref.PreventCrossSiteTracking", true);
    next->block_all_cookies = ReadBoolDefault(ud, @"Safarium.Pref.BlockAllCookies", false);
    next->advanced_fingerprint = ReadBoolDefault(ud, @"Safarium.Pref.AdvancedFingerprint", true);
    next->advanced_fingerprint_scope = ReadIntDefault(ud, @"Safarium.Pref.AdvancedFingerprintScope", 1);
    next->global_privacy_control = ReadBoolDefault(ud, @"Safarium.Pref.GlobalPrivacyControl", false);
    next->https_only_mode = ReadBoolDefault(ud, @"Safarium.Pref.HTTPSOnlyMode", true);
    next->warn_http = ReadBoolDefault(ud, @"Safarium.Pref.WarnHTTP", false);
    next->strip_tracking_params = ReadBoolDefault(ud, @"Safarium.Pref.StripTrackingParams", true);
    next->referrer_trimming = ReadBoolDefault(ud, @"Safarium.Pref.ReferrerTrimming", true);
    next->webrtc_ip_protection = ReadBoolDefault(ud, @"Safarium.Pref.WebRTCIPProtection", true);
    next->protection_level = ReadIntDefault(ud, @"Safarium.Pref.PrivacyProtectionLevel",
                                            ReadIntDefault(ud, @"Safarium.Pref.ProtectionLevel", 0));
    next->content_blockers_default = ReadIntDefault(ud, @"Safarium.SiteDefault.Content Blockers", 0);
    next->microphone_default = ReadIntDefault(ud, @"Safarium.SiteDefault.Microphone", 0);
    next->camera_default = ReadIntDefault(ud, @"Safarium.SiteDefault.Camera", 0);

    NSString* prefix = @"Safarium.SitePolicy.Content Blockers.";
    NSString* micPrefix = @"Safarium.SitePolicy.Microphone.";
    NSString* camPrefix = @"Safarium.SitePolicy.Camera.";
    NSDictionary<NSString*, id>* all = [ud dictionaryRepresentation];
    for (NSString* key in all) {
      if ([key hasPrefix:prefix]) {
        NSString* host = [key substringFromIndex:prefix.length];
        if (host.length == 0 || !host.UTF8String) continue;
        std::string norm = NormalizeHost(host.UTF8String);
        if (norm.empty()) continue;
        NSInteger idx = [ud integerForKey:key];
        if (idx == 1) {
          next->content_blockers_disabled_hosts.insert(std::move(norm));
        } else if (idx == 0) {
          next->content_blockers_enabled_hosts.insert(std::move(norm));
        }
      } else if ([key hasPrefix:micPrefix]) {
        NSString* host = [key substringFromIndex:micPrefix.length];
        if (host.length == 0 || !host.UTF8String) continue;
        std::string norm = NormalizeHost(host.UTF8String);
        if (!norm.empty() && [ud integerForKey:key] == 2) {
          next->microphone_allowed_hosts.insert(std::move(norm));
        }
      } else if ([key hasPrefix:camPrefix]) {
        NSString* host = [key substringFromIndex:camPrefix.length];
        if (host.length == 0 || !host.UTF8String) continue;
        std::string norm = NormalizeHost(host.UTF8String);
        if (!norm.empty() && [ud integerForKey:key] == 2) {
          next->camera_allowed_hosts.insert(std::move(norm));
        }
      }
    }

    std::lock_guard<std::mutex> lock(policy_mutex_);
    snapshot_ = std::move(next);
  }
}

std::shared_ptr<const PolicySnapshot> SXPrivacyEngine::UpdatePolicyFromDictionary(
    NSDictionary<NSString*, id>* policy) {
  auto next = std::make_shared<PolicySnapshot>();
  next->prevent_cross_site_tracking = BoolFromPolicy(policy, @"preventCrossSiteTracking", true);
  next->block_all_cookies = BoolFromPolicy(policy, @"blockAllCookies", false);
  next->advanced_fingerprint = BoolFromPolicy(policy, @"advancedFingerprint", true);
  next->advanced_fingerprint_scope = IntFromPolicy(policy, @"advancedFingerprintScope", 1);
  next->global_privacy_control = BoolFromPolicy(policy, @"globalPrivacyControl", false);
  next->https_only_mode = BoolFromPolicy(policy, @"httpsOnlyMode", true);
  next->warn_http = BoolFromPolicy(policy, @"warnHTTP", false);
  next->strip_tracking_params = BoolFromPolicy(policy, @"stripTrackingParams", true);
  next->referrer_trimming = BoolFromPolicy(policy, @"referrerTrimming", true);
  next->webrtc_ip_protection = BoolFromPolicy(policy, @"webrtcIPProtection", true);
  next->protection_level = IntFromPolicy(policy, @"protectionLevel", 0);
  next->content_blockers_default = IntFromPolicy(policy, @"contentBlockersDefault", 0);
  next->microphone_default = IntFromPolicy(policy, @"microphoneDefault", 0);
  next->camera_default = IntFromPolicy(policy, @"cameraDefault", 0);
  PopulateHostSetFromPolicy(policy, @"contentBlockersDisabledHosts", next->content_blockers_disabled_hosts);
  PopulateHostSetFromPolicy(policy, @"contentBlockersEnabledHosts", next->content_blockers_enabled_hosts);
  PopulateHostSetFromPolicy(policy, @"microphoneAllowedHosts", next->microphone_allowed_hosts);
  PopulateHostSetFromPolicy(policy, @"cameraAllowedHosts", next->camera_allowed_hosts);

  {
    std::lock_guard<std::mutex> lock(policy_mutex_);
    snapshot_ = next;
  }
  return next;
}

std::shared_ptr<const PolicySnapshot> SXPrivacyEngine::Snapshot() const {
  std::lock_guard<std::mutex> lock(policy_mutex_);
  return snapshot_;
}

std::string SXPrivacyEngine::NormalSessionSalt() const {
  std::lock_guard<std::mutex> lock(salt_mutex_);
  return normal_session_salt_;
}

std::string SXPrivacyEngine::IncognitoSessionSalt() const {
  std::lock_guard<std::mutex> lock(salt_mutex_);
  return incognito_session_salt_;
}

std::string SXPrivacyEngine::ResetIncognitoSessionSalt() {
  std::lock_guard<std::mutex> lock(salt_mutex_);
  incognito_session_salt_ = GenerateRandomHexSalt32();
  return incognito_session_salt_;
}

void SXPrivacyEngine::ResetIncognitoState() {
  ResetIncognitoSessionSalt();
  std::lock_guard<std::mutex> lock(http_mutex_);
  incognito_allowed_http_hosts_.clear();
  incognito_http_fallback_hosts_.clear();
}

bool SXPrivacyEngine::IsEssentialAllowlistedHost(std::string_view req_host) const {
  std::string h = NormalizeHostRaw(req_host);
  if (h.empty()) return false;
  const auto& allow = EssentialAllowlistedExactOrSuffixHosts();
  if (allow.count(h) > 0) return true;

  // Walk parent suffixes while preserving exactness for subdomain-specific entries like accounts.google.com
  static const std::unordered_set<std::string>* suffix_allow = new std::unordered_set<std::string>({
      "stripe.com", "hcaptcha.com", "recaptcha.net", "paypal.com", "paypalobjects.com",
      "auth0.com", "okta.com", "gstatic.com", "appleid.apple.com",
  });
  for (const auto& dom : *suffix_allow) {
    if (HostMatchesDomainOrSubdomain(h, dom)) return true;
  }
  return false;
}

bool SXPrivacyEngine::IsSameEntity(std::string_view page_host,
                                   std::string_view req_host,
                                   std::string_view entity_domain) const {
  std::string page_reg = RegistrableDomain(page_host);
  std::string req_reg = RegistrableDomain(req_host);
  if (!page_reg.empty() && page_reg == req_reg) {
    return true;
  }
  if (page_reg.empty()) {
    return false;
  }

  const auto& rev = DomainToEntityMap();
  auto resolveEntity = [&](const std::string& reg) -> std::string {
    auto it = rev.find(reg);
    return (it != rev.end()) ? it->second : reg;
  };

  std::string page_entity = resolveEntity(page_reg);
  std::string req_entity = !entity_domain.empty()
                               ? NormalizeHostRaw(entity_domain)
                               : (!req_reg.empty() ? resolveEntity(req_reg) : "");
  if (req_entity.empty()) {
    return false;
  }
  if (req_entity == page_reg || req_entity == page_entity) {
    return true;
  }
  const auto& owned = EntityOwnedDomains();
  auto it = owned.find(req_entity);
  if (it != owned.end() && it->second.count(page_reg) > 0) {
    return true;
  }
  return false;
}

TrackerMatch SXPrivacyEngine::ClassifyTrackerHost(std::string_view req_host,
                                                  int protection_level,
                                                  bool include_strict) const {
  std::string h = NormalizeHostRaw(req_host);
  if (h.empty()) return {};

  const auto& db = TrackerDataset();
  std::string_view probe(h);
  while (!probe.empty()) {
    auto it = db.find(std::string(probe));
    if (it != db.end()) {
      const TrackerEntry& entry = it->second;
      if (entry.strict_only && !(include_strict || protection_level >= 1)) {
        return {};
      }
      TrackerMatch res;
      res.matched = true;
      res.matched_domain = std::string(probe);
      res.entity_domain = entry.entity_domain;
      res.owner_name = entry.owner_name;
      res.category = entry.category;
      return res;
    }
    size_t dot = probe.find('.');
    if (dot == std::string_view::npos) break;
    probe.remove_prefix(dot + 1);
  }
  return {};
}

SurrogateKind SXPrivacyEngine::DetectSurrogateKind(std::string_view req_url) const {
  std::string lower = ToLowerASCII(req_url);
  size_t q = lower.find('?');
  if (q != std::string::npos) lower.resize(q);
  size_t frag = lower.find('#');
  if (frag != std::string::npos) lower.resize(frag);

  std::string host = ExtractHostFromURL(lower);
  if (HostMatchesDomainOrSubdomain(host, "googletagmanager.com")) {
    if (lower.find("/gtag/js") != std::string::npos) return SurrogateKind::kGtag;
    if (lower.find("/gtm.js") != std::string::npos) return SurrogateKind::kGtm;
  }
  if (HostMatchesDomainOrSubdomain(host, "google-analytics.com")) {
    if (lower.find("/analytics.js") != std::string::npos) return SurrogateKind::kAnalytics;
    if (lower.find("/ga.js") != std::string::npos) return SurrogateKind::kGa;
  }
  if (HostMatchesDomainOrSubdomain(host, "connect.facebook.net")) {
    if (lower.find("/fbevents.js") != std::string::npos) return SurrogateKind::kFbEvents;
  }
  return SurrogateKind::kNone;
}

const char* SXPrivacyEngine::SurrogateScriptBody(SurrogateKind kind) {
  switch (kind) {
    case SurrogateKind::kGtag:
      return "window.dataLayer=window.dataLayer||[];"
             "window.gtag=window.gtag||function(){"
             "window.dataLayer.push(arguments);"
             "var a=arguments[2];"
             "if(a&&typeof a==='object'&&typeof a.event_callback==='function'){"
             "var cb=a.event_callback;setTimeout(function(){try{cb();}catch(_){}},0);}"
             "};";
    case SurrogateKind::kGtm:
      return "(function(){var w=window,d=w.dataLayer=w.dataLayer||[];"
             "w.google_tag_manager=w.google_tag_manager||{};"
             "for(var i=0;i<d.length;i++){var e=d[i];"
             "if(e&&typeof e.eventCallback==='function')try{e.eventCallback();}catch(_){}}"
             "var p=d.push;d.push=function(){for(var j=0;j<arguments.length;j++){var a=arguments[j];"
             "if(a&&typeof a.eventCallback==='function')try{a.eventCallback();}catch(_){}}"
             "return p.apply(d,arguments);};})();";
    case SurrogateKind::kAnalytics:
      return "(function(){var n=function(){};"
             "var t=function(){return{get:n,set:n,send:n};};"
             "var runCb=function(args){if(!args)return;"
             "var last=args[args.length-1];"
             "if(typeof last==='function'){try{last(t());}catch(_){}}"
             "for(var k=0;k<args.length;k++){var o=args[k];"
             "if(o&&typeof o==='object'&&typeof o.hitCallback==='function'){"
             "try{o.hitCallback();}catch(_){}}}"
             "};"
             "var prevQ=(window.ga&&window.ga.q)?window.ga.q:[];"
             "var ga=window.ga=function(){runCb(arguments);ga.q.push(arguments);};"
             "ga.q=[];ga.create=t;ga.getByName=t;ga.getAll=function(){return[];};"
             "ga.remove=n;ga.loaded=true;ga.l=+new Date;"
             "for(var i=0;i<prevQ.length;i++){var item=prevQ[i];"
             "if(typeof item==='function'){try{item(t());}catch(_){}}"
             "else if(item&&typeof item.length==='number'){runCb(item);}}})();";
    case SurrogateKind::kGa:
      return "window._gat=window._gat||{_getTracker:function(){return{_trackPageview:function(){},"
             "_trackEvent:function(){},_setAccount:function(){}};},"
             "_createTracker:function(){return this._getTracker();}};"
             "window._gaq=window._gaq||{push:function(){}};";
    case SurrogateKind::kFbEvents:
      return "(function(){var f=window.fbq=window.fbq||function(){"
             "f.callMethod?f.callMethod.apply(f,arguments):f.queue.push(arguments);};"
             "if(!window._fbq)window._fbq=f;f.push=f;f.loaded=true;f.version='2.0';"
             "f.queue=f.queue||[];})();";
    case SurrogateKind::kNone:
    default:
      return "";
  }
}

TrackerMatch SXPrivacyEngine::EvaluateSubresourceBlock(std::string_view req_url,
                                                       std::string_view req_host,
                                                       std::string_view page_host,
                                                       const PolicySnapshot& policy) const {
  if (!policy.IsSiteProtectionEnabled(page_host)) {
    return {};
  }
  // Never block essential SSO/auth, payments, CAPTCHAs, or static CDNs.
  if (IsEssentialAllowlistedHost(req_host)) {
    return {};
  }

  // Exempt Facebook Login JS SDK in Standard mode so "Continue with Facebook" SSO works cleanly.
  if (policy.protection_level == 0 && HostMatchesDomainOrSubdomain(NormalizeHostRaw(req_host), "connect.facebook.net")) {
    std::string lower_url = ToLowerASCII(req_url);
    size_t q = lower_url.find('?');
    if (q != std::string::npos) lower_url.resize(q);
    size_t f = lower_url.find('#');
    if (f != std::string::npos) lower_url.resize(f);
    if (lower_url.find("/sdk.js") != std::string::npos) {
      return {};
    }
  }

  TrackerMatch match = ClassifyTrackerHost(req_host, policy.protection_level, false);
  if (!match.matched) {
    return {};
  }

  // Zero-breakage same-entity exemption.
  if (IsSameEntity(page_host, req_host, match.entity_domain)) {
    return {};
  }

  match.is_surrogate_eligible = (DetectSurrogateKind(req_url) != SurrogateKind::kNone);
  return match;
}

ParamStripResult SXPrivacyEngine::StripTrackingParamsFromURL(std::string_view raw_url) const {
  ParamStripResult result;
  size_t frag_pos = raw_url.find('#');
  std::string_view before_frag = (frag_pos == std::string_view::npos)
                                     ? raw_url
                                     : raw_url.substr(0, frag_pos);
  std::string_view fragment = (frag_pos == std::string_view::npos) ? "" : raw_url.substr(frag_pos);

  size_t qpos = before_frag.find('?');
  if (qpos == std::string_view::npos) {
    return result;
  }

  std::string_view base = before_frag.substr(0, qpos);
  std::string_view query = before_frag.substr(qpos + 1);
  if (query.empty()) {
    return result;
  }

  std::string host = NormalizeHost(ExtractHostFromURL(raw_url));
  const bool allow_si_strip =
      HostMatchesDomainOrSubdomain(host, "youtube.com") ||
      HostMatchesDomainOrSubdomain(host, "youtu.be") ||
      HostMatchesDomainOrSubdomain(host, "open.spotify.com");

  const auto& exact_params = TrackingQueryParamsExact();
  std::vector<std::string_view> kept;

  size_t pos = 0;
  while (pos <= query.size()) {
    size_t amp = query.find('&', pos);
    if (amp == std::string_view::npos) amp = query.size();
    std::string_view token = query.substr(pos, amp - pos);

    if (!token.empty()) {
      size_t eq = token.find('=');
      std::string_view raw_key = (eq == std::string_view::npos) ? token : token.substr(0, eq);
      std::string lower_key = URLDecodeLower(raw_key);

      bool strip = false;
      if (exact_params.count(lower_key) > 0) {
        strip = true;
      } else if (lower_key.rfind("utm_", 0) == 0 ||
                 lower_key.rfind("hsa_", 0) == 0 ||
                 lower_key.rfind("mtm_", 0) == 0) {
        strip = true;
      } else if (allow_si_strip && lower_key == "si") {
        strip = true;
      }

      if (strip) {
        result.modified = true;
        result.stripped_params.push_back(std::string(raw_key));
      } else {
        kept.push_back(token);
      }
    }

    if (amp == query.size()) break;
    pos = amp + 1;
  }

  if (!result.modified) {
    return result;
  }

  result.cleaned_url.reserve(raw_url.size());
  result.cleaned_url.append(base);
  if (!kept.empty()) {
    result.cleaned_url.push_back('?');
    for (size_t i = 0; i < kept.size(); ++i) {
      if (i > 0) result.cleaned_url.push_back('&');
      result.cleaned_url.append(kept[i]);
    }
  }
  result.cleaned_url.append(fragment);
  return result;
}

bool SXPrivacyEngine::IsBounceTrackerHost(std::string_view host) const {
  std::string h = NormalizeHostRaw(host);
  if (h.empty()) return false;
  const auto& bounce = BounceTrackerHosts();
  std::string_view probe(h);
  while (!probe.empty()) {
    if (bounce.count(std::string(probe)) > 0) {
      return true;
    }
    size_t dot = probe.find('.');
    if (dot == std::string_view::npos) break;
    probe.remove_prefix(dot + 1);
  }
  return false;
}

void SXPrivacyEngine::AllowInsecureHTTPForHost(std::string_view host, bool is_private) {
  std::string norm = NormalizeHost(host);
  if (norm.empty()) return;
  std::lock_guard<std::mutex> lock(http_mutex_);
  if (is_private) {
    incognito_allowed_http_hosts_.insert(norm);
    incognito_http_fallback_hosts_.insert(norm);
  } else {
    normal_allowed_http_hosts_.insert(norm);
    normal_http_fallback_hosts_.insert(norm);
  }
}

void SXPrivacyEngine::AddSessionHTTPSFallbackHost(std::string_view host, bool is_private) {
  std::string norm = NormalizeHost(host);
  if (norm.empty()) return;
  std::lock_guard<std::mutex> lock(http_mutex_);
  if (is_private) {
    incognito_http_fallback_hosts_.insert(norm);
  } else {
    normal_http_fallback_hosts_.insert(norm);
  }
}

bool SXPrivacyEngine::IsHostAllowedInsecureHTTP(std::string_view host, bool is_private) const {
  std::string norm = NormalizeHost(host);
  if (norm.empty()) return false;
  std::lock_guard<std::mutex> lock(http_mutex_);
  if (is_private) {
    return incognito_allowed_http_hosts_.count(norm) > 0 ||
           incognito_http_fallback_hosts_.count(norm) > 0;
  }
  return normal_allowed_http_hosts_.count(norm) > 0 ||
         normal_http_fallback_hosts_.count(norm) > 0;
}

bool SXPrivacyEngine::ShouldUpgradeMainFrameToHTTPS(std::string_view url,
                                                    std::string_view host,
                                                    const PolicySnapshot& policy,
                                                    bool is_private) const {
  if (!policy.https_only_mode) return false;
  if (ExtractSchemeFromURL(url) != "http") return false;
  std::string raw_host = ExtractHostFromURL(url);
  if (raw_host.empty()) raw_host = NormalizeHostRaw(host);
  std::string port = ExtractPortFromURL(url);
  if (!port.empty() && port != "80") return false;
  if (!policy.IsSiteProtectionEnabled(host)) return false;
  if (IsPrivateOrLocalNetworkHost(raw_host)) return false;
  if (IsHostAllowedInsecureHTTP(host, is_private)) return false;
  return true;
}

}  // namespace sx::privacy
