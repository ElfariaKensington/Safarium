import AppKit
import Foundation
import SQLite3

// MARK: - Data Models

enum SupportedBrowserKind: String, CaseIterable, Hashable {
    case chrome = "Google Chrome"
    case safari = "Safari"
    case brave = "Brave"
    case edge = "Microsoft Edge"
    case arc = "Arc"
    case vivaldi = "Vivaldi"
    case opera = "Opera"
    case operaGX = "Opera GX"
    case orion = "Orion"
    case firefox = "Firefox"
    case zen = "Zen"
    case chromeBeta = "Google Chrome Beta"
    case chromeCanary = "Google Chrome Canary"

    var shortName: String {
        switch self {
        case .chrome: return "Chrome"
        case .chromeBeta: return "Chrome Beta"
        case .chromeCanary: return "Chrome Canary"
        case .edge: return "Edge"
        default: return rawValue
        }
    }

    var isChromiumFamily: Bool {
        switch self {
        case .chrome, .chromeBeta, .chromeCanary, .brave, .edge, .arc, .vivaldi, .opera, .operaGX:
            return true
        case .safari, .orion, .firefox, .zen:
            return false
        }
    }

    var appBundlePaths: [String] {
        switch self {
        case .safari: return ["/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app", "/Applications/Safari.app"]
        case .chrome: return ["/Applications/Google Chrome.app"]
        case .chromeBeta: return ["/Applications/Google Chrome Beta.app"]
        case .chromeCanary: return ["/Applications/Google Chrome Canary.app"]
        case .brave: return ["/Applications/Brave Browser.app"]
        case .edge: return ["/Applications/Microsoft Edge.app"]
        case .arc: return ["/Applications/Arc.app"]
        case .vivaldi: return ["/Applications/Vivaldi.app"]
        case .opera: return ["/Applications/Opera.app"]
        case .operaGX: return ["/Applications/Opera GX.app"]
        case .orion: return ["/Applications/Orion.app"]
        case .firefox: return ["/Applications/Firefox.app"]
        case .zen: return ["/Applications/Zen.app", "/Applications/Zen Browser.app"]
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .chromeBeta: return "com.google.Chrome.beta"
        case .chromeCanary: return "com.google.Chrome.canary"
        case .brave: return "com.brave.Browser"
        case .edge: return "com.microsoft.edgemac"
        case .arc: return "company.thebrowser.Browser"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .opera: return "com.operasoftware.Opera"
        case .operaGX: return "com.operasoftware.OperaGX"
        case .orion: return "com.kagi.kagimacOS"
        case .firefox: return "org.mozilla.firefox"
        case .zen: return "app.zen-browser.zen"
        }
    }

    var resolvedAppURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }
        let fm = FileManager.default
        for path in appBundlePaths where fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    var isAppInstalled: Bool {
        resolvedAppURL != nil
    }

    func appIcon(size: CGFloat = 22) -> NSImage {
        if let url = resolvedAppURL {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: size, height: size)
            return icon
        }
        return AssetLoader.shared.symbol(named: "globe", pointSize: size * 0.72, weight: .regular)
    }

    var userDataDirectory: URL {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let lib = home.appendingPathComponent("Library", isDirectory: true)
        let appSup = lib.appendingPathComponent("Application Support", isDirectory: true)
        switch self {
        case .safari: return lib.appendingPathComponent("Safari", isDirectory: true)
        case .chrome: return appSup.appendingPathComponent("Google/Chrome", isDirectory: true)
        case .chromeBeta: return appSup.appendingPathComponent("Google/Chrome Beta", isDirectory: true)
        case .chromeCanary: return appSup.appendingPathComponent("Google/Chrome Canary", isDirectory: true)
        case .brave: return appSup.appendingPathComponent("BraveSoftware/Brave-Browser", isDirectory: true)
        case .edge: return appSup.appendingPathComponent("Microsoft Edge", isDirectory: true)
        case .arc: return appSup.appendingPathComponent("Arc/User Data", isDirectory: true)
        case .vivaldi: return appSup.appendingPathComponent("Vivaldi", isDirectory: true)
        case .opera: return appSup.appendingPathComponent("com.operasoftware.Opera", isDirectory: true)
        case .operaGX: return appSup.appendingPathComponent("com.operasoftware.OperaGX", isDirectory: true)
        case .orion: return appSup.appendingPathComponent("Orion/Defaults", isDirectory: true)
        case .firefox: return appSup.appendingPathComponent("Firefox/Profiles", isDirectory: true)
        case .zen: return appSup.appendingPathComponent("zen/Profiles", isDirectory: true)
        }
    }
}

struct DetectedBrowserProfile: Equatable {
    let browser: SupportedBrowserKind
    let profileName: String
    let directory: URL
    let requiresPermissionGrant: Bool
}

struct ImportedExtensionCandidate: Equatable {
    let id: String
    let name: String
    let version: String
    let icon: NSImage?
    let localDirectory: URL?
    let storeID: String?
    let hasManifestKey: Bool
    let isAlreadyInstalled: Bool
    let manifestVersion: Int
    let compatibility: ExtensionCompatibility
}

struct BrowserProfileScan {
    let profile: DetectedBrowserProfile
    let bookmarks: [AssetLoader.BookmarkEntry]
    let readingList: [AssetLoader.ReadingListItem]
    let history: [AssetLoader.HistoryEntry]
    let extensions: [ImportedExtensionCandidate]
    let accessBlocked: Bool
}

struct BrowserImportSelection {
    var importBookmarks: Bool
    var importHistory: Bool
    var importReadingList: Bool
    var selectedExtensionIDs: Set<String>
}

struct BrowserImportResult {
    var bookmarksImported: Int = 0
    var historyImported: Int = 0
    var readingListImported: Int = 0
    var extensionsImported: Int = 0
    var extensionsSkipped: Int = 0
    var extensionsFailed: Int = 0
}

// MARK: - Browser Data Importer Engine

final class BrowserDataImporter {
    static let shared = BrowserDataImporter()

    /// Chromium built-in component / payment / cast / docs extensions that should not clutter user extension import.
    private static let ignoredComponentExtensionIDs: Set<String> = [
        "nmmhkkegccagdldgiimedpiccmgmieda", // Chrome Web Store Payments
        "pkedcjkdefgpdelpbcmbmeomcjbeemfm", // Chrome Media Router / Cast
        "ghbmnnjooekpmoecnnnilnnbdlolhkhi", // Google Docs Offline
        "aohghmighlieiainnegkcijnfilokake", // Google Docs
        "aapocclcgogkmnckokdopfmhonfmgoek", // Google Slides
        "felcaaldnbdncclmgdcncolpebgiejap", // Google Sheets
        "blpcfgokakmgnkcojhhkbfbldkacnbeo", // YouTube app
        "pjkljhegncpnkpknbcohdijeoejaedia", // Gmail app
        "mhjfbmdgcfjbbpaeojofohoefgiehjai", // Chrome PDF Viewer
        "kmendfapggjehodndflmmgagdbamhnfd", // CryptoTokenExtension
        "neajdppkdcdipfabeoofebfddakdcjhd", // Google Network Speech
        "nkeimhogjdpnpccoofpliimaahmaaome", // Google Hangouts
        "fhbjgbiflinjbdggehcddcbncdddomop", // Edge/Chrome component
        "jmjflgjpcpepeafmmgdpfkogkghcpiha", // Edge Shopping/Collections
        "mnojpmjdmbbfmejpflffifhffcmidifd"  // Brave internal
    ]

    private init() {}

    // MARK: - 1. Auto-Detect Installed Browsers & Profiles

    /// Fast, zero-TCC detection of installed browser apps for the `File → Import from Browser` menu.
    func detectInstalledBrowsers() -> [SupportedBrowserKind] {
        SupportedBrowserKind.allCases.filter { $0.isAppInstalled }
    }

    func detectProfiles(for kind: SupportedBrowserKind) -> [DetectedBrowserProfile] {
        detectInstalledProfiles(onlyBrowsers: [kind])
    }

    func detectInstalledProfiles(
        customDirectories: [SupportedBrowserKind: URL] = [:],
        onlyBrowsers: [SupportedBrowserKind]? = nil
    ) -> [DetectedBrowserProfile] {
        let fm = FileManager.default
        var results: [DetectedBrowserProfile] = []
        let targets = onlyBrowsers ?? SupportedBrowserKind.allCases

        for kind in targets {
            let root = customDirectories[kind] ?? kind.userDataDirectory
            let dataExists = fm.fileExists(atPath: root.path)
            let appInstalled = kind.isAppInstalled
            guard dataExists || appInstalled else { continue }

            switch kind {
            case .safari:
                let readable = fm.isReadableFile(atPath: root.appendingPathComponent("Bookmarks.plist").path) ||
                    fm.isReadableFile(atPath: root.appendingPathComponent("History.db").path)
                results.append(DetectedBrowserProfile(
                    browser: .safari,
                    profileName: "Default",
                    directory: root,
                    requiresPermissionGrant: !readable
                ))

            case .orion:
                var blocked = false
                do {
                    _ = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                } catch {
                    blocked = isPermissionError(error)
                }
                if blocked {
                    results.append(DetectedBrowserProfile(
                        browser: .orion,
                        profileName: "Default",
                        directory: root,
                        requiresPermissionGrant: true
                    ))
                } else if fm.fileExists(atPath: root.appendingPathComponent("favourites.plist").path) ||
                          fm.fileExists(atPath: root.appendingPathComponent("history").path) ||
                          appInstalled {
                    results.append(DetectedBrowserProfile(
                        browser: .orion,
                        profileName: "Default",
                        directory: root,
                        requiresPermissionGrant: false
                    ))
                }

            case .firefox, .zen:
                do {
                    let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                    var added = 0
                    for child in children {
                        guard fm.fileExists(atPath: child.appendingPathComponent("places.sqlite").path) else { continue }
                        let rawName = child.lastPathComponent
                        let displayName = rawName.components(separatedBy: ".").last ?? rawName
                        results.append(DetectedBrowserProfile(
                            browser: kind,
                            profileName: displayName,
                            directory: child,
                            requiresPermissionGrant: false
                        ))
                        added += 1
                    }
                    // If user pointed directly at a profile directory containing places.sqlite
                    if added == 0 && fm.fileExists(atPath: root.appendingPathComponent("places.sqlite").path) {
                        results.append(DetectedBrowserProfile(
                            browser: kind,
                            profileName: root.lastPathComponent,
                            directory: root,
                            requiresPermissionGrant: false
                        ))
                    }
                } catch {
                    if isPermissionError(error) || appInstalled {
                        results.append(DetectedBrowserProfile(
                            browser: kind,
                            profileName: "Default",
                            directory: root,
                            requiresPermissionGrant: true
                        ))
                    }
                }

            default:
                // Chromium-family browser (Chrome, Brave, Edge, Arc, Vivaldi, Opera, etc.)
                // First check if user selected a single profile subfolder directly (contains Bookmarks / History / Extensions)
                if hasChromiumProfileData(in: root) {
                    results.append(DetectedBrowserProfile(
                        browser: kind,
                        profileName: root.lastPathComponent,
                        directory: root,
                        requiresPermissionGrant: false
                    ))
                    continue
                }

                do {
                    let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                    let profileDisplayNames = readChromiumLocalStateProfileNames(userDataDir: root)
                    var foundProfiles: [DetectedBrowserProfile] = []
                    for child in children {
                        let folderName = child.lastPathComponent
                        guard folderName == "Default" || folderName.hasPrefix("Profile ") else { continue }
                        guard hasChromiumProfileData(in: child) else { continue }
                        let label = profileDisplayNames[folderName] ?? folderName
                        foundProfiles.append(DetectedBrowserProfile(
                            browser: kind,
                            profileName: label,
                            directory: child,
                            requiresPermissionGrant: false
                        ))
                    }
                    foundProfiles.sort { a, b in
                        if a.directory.lastPathComponent == "Default" { return true }
                        if b.directory.lastPathComponent == "Default" { return false }
                        return a.profileName.localizedCaseInsensitiveCompare(b.profileName) == .orderedAscending
                    }
                    if !foundProfiles.isEmpty {
                        results.append(contentsOf: foundProfiles)
                    } else if appInstalled {
                        results.append(DetectedBrowserProfile(
                            browser: kind,
                            profileName: "Default",
                            directory: root,
                            requiresPermissionGrant: false
                        ))
                    }
                } catch {
                    // macOS Tahoe / Sequoia App Data Protection (TCC EPERM) blocks reading ~/Library/Application Support/Google/Chrome
                    // until the user grants access via NSOpenPanel or Full Disk Access. Surface the browser so the user can grant access in 1 click!
                    if isPermissionError(error) || appInstalled {
                        results.append(DetectedBrowserProfile(
                            browser: kind,
                            profileName: "Default",
                            directory: root,
                            requiresPermissionGrant: true
                        ))
                    }
                }
            }
        }

        // Order: installed apps first (preserving Chrome, Safari, Brave, Edge...), then residual data-only browsers
        let installed = results.filter { $0.browser.isAppInstalled }
        let residual = results.filter { !$0.browser.isAppInstalled }
        return installed + residual
    }

    func hasChromiumProfileData(in dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("Bookmarks").path) ||
               fm.fileExists(atPath: dir.appendingPathComponent("History").path) ||
               fm.fileExists(atPath: dir.appendingPathComponent("Extensions").path)
    }

    func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoPermissionError || ns.code == 257) {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) {
            return true
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionError(underlying)
        }
        return false
    }

    func readChromiumLocalStateProfileNames(userDataDir: URL) -> [String: String] {
        let localStateURL = userDataDir.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: localStateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let infoCache = profile["info_cache"] as? [String: Any] else {
            return [:]
        }
        var names: [String: String] = [:]
        for (dirName, raw) in infoCache {
            if let dict = raw as? [String: Any],
               let name = dict["name"] as? String, !name.isEmpty {
                names[dirName] = name
            }
        }
        return names
    }

    // MARK: - 2. Scan a Browser Profile

    func scan(
        profile: DetectedBrowserProfile,
        installedExtensionIDs: Set<String>,
        installedExtensionNames: Set<String> = []
    ) -> BrowserProfileScan {
        if profile.requiresPermissionGrant && profile.browser != .safari {
            return BrowserProfileScan(
                profile: profile,
                bookmarks: [],
                readingList: [],
                history: [],
                extensions: [],
                accessBlocked: true
            )
        }
        switch profile.browser {
        case .safari:
            return scanSafari(
                profile: profile,
                installedExtensionIDs: installedExtensionIDs,
                installedExtensionNames: installedExtensionNames
            )
        case .orion:
            return scanOrion(
                profile: profile,
                installedExtensionIDs: installedExtensionIDs,
                installedExtensionNames: installedExtensionNames
            )
        case .firefox, .zen:
            return scanGecko(profile: profile)
        default:
            return scanChromium(
                profile: profile,
                installedExtensionIDs: installedExtensionIDs,
                installedExtensionNames: installedExtensionNames
            )
        }
    }

    // MARK: - Chromium Scanner (Chrome / Brave / Edge / Arc / Vivaldi / Opera)

    func scanChromium(
        profile: DetectedBrowserProfile,
        installedExtensionIDs: Set<String>,
        installedExtensionNames: Set<String>
    ) -> BrowserProfileScan {
        do {
            _ = try FileManager.default.contentsOfDirectory(at: profile.directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            if isPermissionError(error) {
                return BrowserProfileScan(
                    profile: profile,
                    bookmarks: [],
                    readingList: [],
                    history: [],
                    extensions: [],
                    accessBlocked: true
                )
            }
        }

        let (bookmarks, readingList) = parseChromiumBookmarks(fileURL: profile.directory.appendingPathComponent("Bookmarks"))
        let history = parseChromiumHistory(dbURL: profile.directory.appendingPathComponent("History"))
        let extensions = scanChromiumExtensions(
            profileDir: profile.directory,
            installedExtensionIDs: installedExtensionIDs,
            installedExtensionNames: installedExtensionNames
        )
        return BrowserProfileScan(
            profile: profile,
            bookmarks: bookmarks,
            readingList: readingList,
            history: history,
            extensions: extensions,
            accessBlocked: false
        )
    }

    func parseChromiumBookmarks(fileURL: URL) -> ([AssetLoader.BookmarkEntry], [AssetLoader.ReadingListItem]) {
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else {
            return ([], [])
        }

        var bookmarks: [AssetLoader.BookmarkEntry] = []
        var readingList: [AssetLoader.ReadingListItem] = []
        var seenURLs = Set<String>()

        func walk(node: [String: Any], isReadingList: Bool, depth: Int = 0) {
            guard depth <= 64 else { return }  // hostile profile with absurd folder nesting must not overflow the stack
            let type = node["type"] as? String ?? ""
            let name = (node["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if type == "url", let urlStr = node["url"] as? String,
               isValidWebURL(urlStr) {
                let key = (isReadingList ? "rl|" : "bm|") + AssetLoader.normalizedURLKey(urlStr)
                guard !seenURLs.contains(key) else { return }
                seenURLs.insert(key)
                let resolvedTitle = name.isEmpty ? URLInputNormalizer.displayDomain(for: URL(string: urlStr)) : name
                if isReadingList {
                    readingList.append(AssetLoader.ReadingListItem(
                        id: "imp-rl-\(UUID().uuidString.prefix(8))",
                        title: resolvedTitle,
                        url: urlStr,
                        addedAt: Date()
                    ))
                } else {
                    bookmarks.append(AssetLoader.BookmarkEntry(
                        id: "imp-bm-\(UUID().uuidString.prefix(8))",
                        title: resolvedTitle,
                        url: urlStr,
                        color: nil
                    ))
                }
                return
            }
            if let children = node["children"] as? [[String: Any]] {
                let childIsRL = isReadingList || name.caseInsensitiveCompare("Reading List") == .orderedSame
                for child in children {
                    walk(node: child, isReadingList: childIsRL, depth: depth + 1)
                }
            }
        }

        for rootKey in ["bookmark_bar", "other", "synced"] {
            if let node = roots[rootKey] as? [String: Any] {
                walk(node: node, isReadingList: false)
            }
        }
        return (bookmarks, readingList)
    }

    func parseChromiumHistory(dbURL: URL, limit: Int = 600) -> [AssetLoader.HistoryEntry] {
        return withCopiedSQLiteDatabase(at: dbURL) { db in
            var entries: [AssetLoader.HistoryEntry] = []
            let sql = """
            SELECT url, title, visit_count, last_visit_time
            FROM urls
            WHERE url LIKE 'http%' AND hidden = 0
            ORDER BY last_visit_time DESC
            LIMIT \(limit);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let urlC = sqlite3_column_text(stmt, 0) else { continue }
                let urlStr = String(cString: urlC)
                guard isValidWebURL(urlStr) else { continue }
                let titleStr: String
                if let titleC = sqlite3_column_text(stmt, 1) {
                    titleStr = String(cString: titleC).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    titleStr = ""
                }
                let visits = Int(sqlite3_column_int(stmt, 2))
                let chromeMicros = sqlite3_column_int64(stmt, 3)
                let unixSec = Double(chromeMicros) / 1_000_000.0 - 11_644_473_600.0
                let date = (unixSec > 946_684_800 && unixSec < 4_102_444_800) ? Date(timeIntervalSince1970: unixSec) : Date()
                let resolvedTitle = titleStr.isEmpty ? URLInputNormalizer.displayDomain(for: URL(string: urlStr)) : titleStr
                entries.append(AssetLoader.HistoryEntry(
                    title: resolvedTitle,
                    url: urlStr,
                    visitCount: max(1, visits),
                    lastVisited: date
                ))
            }
            return entries
        }
    }

    func scanChromiumExtensions(
        profileDir: URL,
        installedExtensionIDs: Set<String>,
        installedExtensionNames: Set<String>
    ) -> [ImportedExtensionCandidate] {
        let fm = FileManager.default
        let extRoot = profileDir.appendingPathComponent("Extensions", isDirectory: true)
        var candidates: [ImportedExtensionCandidate] = []
        var seenIDs = Set<String>()

        let prefSettings = readChromiumPreferencesExtensionSettings(profileDir: profileDir)

        if let idDirs = try? fm.contentsOfDirectory(at: extRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for idDir in idDirs {
                let extID = idDir.lastPathComponent.lowercased()
                guard Self.isValidChromiumExtensionID(extID),
                      !Self.ignoredComponentExtensionIDs.contains(extID),
                      !seenIDs.contains(extID) else { continue }

                guard let verDirs = try? fm.contentsOfDirectory(at: idDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                    continue
                }
                let validVerDirs = verDirs
                    .filter { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
                    .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }

                guard let latestDir = validVerDirs.first,
                      !isThemeManifest(in: latestDir),
                      let candidate = buildExtensionCandidate(
                        extID: extID,
                        storeID: extID,
                        manifestDir: latestDir,
                        fromSafariBundle: false,
                        installedExtensionIDs: installedExtensionIDs,
                        installedExtensionNames: installedExtensionNames
                      ) else { continue }

                seenIDs.insert(extID)
                candidates.append(candidate)
            }
        }

        // Sideloaded / unpacked extensions recorded in Preferences
        for (rawID, settings) in prefSettings {
            let extID = rawID.lowercased()
            guard Self.isValidChromiumExtensionID(extID),
                  !Self.ignoredComponentExtensionIDs.contains(extID),
                  !seenIDs.contains(extID),
                  let pathStr = settings["path"] as? String,
                  !pathStr.isEmpty else { continue }
            let localDir = pathStr.hasPrefix("/")
                ? URL(fileURLWithPath: pathStr, isDirectory: true)
                : extRoot.appendingPathComponent(pathStr, isDirectory: true)
            guard fm.fileExists(atPath: localDir.appendingPathComponent("manifest.json").path),
                  !isThemeManifest(in: localDir),
                  let candidate = buildExtensionCandidate(
                    extID: extID,
                    storeID: nil,
                    manifestDir: localDir,
                    fromSafariBundle: false,
                    installedExtensionIDs: installedExtensionIDs,
                    installedExtensionNames: installedExtensionNames
                  ) else { continue }
            seenIDs.insert(extID)
            candidates.append(candidate)
        }

        candidates.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return candidates
    }

    func readChromiumPreferencesExtensionSettings(profileDir: URL) -> [String: [String: Any]] {
        for filename in ["Preferences", "Secure Preferences"] {
            let url = profileDir.appendingPathComponent(filename)
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let extensions = json["extensions"] as? [String: Any],
               let settings = extensions["settings"] as? [String: [String: Any]] {
                return settings
            }
        }
        return [:]
    }

    func isThemeManifest(in dir: URL) -> Bool {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return manifest["theme"] != nil
    }

    func buildExtensionCandidate(
        extID: String,
        storeID: String?,
        manifestDir: URL,
        fromSafariBundle: Bool,
        installedExtensionIDs: Set<String>,
        installedExtensionNames: Set<String>
    ) -> ImportedExtensionCandidate? {
        let manifestURL = manifestDir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let manifestVersion = manifest["manifest_version"] as? Int ?? 3
        let rawName = (manifest["name"] as? String) ?? extID
        let name = resolveLocalizedManifestString(rawName, in: manifestDir, manifest: manifest)
        let resolvedName = name.isEmpty ? extID : name
        let version = (manifest["version"] as? String) ?? "1.0"
        let hasKey = ((manifest["key"] as? String)?.isEmpty == false)
        let icon = loadBestExtensionIcon(in: manifestDir, manifest: manifest)
        let alreadyInstalled = installedExtensionIDs.contains(extID.lowercased()) ||
            installedExtensionNames.contains(resolvedName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let compatibility = ExtensionCompatibilityConverter.shared.analyze(
            manifestDir: manifestDir,
            fromSafariBundle: fromSafariBundle
        )

        return ImportedExtensionCandidate(
            id: extID,
            name: resolvedName,
            version: version,
            icon: icon,
            localDirectory: manifestDir,
            storeID: storeID,
            hasManifestKey: hasKey,
            isAlreadyInstalled: alreadyInstalled,
            manifestVersion: manifestVersion,
            compatibility: compatibility
        )
    }

    func resolveLocalizedManifestString(_ raw: String, in dir: URL, manifest: [String: Any]) -> String {
        guard raw.hasPrefix("__MSG_") && raw.hasSuffix("__") else { return raw }
        let key = String(raw.dropFirst(6).dropLast(2))
        let defaultLocale = (manifest["default_locale"] as? String) ?? "en"
        let locales = [defaultLocale, "en", "en_US", "en_GB"]
        for loc in locales {
            let msgURL = dir.appendingPathComponent("_locales/\(loc)/messages.json")
            guard let data = try? Data(contentsOf: msgURL),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let entry = dict[key] as? [String: Any], let msg = entry["message"] as? String, !msg.isEmpty {
                return msg
            }
            for (k, v) in dict where k.caseInsensitiveCompare(key) == .orderedSame {
                if let entry = v as? [String: Any], let msg = entry["message"] as? String, !msg.isEmpty {
                    return msg
                }
            }
        }
        return raw
    }

    func loadBestExtensionIcon(in dir: URL, manifest: [String: Any]) -> NSImage? {
        func pickPath(from raw: Any?) -> String? {
            if let str = raw as? String, !str.isEmpty { return str }
            if let dict = raw as? [String: Any] {
                for key in ["64", "48", "128", "38", "32", "96", "19", "16"] {
                    if let p = dict[key] as? String, !p.isEmpty { return p }
                }
                for (_, v) in dict {
                    if let p = v as? String, !p.isEmpty { return p }
                }
            }
            return nil
        }

        let action = (manifest["action"] as? [String: Any]) ?? (manifest["browser_action"] as? [String: Any])
        let relPath = pickPath(from: action?["default_icon"]) ?? pickPath(from: manifest["icons"])
        guard let relPath else { return nil }
        let clean = relPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let iconURL = dir.appendingPathComponent(clean)
        guard let img = NSImage(contentsOf: iconURL) else { return nil }
        img.size = NSSize(width: 22, height: 22)
        return img
    }

    // MARK: - Safari Scanner (Bookmarks.plist, History.db, Safari Web Extensions)

    func scanSafari(
        profile: DetectedBrowserProfile,
        installedExtensionIDs: Set<String>,
        installedExtensionNames: Set<String>
    ) -> BrowserProfileScan {
        let fm = FileManager.default
        let bookmarksURL = profile.directory.appendingPathComponent("Bookmarks.plist")
        let historyURL = profile.directory.appendingPathComponent("History.db")

        let canReadBookmarks = fm.isReadableFile(atPath: bookmarksURL.path)
        let canReadHistory = fm.isReadableFile(atPath: historyURL.path)
        let accessBlocked = !canReadBookmarks && !canReadHistory

        let (bookmarks, readingList) = canReadBookmarks ? parseSafariBookmarksPlist(fileURL: bookmarksURL) : ([], [])
        let history = canReadHistory ? parseSafariHistory(dbURL: historyURL) : []
        let extensions = scanSafariWebExtensions(
            installedExtensionIDs: installedExtensionIDs,
            installedExtensionNames: installedExtensionNames
        )

        return BrowserProfileScan(
            profile: profile,
            bookmarks: bookmarks,
            readingList: readingList,
            history: history,
            extensions: extensions,
            accessBlocked: accessBlocked
        )
    }

    func parseSafariBookmarksPlist(fileURL: URL) -> ([AssetLoader.BookmarkEntry], [AssetLoader.ReadingListItem]) {
        guard let data = try? Data(contentsOf: fileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return ([], [])
        }

        var favorites: [AssetLoader.BookmarkEntry] = []
        var otherBookmarks: [AssetLoader.BookmarkEntry] = []
        var readingList: [AssetLoader.ReadingListItem] = []
        var seenURLs = Set<String>()

        func walk(node: [String: Any], inFavorites: Bool, inReadingList: Bool, depth: Int = 0) {
            guard depth <= 64 else { return }
            let type = node["WebBookmarkType"] as? String ?? ""
            let folderTitle = node["Title"] as? String ?? ""

            if type == "WebBookmarkTypeLeaf", let urlStr = node["URLString"] as? String, isValidWebURL(urlStr) {
                let key = (inReadingList ? "rl|" : "bm|") + AssetLoader.normalizedURLKey(urlStr)
                guard !seenURLs.contains(key) else { return }
                seenURLs.insert(key)

                let uriDict = node["URIDictionary"] as? [String: Any]
                let rawTitle = (uriDict?["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let title = rawTitle.isEmpty ? URLInputNormalizer.displayDomain(for: URL(string: urlStr)) : rawTitle

                if inReadingList {
                    let rlDict = node["ReadingList"] as? [String: Any]
                    let added = (rlDict?["DateAdded"] as? Date) ?? Date()
                    readingList.append(AssetLoader.ReadingListItem(
                        id: "imp-srl-\(UUID().uuidString.prefix(8))",
                        title: title,
                        url: urlStr,
                        addedAt: added
                    ))
                } else {
                    let entry = AssetLoader.BookmarkEntry(
                        id: "imp-sbm-\(UUID().uuidString.prefix(8))",
                        title: title,
                        url: urlStr,
                        color: nil
                    )
                    if inFavorites {
                        favorites.append(entry)
                    } else {
                        otherBookmarks.append(entry)
                    }
                }
                return
            }

            if let children = node["Children"] as? [[String: Any]] {
                let nextFav = inFavorites || folderTitle == "BookmarksBar"
                let nextRL = inReadingList || folderTitle == "com.apple.ReadingList"
                for child in children {
                    walk(node: child, inFavorites: nextFav, inReadingList: nextRL, depth: depth + 1)
                }
            }
        }

        walk(node: plist, inFavorites: false, inReadingList: false)
        return (favorites + otherBookmarks, readingList)
    }

    func parseSafariHistory(dbURL: URL, limit: Int = 600) -> [AssetLoader.HistoryEntry] {
        return withCopiedSQLiteDatabase(at: dbURL) { db in
            var entries: [AssetLoader.HistoryEntry] = []
            let sql = """
            SELECT hi.url,
                   COALESCE((SELECT title FROM history_visits hv WHERE hv.history_item = hi.id AND hv.title IS NOT NULL AND hv.title != '' ORDER BY hv.visit_time DESC LIMIT 1), ''),
                   hi.visit_count,
                   COALESCE((SELECT MAX(visit_time) FROM history_visits hv WHERE hv.history_item = hi.id), 0)
            FROM history_items hi
            WHERE hi.url LIKE 'http%'
            ORDER BY 4 DESC
            LIMIT \(limit);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let urlC = sqlite3_column_text(stmt, 0) else { continue }
                let urlStr = String(cString: urlC)
                guard isValidWebURL(urlStr) else { continue }
                let titleStr = sqlite3_column_text(stmt, 1).map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                let visits = Int(sqlite3_column_int(stmt, 2))
                let cocoaTime = sqlite3_column_double(stmt, 3)
                let date = cocoaTime > 0 ? Date(timeIntervalSinceReferenceDate: cocoaTime) : Date()
                let resolvedTitle = titleStr.isEmpty ? URLInputNormalizer.displayDomain(for: URL(string: urlStr)) : titleStr
                entries.append(AssetLoader.HistoryEntry(
                    title: resolvedTitle,
                    url: urlStr,
                    visitCount: max(1, visits),
                    lastVisited: date
                ))
            }
            return entries
        }
    }

    func scanSafariWebExtensions(
        installedExtensionIDs: Set<String>,
        installedExtensionNames: Set<String>
    ) -> [ImportedExtensionCandidate] {
        let fm = FileManager.default
        let appDirs = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Applications", isDirectory: true)
        ]
        var candidates: [ImportedExtensionCandidate] = []
        var seenNames = Set<String>()

        for appDir in appDirs {
            guard let apps = try? fm.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for appURL in apps where appURL.pathExtension == "app" {
                let plugInsURL = appURL.appendingPathComponent("Contents/PlugIns", isDirectory: true)
                guard let plugIns = try? fm.contentsOfDirectory(at: plugInsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                    continue
                }
                for plugIn in plugIns where plugIn.pathExtension == "appex" {
                    let resDir = plugIn.appendingPathComponent("Contents/Resources", isDirectory: true)
                    let manifestURL = resDir.appendingPathComponent("manifest.json")
                    guard fm.fileExists(atPath: manifestURL.path) else { continue }
                    let syntheticID = "safari-\(plugIn.deletingPathExtension().lastPathComponent.lowercased())"
                    guard let candidate = buildExtensionCandidate(
                        extID: syntheticID,
                        storeID: nil,
                        manifestDir: resDir,
                        fromSafariBundle: true,
                        installedExtensionIDs: installedExtensionIDs,
                        installedExtensionNames: installedExtensionNames
                    ) else { continue }
                    let dedupKey = candidate.name.lowercased()
                    guard !seenNames.contains(dedupKey) else { continue }
                    seenNames.insert(dedupKey)
                    candidates.append(candidate)
                }
            }
        }
        candidates.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return candidates
    }

    // MARK: - Orion Scanner

    func scanOrion(
        profile: DetectedBrowserProfile,
        installedExtensionIDs: Set<String>,
        installedExtensionNames: Set<String>
    ) -> BrowserProfileScan {
        let bookmarksURL = profile.directory.appendingPathComponent("favourites.plist")
        let (bookmarks, readingList) = parseSafariBookmarksPlist(fileURL: bookmarksURL)
        let history = parseSafariHistory(dbURL: profile.directory.appendingPathComponent("history"))
        let extensions = scanChromiumExtensions(
            profileDir: profile.directory,
            installedExtensionIDs: installedExtensionIDs,
            installedExtensionNames: installedExtensionNames
        )
        return BrowserProfileScan(
            profile: profile,
            bookmarks: bookmarks,
            readingList: readingList,
            history: history,
            extensions: extensions,
            accessBlocked: false
        )
    }

    // MARK: - Firefox / Zen Scanner (`places.sqlite`)

    func scanGecko(profile: DetectedBrowserProfile) -> BrowserProfileScan {
        let placesURL = profile.directory.appendingPathComponent("places.sqlite")
        let bookmarks: [AssetLoader.BookmarkEntry] = withCopiedSQLiteDatabase(at: placesURL) { db in
            var items: [AssetLoader.BookmarkEntry] = []
            var seen = Set<String>()
            let sql = """
            SELECT p.url, COALESCE(b.title, p.title, '')
            FROM moz_bookmarks b
            JOIN moz_places p ON b.fk = p.id
            WHERE b.type = 1 AND p.url LIKE 'http%'
            ORDER BY b.dateAdded DESC
            LIMIT 800;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let urlC = sqlite3_column_text(stmt, 0) else { continue }
                let urlStr = String(cString: urlC)
                let key = AssetLoader.normalizedURLKey(urlStr)
                guard isValidWebURL(urlStr), !seen.contains(key) else { continue }
                seen.insert(key)
                let rawTitle = sqlite3_column_text(stmt, 1).map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                let title = rawTitle.isEmpty ? URLInputNormalizer.displayDomain(for: URL(string: urlStr)) : rawTitle
                items.append(AssetLoader.BookmarkEntry(
                    id: "imp-ff-\(UUID().uuidString.prefix(8))",
                    title: title,
                    url: urlStr,
                    color: nil
                ))
            }
            return items
        }

        let history: [AssetLoader.HistoryEntry] = withCopiedSQLiteDatabase(at: placesURL) { db in
            var items: [AssetLoader.HistoryEntry] = []
            let sql = """
            SELECT url, COALESCE(title, ''), visit_count, last_visit_date
            FROM moz_places
            WHERE url LIKE 'http%' AND hidden = 0 AND visit_count > 0
            ORDER BY last_visit_date DESC
            LIMIT 600;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let urlC = sqlite3_column_text(stmt, 0) else { continue }
                let urlStr = String(cString: urlC)
                guard isValidWebURL(urlStr) else { continue }
                let rawTitle = sqlite3_column_text(stmt, 1).map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                let visits = Int(sqlite3_column_int(stmt, 2))
                let micros = sqlite3_column_int64(stmt, 3)
                let date = micros > 0 ? Date(timeIntervalSince1970: Double(micros) / 1_000_000.0) : Date()
                let title = rawTitle.isEmpty ? URLInputNormalizer.displayDomain(for: URL(string: urlStr)) : rawTitle
                items.append(AssetLoader.HistoryEntry(
                    title: title,
                    url: urlStr,
                    visitCount: max(1, visits),
                    lastVisited: date
                ))
            }
            return items
        }

        return BrowserProfileScan(
            profile: profile,
            bookmarks: bookmarks,
            readingList: [],
            history: history,
            extensions: [],
            accessBlocked: false
        )
    }

    // MARK: - Netscape Bookmarks HTML Parser (Universal Export Fallback)

    func parseNetscapeBookmarksHTML(at fileURL: URL) -> [AssetLoader.BookmarkEntry] {
        guard let html = (try? String(contentsOf: fileURL, encoding: .utf8))
            ?? (try? String(contentsOf: fileURL, encoding: .isoLatin1)) else {
            return []
        }
        let pattern = #"<A\s+[^>]*HREF="([^"]+)"[^>]*>([^<]*)</A>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var entries: [AssetLoader.BookmarkEntry] = []
        var seen = Set<String>()
        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let urlStr = decodeHTMLEntities(ns.substring(with: match.range(at: 1))).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidWebURL(urlStr) else { continue }
            let key = AssetLoader.normalizedURLKey(urlStr)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let rawTitle = decodeHTMLEntities(ns.substring(with: match.range(at: 2))).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.isEmpty ? URLInputNormalizer.displayDomain(for: URL(string: urlStr)) : rawTitle
            entries.append(AssetLoader.BookmarkEntry(
                id: "imp-html-\(UUID().uuidString.prefix(8))",
                title: title,
                url: urlStr,
                color: nil
            ))
        }
        return entries
    }

    func decodeNumericCharacterReferences(_ s: String) -> String {
        guard s.contains("&#"), let regex = try? NSRegularExpression(pattern: "&#([0-9]{1,7}|[xX][0-9a-fA-F]{1,6});") else { return s }
        var out = ""
        var last = s.startIndex
        let ns = s as NSString
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let full = Range(m.range, in: s), let body = Range(m.range(at: 1), in: s) else { continue }
            let text = String(s[body])
            let value = (text.first == "x" || text.first == "X") ? UInt32(text.dropFirst(), radix: 16) : UInt32(text)
            out += s[last..<full.lowerBound]
            if let v = value, let scalar = Unicode.Scalar(v) { out.unicodeScalars.append(scalar) } else { out += s[full] }
            last = full.upperBound
        }
        out += s[last...]
        return out
    }

    func decodeHTMLEntities(_ s: String) -> String {
        // Numeric character references first (&#38; / &#x26;), then the named ones; "&amp;" must be decoded last so
        // "&amp;lt;" becomes "&lt;" and not "<".
        decodeNumericCharacterReferences(s).replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&apos;", with: "'")
         .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - 3. Execute Import (Bookmarks, History, Reading List & Live Extensions)

    func performImport(
        scan: BrowserProfileScan,
        selection: BrowserImportSelection,
        engine: BrowserEngine,
        onProgress: @escaping (_ status: String, _ fraction: Double) -> Void,
        completion: @escaping (BrowserImportResult) -> Void
    ) {
        var result = BrowserImportResult()

        let selectedExtensions = scan.extensions.filter { selection.selectedExtensionIDs.contains($0.id) }
        let totalSteps = (selection.importBookmarks ? 1 : 0) +
                         (selection.importHistory ? 1 : 0) +
                         (selection.importReadingList ? 1 : 0) +
                         selectedExtensions.count
        let denom = Double(max(1, totalSteps))
        var completedSteps = 0

        if selection.importBookmarks {
            onProgress("Importing bookmarks…", Double(completedSteps) / denom)
            result.bookmarksImported = AssetLoader.shared.mergeImportedFavorites(scan.bookmarks, prepend: true)
            completedSteps += 1
        }

        if selection.importReadingList {
            onProgress("Importing Reading List…", Double(completedSteps) / denom)
            result.readingListImported = AssetLoader.shared.mergeImportedReadingList(scan.readingList)
            completedSteps += 1
        }

        if selection.importHistory {
            onProgress("Importing browsing history…", Double(completedSteps) / denom)
            result.historyImported = AssetLoader.shared.mergeImportedHistory(scan.history)
            completedSteps += 1
        }

        guard !selectedExtensions.isEmpty else {
            onProgress("Import complete", 1.0)
            completion(result)
            return
        }

        let alreadyInstalled = Set(engine.installedExtensions().map { $0.id.lowercased() })

        func importNextExtension(at idx: Int) {
            if idx >= selectedExtensions.count {
                onProgress("Import complete", 1.0)
                completion(result)
                return
            }

            let ext = selectedExtensions[idx]
            if alreadyInstalled.contains(ext.id.lowercased()) || !ext.compatibility.isImportable {
                result.extensionsSkipped += 1
                completedSteps += 1
                onProgress("Skipped \(ext.name)", Double(completedSteps) / denom)
                DispatchQueue.main.async {
                    importNextExtension(at: idx + 1)
                }
                return
            }

            let isConverting: Bool
            if case .convertible = ext.compatibility {
                isConverting = true
            } else {
                isConverting = false
            }

            onProgress(
                isConverting
                    ? "Converting & installing \(ext.name)… (\(idx + 1)/\(selectedExtensions.count))"
                    : "Installing \(ext.name)… (\(idx + 1)/\(selectedExtensions.count))",
                Double(completedSteps) / denom
            )

            let finishOne: (Bool) -> Void = { success in
                DispatchQueue.main.async {
                    if success {
                        result.extensionsImported += 1
                    } else {
                        result.extensionsFailed += 1
                    }
                    completedSteps += 1
                    onProgress(
                        success ? "Installed \(ext.name)" : "Could not install \(ext.name)",
                        Double(completedSteps) / denom
                    )
                    importNextExtension(at: idx + 1)
                }
            }

            // If conversion is required (MV2, Safari background.scripts, browser.* polyfill, host_permissions split),
            // convert cleanly into a Chromium 156 MV3 bundle BEFORE loading — never blindly load incompatible manifests.
            if isConverting, let localDir = ext.localDirectory {
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let convertedDir = try ExtensionCompatibilityConverter.shared.convertToChromiumMV3(
                            sourceDir: localDir,
                            extensionID: ext.id
                        )
                        DispatchQueue.main.async {
                            engine.loadUnpackedExtension(atPath: convertedDir.path, completion: finishOne)
                        }
                    } catch {
                        NSLog("[Safarium] Extension conversion failed for %@: %@", ext.name, error.localizedDescription)
                        finishOne(false)
                    }
                }
            } else if let localDir = ext.localDirectory, ext.hasManifestKey {
                engine.loadUnpackedExtension(atPath: localDir.path) { ok in
                    if ok {
                        finishOne(true)
                    } else if let storeID = ext.storeID, Self.isValidChromiumExtensionID(storeID) {
                        engine.installExtensionFromChromeWebStoreID(storeID, completion: finishOne)
                    } else {
                        finishOne(false)
                    }
                }
            } else if let storeID = ext.storeID, Self.isValidChromiumExtensionID(storeID) {
                engine.installExtensionFromChromeWebStoreID(storeID) { ok in
                    if ok {
                        finishOne(true)
                    } else if let localDir = ext.localDirectory {
                        engine.loadUnpackedExtension(atPath: localDir.path, completion: finishOne)
                    } else {
                        finishOne(false)
                    }
                }
            } else if let localDir = ext.localDirectory {
                engine.loadUnpackedExtension(atPath: localDir.path, completion: finishOne)
            } else {
                finishOne(false)
            }
        }

        importNextExtension(at: 0)
    }

    // MARK: - Helpers

    func isValidWebURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else { return false }
        guard let host = URLComponents(string: trimmed)?.host, !host.isEmpty else { return false }
        return true
    }

    static func isValidChromiumExtensionID(_ id: String) -> Bool {
        guard id.count == 32 else { return false }
        for scalar in id.unicodeScalars {
            if scalar.value < 97 || scalar.value > 112 {
                return false
            }
        }
        return true
    }

    func withCopiedSQLiteDatabase<T>(at sourceURL: URL, _ body: (OpaquePointer) -> T) -> T where T: RangeReplaceableCollection {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: sourceURL.path) else { return T() }
        let tempDir = fm.temporaryDirectory.appendingPathComponent("safarium-import-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return T()
        }
        defer { try? fm.removeItem(at: tempDir) }

        let tempDB = tempDir.appendingPathComponent("copy.sqlite")
        do {
            try fm.copyItem(at: sourceURL, to: tempDB)
        } catch {
            return T()
        }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: sourceURL.path + suffix)
            if fm.fileExists(atPath: sidecar.path) {
                try? fm.copyItem(at: sidecar, to: URL(fileURLWithPath: tempDB.path + suffix))
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tempDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return T()
        }
        defer { sqlite3_close(db) }
        return body(db)
    }
}
