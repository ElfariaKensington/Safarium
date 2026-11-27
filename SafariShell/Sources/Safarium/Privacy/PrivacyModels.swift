import AppKit
import Foundation

extension Notification.Name {
    static let safariumPrivacyReportDidChange = Notification.Name("SafariumPrivacyReportDidChangeNotification")
}

enum ConnectionSecurityState: Int, Equatable, Codable {
    case internalPage = 0
    case secureHTTPS = 1
    case upgradedHTTPS = 2
    case insecureHTTP = 3
    case certificateError = 4

    var isSecure: Bool {
        self == .secureHTTPS || self == .upgradedHTTPS
    }

    var displayTitle: String {
        switch self {
        case .internalPage:
            return "Safarium Page"
        case .secureHTTPS:
            return "Connection is Secure (HTTPS)"
        case .upgradedHTTPS:
            return "Automatically Upgraded to HTTPS"
        case .insecureHTTP:
            return "Not Secure (HTTP)"
        case .certificateError:
            return "Certificate Warning"
        }
    }

    var symbolName: String {
        switch self {
        case .internalPage:
            return "safari"
        case .secureHTTPS:
            return "lock.fill"
        case .upgradedHTTPS:
            return "lock.shield.fill"
        case .insecureHTTP:
            return "exclamationmark.triangle.fill"
        case .certificateError:
            return "xmark.shield.fill"
        }
    }
}

enum PrivacyProtectionLevel: Int, CaseIterable, Codable {
    case standard = 0
    case strict = 1

    var displayName: String {
        switch self {
        case .standard:
            return "Standard"
        case .strict:
            return "Strict"
        }
    }

    var summaryDescription: String {
        switch self {
        case .standard:
            return "Blocks known cross-site trackers, cleans tracking links, and preserves site compatibility."
        case .strict:
            return "Aggressively blocks trackers, third-party telemetry, and fingerprinting probes across all browsing."
        }
    }
}

enum PrivacyEventType: String, CaseIterable, Codable {
    case trackerBlocked
    case cookieBlocked
    case trackingParamStripped
    case httpsUpgraded
    case fingerprintBlocked
    case bounceTrackerMitigated
    case pageVisited

    var isTrackerPrevention: Bool {
        switch self {
        case .trackerBlocked, .cookieBlocked, .fingerprintBlocked, .bounceTrackerMitigated:
            return true
        case .trackingParamStripped, .httpsUpgraded, .pageVisited:
            return false
        }
    }
}

enum PrivacyTrackerCategory: String, CaseIterable, Codable {
    case advertising
    case analytics
    case social
    case fingerprinting
    case cryptomining
    case sessionReplay
    case dataBroker
    case emailTracking
    case cookie
    case linkTracking
    case httpsUpgrade
    case bounceTracking
    case other

    var displayName: String {
        switch self {
        case .advertising:
            return "Advertising"
        case .analytics:
            return "Analytics"
        case .social:
            return "Social"
        case .fingerprinting:
            return "Fingerprinting"
        case .cryptomining:
            return "Cryptomining"
        case .sessionReplay:
            return "Session Replay"
        case .dataBroker:
            return "Data Broker"
        case .emailTracking:
            return "Email Tracking"
        case .cookie:
            return "Cookie"
        case .linkTracking:
            return "Link Tracking"
        case .httpsUpgrade:
            return "HTTPS Upgrade"
        case .bounceTracking:
            return "Bounce Tracking"
        case .other:
            return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .advertising:
            return "megaphone.fill"
        case .analytics:
            return "chart.bar.fill"
        case .social:
            return "person.2.fill"
        case .fingerprinting:
            return "hand.raised.fill"
        case .cryptomining:
            return "cpu.fill"
        case .sessionReplay:
            return "eye.slash.fill"
        case .dataBroker:
            return "tray.full.fill"
        case .emailTracking:
            return "envelope.badge.shield.half.filled"
        case .cookie:
            return "shield.lefthalf.filled"
        case .linkTracking:
            return "link.badge.plus"
        case .httpsUpgrade:
            return "lock.shield.fill"
        case .bounceTracking:
            return "arrow.uturn.backward.circle.fill"
        case .other:
            return "shield.fill"
        }
    }

    var badgeColor: NSColor {
        switch self {
        case .advertising:
            return .systemOrange
        case .analytics:
            return .systemBlue
        case .social:
            return .systemPink
        case .fingerprinting:
            return .systemPurple
        case .cryptomining:
            return .systemRed
        case .sessionReplay:
            return .systemIndigo
        case .dataBroker:
            return .systemBrown
        case .emailTracking:
            return .systemTeal
        case .cookie:
            return .systemYellow
        case .linkTracking:
            return .systemCyan
        case .httpsUpgrade:
            return .systemGreen
        case .bounceTracking:
            return .systemMint
        case .other:
            return .systemGray
        }
    }
}

struct PrivacyEvent: Equatable, Codable, Identifiable {
    let id: UUID
    let eventType: PrivacyEventType
    let pageHost: String
    let trackerHost: String
    let entityDomain: String
    let ownerName: String
    let category: PrivacyTrackerCategory
    let detail: String
    let count: Int
    let isPrivate: Bool
    let timestamp: Date

    init(
        id: UUID = UUID(),
        eventType: PrivacyEventType,
        pageHost: String,
        trackerHost: String = "",
        entityDomain: String = "",
        ownerName: String = "",
        category: PrivacyTrackerCategory = .other,
        detail: String = "",
        count: Int = 1,
        isPrivate: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.eventType = eventType
        self.pageHost = pageHost
        self.trackerHost = trackerHost
        self.entityDomain = entityDomain
        self.ownerName = ownerName
        self.category = category
        self.detail = detail
        self.count = count
        self.isPrivate = isPrivate
        self.timestamp = timestamp
    }
}

struct WebsiteDataRecord: Equatable, Identifiable, Codable {
    var id: String { domain }
    let domain: String
    let cookieCount: Int
    let hasCookies: Bool
    let hasCache: Bool

    var detailSummary: String {
        var parts: [String] = []
        if cookieCount > 0 {
            parts.append(cookieCount == 1 ? "1 cookie" : "\(cookieCount) cookies")
        } else if hasCookies {
            parts.append("Cookies")
        }
        if hasCache {
            parts.append("Cache")
        }
        return parts.isEmpty ? "Stored data" : parts.joined(separator: ", ")
    }
}

struct PrivacyReportSiteTrackerDetail: Equatable, Identifiable {
    var id: String { entityDomain }
    let entityDomain: String
    let ownerName: String
    let category: PrivacyTrackerCategory
    let trackerDomains: [String]
    let blockedCount: Int
    let eventTypes: Set<PrivacyEventType>
    let lastSeen: Date
}

struct PrivacyReportWebsiteEntry: Equatable, Identifiable {
    var id: String { host }
    let host: String
    let trackers: [PrivacyReportSiteTrackerDetail]
    let totalBlockedRequests: Int
    let uniqueTrackerCount: Int
    let cookiesBlocked: Int
    let paramsStripped: Int
    let fingerprintsBlocked: Int
    let httpsUpgrades: Int
    let bounceTrackersMitigated: Int
    let lastVisited: Date
}

struct PrivacyReportTrackerEntry: Equatable, Identifiable {
    var id: String { entityDomain }
    let entityDomain: String
    let ownerName: String
    let category: PrivacyTrackerCategory
    let trackerDomains: [String]
    let websites: [String]
    let totalBlockedRequests: Int
    let lastSeen: Date

    var websiteCount: Int { websites.count }
}

struct PrivacyReportSummary: Equatable {
    let uniqueTrackersPrevented: Int
    let totalBlockedRequests: Int
    let totalWebsitesVisited: Int
    let websitesContactingTrackersCount: Int
    let websitesContactingTrackersPercent: Int
    let mostContactedTracker: PrivacyReportTrackerEntry?
    let httpsUpgradesCount: Int
    let trackingParamsStrippedCount: Int
    let fingerprintingAttemptsBlocked: Int
    let cookiesBlockedCount: Int
    let bounceTrackersMitigatedCount: Int
    let categoryBreakdown: [PrivacyTrackerCategory: Int]
    let websites: [PrivacyReportWebsiteEntry]
    let trackers: [PrivacyReportTrackerEntry]
    let windowDays: Int

    static let empty = PrivacyReportSummary(
        uniqueTrackersPrevented: 0,
        totalBlockedRequests: 0,
        totalWebsitesVisited: 0,
        websitesContactingTrackersCount: 0,
        websitesContactingTrackersPercent: 0,
        mostContactedTracker: nil,
        httpsUpgradesCount: 0,
        trackingParamsStrippedCount: 0,
        fingerprintingAttemptsBlocked: 0,
        cookiesBlockedCount: 0,
        bounceTrackersMitigatedCount: 0,
        categoryBreakdown: [:],
        websites: [],
        trackers: [],
        windowDays: 30
    )
}

struct TabPrivacySnapshot: Equatable {
    let tabID: String
    var host: String
    var isPrivate: Bool
    var securityState: ConnectionSecurityState
    var protectionsEnabled: Bool
    var trackers: [PrivacyReportTrackerEntry]
    var totalTrackersBlocked: Int
    var uniqueTrackerEntitiesCount: Int
    var cookiesBlocked: Int
    var paramsStripped: Int
    var fingerprintsBlocked: Int
    var httpsUpgraded: Bool
    var bounceTrackersMitigated: Int
    var recentEvents: [PrivacyEvent]

    static func empty(
        tabID: String,
        host: String = "",
        isPrivate: Bool = false,
        securityState: ConnectionSecurityState = .internalPage,
        protectionsEnabled: Bool = true
    ) -> TabPrivacySnapshot {
        TabPrivacySnapshot(
            tabID: tabID,
            host: host,
            isPrivate: isPrivate,
            securityState: securityState,
            protectionsEnabled: protectionsEnabled,
            trackers: [],
            totalTrackersBlocked: 0,
            uniqueTrackerEntitiesCount: 0,
            cookiesBlocked: 0,
            paramsStripped: 0,
            fingerprintsBlocked: 0,
            httpsUpgraded: securityState == .upgradedHTTPS,
            bounceTrackersMitigated: 0,
            recentEvents: []
        )
    }
}
