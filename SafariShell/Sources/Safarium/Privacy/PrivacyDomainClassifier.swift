import Foundation

enum PrivacyDomainClassifier {
    private static let allowedNetworkSchemes: Set<String> = ["http", "https", "ws", "wss"]

    private static let multiPartPublicSuffixes: Set<String> = [
        // UK
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk", "ltd.uk", "plc.uk", "sch.uk",
        // Australia
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        // Japan
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "ed.jp", "gr.jp", "lg.jp",
        // Turkey
        "com.tr", "org.tr", "net.tr", "gov.tr", "edu.tr", "bel.tr", "gen.tr", "biz.tr",
        // Brazil
        "com.br", "org.br", "net.br", "gov.br", "edu.br", "jus.br",
        // New Zealand
        "co.nz", "org.nz", "net.nz", "govt.nz", "ac.nz", "gen.nz",
        // China & Hong Kong & Taiwan
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "com.hk", "org.hk", "edu.hk", "gov.hk", "net.hk",
        "com.tw", "org.tw", "net.tw", "edu.tw", "gov.tw",
        // South Korea
        "co.kr", "or.kr", "ne.kr", "go.kr", "re.kr", "ac.kr",
        // Singapore & India & SEA
        "com.sg", "org.sg", "net.sg", "edu.sg", "gov.sg",
        "com.in", "co.in", "net.in", "org.in", "gov.in", "ac.in", "res.in",
        "co.id", "or.id", "go.id", "web.id",
        "com.my", "org.my", "gov.my", "edu.my",
        "com.ph", "org.ph", "gov.ph",
        "com.vn", "org.vn", "gov.vn",
        "co.th", "in.th", "or.th", "go.th",
        // Americas & Europe & Africa & Middle East
        "com.mx", "org.mx", "gob.mx", "edu.mx",
        "com.ar", "org.ar", "gov.ar",
        "com.co", "org.co", "gov.co",
        "co.za", "org.za", "gov.za", "ac.za",
        "co.il", "org.il", "ac.il", "gov.il",
        "com.sa", "org.sa", "gov.sa",
        "com.eg", "org.eg", "gov.eg",
        "com.ng", "org.ng", "gov.ng",
        "co.ke", "or.ke", "go.ke",
        "com.pk", "org.pk", "gov.pk",
        "com.ua", "org.ua", "gov.ua",
        "com.pl", "org.pl", "net.pl", "gov.pl",
        "com.ru", "org.ru", "net.ru",
        "com.es", "org.es", "gob.es",
        "com.pt", "org.pt", "gov.pt",
        "eu.com", "us.com", "uk.com", "de.com", "jp.net"
    ]

    private struct TrackerMetadataEntry {
        let entityDomain: String
        let ownerName: String
        let category: PrivacyTrackerCategory
    }

    private static let trackerCatalog: [String: TrackerMetadataEntry] = [
        // Google
        "doubleclick.net": TrackerMetadataEntry(entityDomain: "google.com", ownerName: "Google", category: .advertising),
        "googlesyndication.com": TrackerMetadataEntry(entityDomain: "google.com", ownerName: "Google", category: .advertising),
        "googleadservices.com": TrackerMetadataEntry(entityDomain: "google.com", ownerName: "Google", category: .advertising),
        "adservice.google.com": TrackerMetadataEntry(entityDomain: "google.com", ownerName: "Google", category: .advertising),
        "googletagservices.com": TrackerMetadataEntry(entityDomain: "google.com", ownerName: "Google", category: .advertising),
        "googletagmanager.com": TrackerMetadataEntry(entityDomain: "google.com", ownerName: "Google", category: .analytics),
        "google-analytics.com": TrackerMetadataEntry(entityDomain: "google.com", ownerName: "Google", category: .analytics),
        "2mdn.net": TrackerMetadataEntry(entityDomain: "google.com", ownerName: "Google", category: .advertising),
        "invitemedia.com": TrackerMetadataEntry(entityDomain: "google.com", ownerName: "Google", category: .advertising),

        // Meta
        "facebook.net": TrackerMetadataEntry(entityDomain: "facebook.com", ownerName: "Meta", category: .social),
        "connect.facebook.net": TrackerMetadataEntry(entityDomain: "facebook.com", ownerName: "Meta", category: .social),
        "facebook.com": TrackerMetadataEntry(entityDomain: "facebook.com", ownerName: "Meta", category: .social),
        "fbcdn.net": TrackerMetadataEntry(entityDomain: "facebook.com", ownerName: "Meta", category: .social),
        "l.facebook.com": TrackerMetadataEntry(entityDomain: "facebook.com", ownerName: "Meta", category: .bounceTracking),
        "lm.facebook.com": TrackerMetadataEntry(entityDomain: "facebook.com", ownerName: "Meta", category: .bounceTracking),
        "atdmt.com": TrackerMetadataEntry(entityDomain: "facebook.com", ownerName: "Meta", category: .advertising),
        "instagram.com": TrackerMetadataEntry(entityDomain: "facebook.com", ownerName: "Meta", category: .social),

        // Microsoft
        "clarity.ms": TrackerMetadataEntry(entityDomain: "microsoft.com", ownerName: "Microsoft", category: .sessionReplay),
        "bat.bing.com": TrackerMetadataEntry(entityDomain: "microsoft.com", ownerName: "Microsoft", category: .advertising),
        "bing.com": TrackerMetadataEntry(entityDomain: "microsoft.com", ownerName: "Microsoft", category: .advertising),
        "ads.linkedin.com": TrackerMetadataEntry(entityDomain: "microsoft.com", ownerName: "Microsoft", category: .advertising),
        "licdn.com": TrackerMetadataEntry(entityDomain: "microsoft.com", ownerName: "Microsoft", category: .social),
        "linkedin.com": TrackerMetadataEntry(entityDomain: "microsoft.com", ownerName: "Microsoft", category: .social),

        // Amazon
        "amazon-adsystem.com": TrackerMetadataEntry(entityDomain: "amazon.com", ownerName: "Amazon", category: .advertising),
        "assoc-amazon.com": TrackerMetadataEntry(entityDomain: "amazon.com", ownerName: "Amazon", category: .advertising),
        "serving-sys.com": TrackerMetadataEntry(entityDomain: "amazon.com", ownerName: "Amazon", category: .advertising),

        // ByteDance / TikTok
        "analytics.tiktok.com": TrackerMetadataEntry(entityDomain: "tiktok.com", ownerName: "ByteDance", category: .analytics),
        "tiktok.com": TrackerMetadataEntry(entityDomain: "tiktok.com", ownerName: "ByteDance", category: .social),
        "byteoversea.com": TrackerMetadataEntry(entityDomain: "tiktok.com", ownerName: "ByteDance", category: .analytics),

        // X / Twitter
        "t.co": TrackerMetadataEntry(entityDomain: "x.com", ownerName: "X Corp.", category: .bounceTracking),
        "ads-twitter.com": TrackerMetadataEntry(entityDomain: "x.com", ownerName: "X Corp.", category: .advertising),
        "analytics.twitter.com": TrackerMetadataEntry(entityDomain: "x.com", ownerName: "X Corp.", category: .analytics),
        "platform.twitter.com": TrackerMetadataEntry(entityDomain: "x.com", ownerName: "X Corp.", category: .social),

        // Adobe
        "demdex.net": TrackerMetadataEntry(entityDomain: "adobe.com", ownerName: "Adobe", category: .dataBroker),
        "omtrdc.net": TrackerMetadataEntry(entityDomain: "adobe.com", ownerName: "Adobe", category: .analytics),
        "2o7.net": TrackerMetadataEntry(entityDomain: "adobe.com", ownerName: "Adobe", category: .analytics),
        "everesttech.net": TrackerMetadataEntry(entityDomain: "adobe.com", ownerName: "Adobe", category: .advertising),

        // Ad Tech & Programmatic
        "criteo.com": TrackerMetadataEntry(entityDomain: "criteo.com", ownerName: "Criteo", category: .advertising),
        "criteo.net": TrackerMetadataEntry(entityDomain: "criteo.com", ownerName: "Criteo", category: .advertising),
        "taboola.com": TrackerMetadataEntry(entityDomain: "taboola.com", ownerName: "Taboola", category: .advertising),
        "outbrain.com": TrackerMetadataEntry(entityDomain: "outbrain.com", ownerName: "Outbrain", category: .advertising),
        "adsrvr.org": TrackerMetadataEntry(entityDomain: "thetradedesk.com", ownerName: "The Trade Desk", category: .advertising),
        "adnxs.com": TrackerMetadataEntry(entityDomain: "xandr.com", ownerName: "Xandr", category: .advertising),
        "pubmatic.com": TrackerMetadataEntry(entityDomain: "pubmatic.com", ownerName: "PubMatic", category: .advertising),
        "rubiconproject.com": TrackerMetadataEntry(entityDomain: "magnite.com", ownerName: "Magnite", category: .advertising),
        "openx.net": TrackerMetadataEntry(entityDomain: "openx.com", ownerName: "OpenX", category: .advertising),
        "casalemedia.com": TrackerMetadataEntry(entityDomain: "indexexchange.com", ownerName: "Index Exchange", category: .advertising),
        "smartadserver.com": TrackerMetadataEntry(entityDomain: "equativ.com", ownerName: "Equativ", category: .advertising),
        "media.net": TrackerMetadataEntry(entityDomain: "media.net", ownerName: "Media.net", category: .advertising),
        "quantserve.com": TrackerMetadataEntry(entityDomain: "quantcast.com", ownerName: "Quantcast", category: .analytics),
        "scorecardresearch.com": TrackerMetadataEntry(entityDomain: "comscore.com", ownerName: "comScore", category: .analytics),
        "advertising.com": TrackerMetadataEntry(entityDomain: "yahoo.com", ownerName: "Yahoo", category: .advertising),

        // Data Brokers
        "bluekai.com": TrackerMetadataEntry(entityDomain: "oracle.com", ownerName: "Oracle", category: .dataBroker),
        "addthis.com": TrackerMetadataEntry(entityDomain: "oracle.com", ownerName: "Oracle", category: .dataBroker),
        "krxd.net": TrackerMetadataEntry(entityDomain: "salesforce.com", ownerName: "Salesforce", category: .dataBroker),
        "rlcdn.com": TrackerMetadataEntry(entityDomain: "liveramp.com", ownerName: "LiveRamp", category: .dataBroker),
        "crwdcntrl.net": TrackerMetadataEntry(entityDomain: "lotame.com", ownerName: "Lotame", category: .dataBroker),
        "acxiom-online.com": TrackerMetadataEntry(entityDomain: "acxiom.com", ownerName: "Acxiom", category: .dataBroker),

        // Session Replay
        "hotjar.com": TrackerMetadataEntry(entityDomain: "hotjar.com", ownerName: "Hotjar", category: .sessionReplay),
        "hotjar.io": TrackerMetadataEntry(entityDomain: "hotjar.com", ownerName: "Hotjar", category: .sessionReplay),
        "fullstory.com": TrackerMetadataEntry(entityDomain: "fullstory.com", ownerName: "FullStory", category: .sessionReplay),
        "mouseflow.com": TrackerMetadataEntry(entityDomain: "mouseflow.com", ownerName: "Mouseflow", category: .sessionReplay),
        "crazyegg.com": TrackerMetadataEntry(entityDomain: "crazyegg.com", ownerName: "Crazy Egg", category: .sessionReplay),
        "luckyorange.com": TrackerMetadataEntry(entityDomain: "luckyorange.com", ownerName: "Lucky Orange", category: .sessionReplay),
        "logrocket.com": TrackerMetadataEntry(entityDomain: "logrocket.com", ownerName: "LogRocket", category: .sessionReplay),

        // Analytics & Attribution
        "mixpanel.com": TrackerMetadataEntry(entityDomain: "mixpanel.com", ownerName: "Mixpanel", category: .analytics),
        "amplitude.com": TrackerMetadataEntry(entityDomain: "amplitude.com", ownerName: "Amplitude", category: .analytics),
        "segment.com": TrackerMetadataEntry(entityDomain: "segment.com", ownerName: "Segment", category: .analytics),
        "segment.io": TrackerMetadataEntry(entityDomain: "segment.com", ownerName: "Segment", category: .analytics),
        "heapanalytics.com": TrackerMetadataEntry(entityDomain: "heap.io", ownerName: "Heap", category: .analytics),
        "pendo.io": TrackerMetadataEntry(entityDomain: "pendo.io", ownerName: "Pendo", category: .analytics),
        "hs-analytics.net": TrackerMetadataEntry(entityDomain: "hubspot.com", ownerName: "HubSpot", category: .analytics),
        "hs-scripts.com": TrackerMetadataEntry(entityDomain: "hubspot.com", ownerName: "HubSpot", category: .analytics),
        "mktoresp.com": TrackerMetadataEntry(entityDomain: "marketo.com", ownerName: "Marketo", category: .analytics),
        "braze.com": TrackerMetadataEntry(entityDomain: "braze.com", ownerName: "Braze", category: .analytics),
        "branch.io": TrackerMetadataEntry(entityDomain: "branch.io", ownerName: "Branch", category: .analytics),
        "appsflyer.com": TrackerMetadataEntry(entityDomain: "appsflyer.com", ownerName: "AppsFlyer", category: .analytics),
        "adjust.com": TrackerMetadataEntry(entityDomain: "adjust.com", ownerName: "Adjust", category: .analytics),
        "onesignal.com": TrackerMetadataEntry(entityDomain: "onesignal.com", ownerName: "OneSignal", category: .analytics),
        "chartbeat.com": TrackerMetadataEntry(entityDomain: "chartbeat.com", ownerName: "Chartbeat", category: .analytics),
        "nr-data.net": TrackerMetadataEntry(entityDomain: "newrelic.com", ownerName: "New Relic", category: .analytics),

        // Social Widgets
        "ct.pinterest.com": TrackerMetadataEntry(entityDomain: "pinterest.com", ownerName: "Pinterest", category: .social),
        "pinterest.com": TrackerMetadataEntry(entityDomain: "pinterest.com", ownerName: "Pinterest", category: .social),
        "sc-static.net": TrackerMetadataEntry(entityDomain: "snapchat.com", ownerName: "Snap Inc.", category: .social),
        "tr.snapchat.com": TrackerMetadataEntry(entityDomain: "snapchat.com", ownerName: "Snap Inc.", category: .social),
        "alb.reddit.com": TrackerMetadataEntry(entityDomain: "reddit.com", ownerName: "Reddit", category: .social),

        // Fingerprinting
        "fpjs.io": TrackerMetadataEntry(entityDomain: "fingerprint.com", ownerName: "Fingerprint", category: .fingerprinting),
        "fingerprintjs.com": TrackerMetadataEntry(entityDomain: "fingerprint.com", ownerName: "Fingerprint", category: .fingerprinting),
        "fpnpmcdn.net": TrackerMetadataEntry(entityDomain: "fingerprint.com", ownerName: "Fingerprint", category: .fingerprinting),

        // Cryptomining
        "coinhive.com": TrackerMetadataEntry(entityDomain: "coinhive.com", ownerName: "Coinhive", category: .cryptomining),
        "coin-hive.com": TrackerMetadataEntry(entityDomain: "coinhive.com", ownerName: "Coinhive", category: .cryptomining),
        "cryptoloot.pro": TrackerMetadataEntry(entityDomain: "cryptoloot.pro", ownerName: "CryptoLoot", category: .cryptomining),
        "jsecoin.com": TrackerMetadataEntry(entityDomain: "jsecoin.com", ownerName: "JSEcoin", category: .cryptomining),

        // Email Tracking
        "list-manage.com": TrackerMetadataEntry(entityDomain: "mailchimp.com", ownerName: "Mailchimp", category: .emailTracking),
        "sendgrid.net": TrackerMetadataEntry(entityDomain: "sendgrid.com", ownerName: "SendGrid", category: .emailTracking),
        "exacttarget.com": TrackerMetadataEntry(entityDomain: "salesforce.com", ownerName: "Salesforce", category: .emailTracking),

        // Bounce Tracking
        "click.linksynergy.com": TrackerMetadataEntry(entityDomain: "rakuten.com", ownerName: "Rakuten Advertising", category: .bounceTracking),
        "ojrq.net": TrackerMetadataEntry(entityDomain: "cj.com", ownerName: "CJ Affiliate", category: .bounceTracking),
        "anrdoezrs.net": TrackerMetadataEntry(entityDomain: "cj.com", ownerName: "CJ Affiliate", category: .bounceTracking),
        "tkqlhce.com": TrackerMetadataEntry(entityDomain: "cj.com", ownerName: "CJ Affiliate", category: .bounceTracking)
    ]

    static func normalizedHost(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var candidate = trimmed

        if candidate.contains("://") {
            guard let components = URLComponents(string: candidate) else {
                return ""
            }
            if let scheme = components.scheme?.lowercased(), !allowedNetworkSchemes.contains(scheme) {
                return ""
            }
            candidate = components.host ?? ""
        } else if candidate.hasPrefix("//") {
            guard let components = URLComponents(string: "https:" + candidate) else {
                return ""
            }
            candidate = components.host ?? ""
        } else {
            // Check for bare non-network scheme URIs such as about:blank, data:text/html, javascript:...
            if let colonIdx = candidate.firstIndex(of: ":"),
               !candidate.hasPrefix("["),
               candidate[..<colonIdx].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) {
                let prefix = candidate[..<colonIdx].lowercased()
                let afterColon = candidate[candidate.index(after: colonIdx)...]
                let isPortLike = !afterColon.isEmpty && afterColon.prefix(while: { $0.isNumber }).count > 0
                    && (afterColon.allSatisfy(\.isNumber) || afterColon.contains("/") || afterColon.contains("?") || afterColon.contains("#"))
                let colonCount = candidate.filter { $0 == ":" }.count
                if colonCount == 1 && !isPortLike && ["about", "data", "javascript", "blob", "file", "safarium", "chrome", "devtools", "mailto", "tel"].contains(prefix) {
                    return ""
                }
            }

            if candidate.contains("/") || candidate.contains("?") || candidate.contains("#") || candidate.contains("@") {
                if let components = URLComponents(string: "https://" + candidate), let parsedHost = components.host {
                    candidate = parsedHost
                } else {
                    if let atIdx = candidate.lastIndex(of: "@") {
                        candidate = String(candidate[candidate.index(after: atIdx)...])
                    }
                    if let stopIdx = candidate.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
                        candidate = String(candidate[..<stopIdx])
                    }
                }
            }
        }

        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Unwrap bracketed IPv6 literals such as [::1] or [::1]:8080
        if candidate.hasPrefix("[") {
            if let closeBracket = candidate.firstIndex(of: "]") {
                candidate = String(candidate[candidate.index(after: candidate.startIndex)..<closeBracket])
            }
        } else {
            // Strip single trailing :port when not a bare IPv6 address
            let colonCount = candidate.filter { $0 == ":" }.count
            if colonCount == 1, let colonIdx = candidate.firstIndex(of: ":") {
                let portPart = candidate[candidate.index(after: colonIdx)...]
                if portPart.isEmpty || portPart.allSatisfy(\.isNumber) {
                    candidate = String(candidate[..<colonIdx])
                }
            }
        }

        while candidate.hasSuffix(".") {
            candidate.removeLast()
        }

        if candidate.hasPrefix("www."), candidate.count > 4 {
            candidate = String(candidate.dropFirst(4))
        }

        return candidate
    }

    static func sanitizeHostForStorage(_ raw: String) -> String {
        let host = normalizedHost(raw)
        guard !host.isEmpty else { return "" }
        let forbidden = CharacterSet(charactersIn: "/?#\\@\r\n\t ")
        if host.rangeOfCharacter(from: forbidden) != nil {
            return ""
        }
        return host
    }

    static func registrableDomain(for rawHost: String) -> String {
        let host = normalizedHost(rawHost)
        guard !host.isEmpty else { return "" }

        if isIPAddress(host) || host == "localhost" || host.hasSuffix(".local") || !host.contains(".") {
            return host
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        guard labels.count > 2 else {
            return labels.joined(separator: ".")
        }

        let lastTwo = "\(labels[labels.count - 2]).\(labels[labels.count - 1])"
        if multiPartPublicSuffixes.contains(lastTwo) {
            return labels.suffix(3).joined(separator: ".")
        }

        return labels.suffix(2).joined(separator: ".")
    }

    static func displayOwner(entityDomain: String, rawOwner: String) -> String {
        let trimmedOwner = rawOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOwner.isEmpty {
            return trimmedOwner
        }

        let normalizedEntity = normalizedHost(entityDomain)
        guard !normalizedEntity.isEmpty else { return "" }

        if let known = trackerMetadata(forHost: normalizedEntity) {
            return known.ownerName
        }

        let registrable = registrableDomain(for: normalizedEntity)
        let firstLabel = registrable.split(separator: ".").first.map(String.init) ?? registrable
        guard !firstLabel.isEmpty else { return normalizedEntity }
        return firstLabel.prefix(1).uppercased() + firstLabel.dropFirst()
    }

    static func trackerMetadata(forHost host: String) -> (entityDomain: String, ownerName: String, category: PrivacyTrackerCategory)? {
        let normalized = normalizedHost(host)
        guard !normalized.isEmpty else { return nil }

        var candidate = normalized
        while !candidate.isEmpty {
            if let match = trackerCatalog[candidate] {
                return (match.entityDomain, match.ownerName, match.category)
            }
            guard let dotIdx = candidate.firstIndex(of: ".") else { break }
            candidate = String(candidate[candidate.index(after: dotIdx)...])
        }

        return nil
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { part in
            guard !part.isEmpty, let value = Int(part), (0...255).contains(value) else {
                return false
            }
            return String(value) == part
        }
    }
}
