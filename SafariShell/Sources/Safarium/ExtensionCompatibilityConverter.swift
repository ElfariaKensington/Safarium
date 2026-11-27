import Foundation

/// Compatibility classification for extensions discovered in Safari, Chrome, Brave, Edge, Firefox, etc.
enum ExtensionCompatibility: Equatable {
    case nativeMV3
    case convertible(reasons: [String])
    case incompatible(reason: String)

    var isImportable: Bool {
        switch self {
        case .nativeMV3, .convertible:
            return true
        case .incompatible:
            return false
        }
    }

    var shortBadgeText: String? {
        switch self {
        case .nativeMV3:
            return nil
        case .convertible:
            return "Auto-Convert"
        case .incompatible:
            return "Incompatible"
        }
    }

    var detailTooltip: String? {
        switch self {
        case .nativeMV3:
            return "Native Chromium Manifest V3 extension."
        case .convertible(let reasons):
            return "Will be converted for Chromium MV3: " + reasons.joined(separator: ", ")
        case .incompatible(let reason):
            return reason
        }
    }
}

/// Analyzes and converts MV2, Safari WebExtension, and Firefox WebExtension bundles into
/// strict Chromium 156 Manifest V3 extensions before loading them into BrowserCore.
final class ExtensionCompatibilityConverter {
    static let shared = ExtensionCompatibilityConverter()

    private static let mv2DisallowedPermissions: Set<String> = [
        "webRequestBlocking",
        "background",
        "nativeMessaging"
    ]

    private init() {}

    // MARK: - 1. Compatibility Analyzer

    func analyze(manifestDir: URL, fromSafariBundle: Bool) -> ExtensionCompatibility {
        let fm = FileManager.default
        let manifestURL = manifestDir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .incompatible(reason: "Missing or invalid manifest.json")
        }

        if manifest["theme"] != nil {
            return .incompatible(reason: "Browser themes are not supported")
        }

        let mv = manifest["manifest_version"] as? Int ?? 0
        guard mv == 2 || mv == 3 else {
            return .incompatible(reason: "Unsupported manifest version (\(mv))")
        }

        let permissions = (manifest["permissions"] as? [String]) ?? []
        let optionalPerms = (manifest["optional_permissions"] as? [String]) ?? []
        let allPerms = Set(permissions + optionalPerms)

        // Pure MV2 blocking webRequest extensions without DNR cannot function in Chromium MV3.
        if allPerms.contains("webRequestBlocking") && !allPerms.contains("declarativeNetRequest") && !allPerms.contains("declarativeNetRequestWithHostAccess") {
            return .incompatible(reason: "Uses MV2 webRequestBlocking (unsupported in Chromium MV3)")
        }

        // Safari .appex extensions whose core functionality relies on Safari's Swift host via nativeMessaging
        // cannot talk to the Swift appex host from Chromium without a Chrome NativeMessagingHost JSON.
        if fromSafariBundle && permissions.contains("nativeMessaging") {
            return .incompatible(reason: "Requires native Safari host app bridge")
        }

        // Extensions relying on chrome_url_overrides / devtools-only native hooks or missing entry scripts
        var conversionReasons: [String] = []

        if mv == 2 {
            conversionReasons.append("MV2 → MV3")
        }

        if let bg = manifest["background"] as? [String: Any] {
            if let scripts = bg["scripts"] as? [String], !scripts.isEmpty, bg["service_worker"] == nil {
                conversionReasons.append("background.scripts → Service Worker")
            } else if let page = bg["page"] as? String, !page.isEmpty, bg["service_worker"] == nil {
                let pageURL = manifestDir.appendingPathComponent(page.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                if !fm.fileExists(atPath: pageURL.path) {
                    return .incompatible(reason: "Background page '\(page)' not found")
                }
                conversionReasons.append("background.page → Service Worker")
            }
            if bg["persistent"] != nil {
                conversionReasons.append("strip background.persistent")
            }
        }

        if manifest["browser_action"] != nil || manifest["page_action"] != nil {
            conversionReasons.append("browser_action → action")
        }

        let hasHostPatternInPerms = permissions.contains(where: Self.isHostPattern)
        if hasHostPatternInPerms {
            conversionReasons.append("move host patterns → host_permissions")
        }

        if let war = manifest["web_accessible_resources"] as? [String], !war.isEmpty {
            conversionReasons.append("upgrade web_accessible_resources")
        }

        if manifest["content_security_policy"] is String {
            conversionReasons.append("upgrade CSP format")
        }

        if manifest["browser_specific_settings"] != nil || manifest["applications"] != nil {
            conversionReasons.append("strip Safari/Firefox manifest keys")
        }

        if fromSafariBundle {
            // Check whether extension scripts reference the WebExtension `browser.` namespace
            if usesBrowserNamespace(in: manifestDir, manifest: manifest) {
                conversionReasons.append("inject browser.* API polyfill")
            }
        }

        if conversionReasons.isEmpty {
            return .nativeMV3
        }
        return .convertible(reasons: conversionReasons)
    }

    // MARK: - 2. Real MV2 / Safari / Firefox → Chromium MV3 Converter

    func convertToChromiumMV3(sourceDir: URL, extensionID: String, stagingRootOverride: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let stagingRoot = stagingRootOverride ?? appSup.appendingPathComponent("Safarium/ConvertedExtensions", isDirectory: true)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        var sanitizedID = extensionID
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9._-]", with: "-", options: .regularExpression)
        // "", "." and ".." would resolve to the staging root itself or its parent (which is then deleted/overwritten).
        if sanitizedID.isEmpty || sanitizedID.allSatisfy({ $0 == "." }) { sanitizedID = "ext-\(sanitizedID.count)" }
        let destDir = stagingRoot.appendingPathComponent(sanitizedID, isDirectory: true)
        if fm.fileExists(atPath: destDir.path) {
            try fm.removeItem(at: destDir)
        }
        try fm.copyItem(at: sourceDir, to: destDir)

        let manifestURL = destDir.appendingPathComponent("manifest.json")
        let rawData = try Data(contentsOf: manifestURL)
        guard var manifest = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
            throw NSError(domain: "com.safarium.ExtConverter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid manifest.json"])
        }

        // 1. Write universal WebExtension `browser.*` -> `chrome.*` + MV2 compat polyfill at root
        let polyfillFilename = "sx-mv3-polyfill.js"
        try Self.webExtensionPolyfillJS.write(
            to: destDir.appendingPathComponent(polyfillFilename),
            atomically: true,
            encoding: .utf8
        )

        // 2. Enforce Manifest V3
        manifest["manifest_version"] = 3

        // 3. Remove Safari / Firefox / MV2-only top-level keys
        manifest.removeValue(forKey: "browser_specific_settings")
        manifest.removeValue(forKey: "applications")
        manifest.removeValue(forKey: "minimum_safari_version")

        // 4. Migrate browser_action / page_action -> action
        if manifest["action"] == nil {
            if let ba = manifest["browser_action"] {
                manifest["action"] = ba
            } else if let pa = manifest["page_action"] {
                manifest["action"] = pa
            }
        }
        manifest.removeValue(forKey: "browser_action")
        manifest.removeValue(forKey: "page_action")

        // 5. Split host patterns out of `permissions` into `host_permissions`
        var existingHosts = (manifest["host_permissions"] as? [String]) ?? []
        var cleanPermissions: [String] = []
        if let rawPerms = manifest["permissions"] as? [String] {
            for p in rawPerms {
                if Self.isHostPattern(p) {
                    if !existingHosts.contains(p) {
                        existingHosts.append(p)
                    }
                } else if !Self.mv2DisallowedPermissions.contains(p) {
                    if !cleanPermissions.contains(p) {
                        cleanPermissions.append(p)
                    }
                }
            }
            manifest["permissions"] = cleanPermissions
        }
        if !existingHosts.isEmpty {
            manifest["host_permissions"] = existingHosts
        }

        // Clean optional_permissions too
        if let rawOpt = manifest["optional_permissions"] as? [String] {
            var optHosts = (manifest["optional_host_permissions"] as? [String]) ?? []
            var cleanOpt: [String] = []
            for p in rawOpt {
                if Self.isHostPattern(p) {
                    if !optHosts.contains(p) { optHosts.append(p) }
                } else if !Self.mv2DisallowedPermissions.contains(p) {
                    if !cleanOpt.contains(p) { cleanOpt.append(p) }
                }
            }
            manifest["optional_permissions"] = cleanOpt
            if !optHosts.isEmpty {
                manifest["optional_host_permissions"] = optHosts
            }
        }

        // 6. Upgrade web_accessible_resources from MV2 [String] to MV3 object array
        if let warStrings = manifest["web_accessible_resources"] as? [String] {
            manifest["web_accessible_resources"] = [[
                "resources": warStrings,
                "matches": ["<all_urls>"]
            ]]
        }

        // 7. Upgrade content_security_policy string -> MV3 dictionary
        if let cspStr = manifest["content_security_policy"] as? String {
            let sanitized = sanitizeMV3CSP(cspStr)
            manifest["content_security_policy"] = ["extension_pages": sanitized]
        }

        // 8. Convert background (`scripts` or `page` or existing `service_worker`) -> MV3 `service_worker`
        if var bg = manifest["background"] as? [String: Any] {
            var bgScripts: [String] = []
            if let scripts = bg["scripts"] as? [String], !scripts.isEmpty {
                bgScripts = scripts
            } else if let pageRel = bg["page"] as? String, !pageRel.isEmpty {
                bgScripts = extractScriptsFromHTML(relativePath: pageRel, in: destDir)
            } else if let existingSW = bg["service_worker"] as? String, !existingSW.isEmpty {
                let isModule = (bg["type"] as? String)?.caseInsensitiveCompare("module") == .orderedSame
                if !isModule {
                    bgScripts = [existingSW]
                }
            }

            if !bgScripts.isEmpty {
                let isModule = (bg["type"] as? String)?.caseInsensitiveCompare("module") == .orderedSame
                let swFilename = "sx-mv3-sw.js"
                let swContent: String
                if isModule {
                    var lines = ["import \(JSStringLiteral.make("/" + polyfillFilename));"]
                    for s in bgScripts {
                        let norm = "/" + s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        lines.append("import \(JSStringLiteral.make(norm));")
                    }
                    swContent = lines.joined(separator: "\n") + "\n"
                } else {
                    let quoted = (["/\(polyfillFilename)"] + bgScripts.map {
                        "/" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    }).map { JSStringLiteral.make($0) }
                    swContent = "importScripts(\(quoted.joined(separator: ", ")));\n"
                }
                try swContent.write(
                    to: destDir.appendingPathComponent(swFilename),
                    atomically: true,
                    encoding: .utf8
                )
                var newBG: [String: Any] = ["service_worker": swFilename]
                if isModule {
                    newBG["type"] = "module"
                }
                manifest["background"] = newBG
            } else {
                bg.removeValue(forKey: "persistent")
                bg.removeValue(forKey: "scripts")
                bg.removeValue(forKey: "page")
                if bg["service_worker"] == nil {
                    manifest.removeValue(forKey: "background")
                } else {
                    manifest["background"] = bg
                }
            }
        }

        // 9. Inject browser.* polyfill into isolated-world content_scripts (never MAIN world)
        if var contentScripts = manifest["content_scripts"] as? [[String: Any]] {
            for idx in contentScripts.indices {
                let world = (contentScripts[idx]["world"] as? String)?.uppercased()
                if world == "MAIN" { continue }
                if var js = contentScripts[idx]["js"] as? [String], !js.isEmpty {
                    if !js.contains(polyfillFilename) {
                        js.insert(polyfillFilename, at: 0)
                        contentScripts[idx]["js"] = js
                    }
                }
            }
            manifest["content_scripts"] = contentScripts
        }

        // 10. Inject polyfill `<script src="/sx-mv3-polyfill.js"></script>` into popup & options HTML pages
        var htmlPagesToPatch: [String] = []
        if let action = manifest["action"] as? [String: Any], let popup = action["default_popup"] as? String {
            htmlPagesToPatch.append(popup)
        }
        if let optUI = manifest["options_ui"] as? [String: Any], let page = optUI["page"] as? String {
            htmlPagesToPatch.append(page)
        }
        if let optPage = manifest["options_page"] as? String {
            htmlPagesToPatch.append(optPage)
        }
        for relPage in Set(htmlPagesToPatch) {
            injectPolyfillIntoHTML(relativePath: relPage, polyfillFilename: polyfillFilename, in: destDir)
        }

        // 11. Write validated MV3 manifest.json
        let updatedData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try updatedData.write(to: manifestURL, options: .atomic)

        return destDir
    }

    // MARK: - Helpers

    static func isHostPattern(_ perm: String) -> Bool {
        perm == "<all_urls>" ||
        perm.contains("://") ||
        perm.hasPrefix("*://") ||
        perm.hasPrefix("http://") ||
        perm.hasPrefix("https://") ||
        perm.hasPrefix("file://")
    }

    func usesBrowserNamespace(in dir: URL, manifest: [String: Any]) -> Bool {
        var scriptPaths: [String] = []
        if let bg = manifest["background"] as? [String: Any] {
            if let sw = bg["service_worker"] as? String { scriptPaths.append(sw) }
            if let scripts = bg["scripts"] as? [String] { scriptPaths.append(contentsOf: scripts) }
        }
        if let cs = manifest["content_scripts"] as? [[String: Any]] {
            for entry in cs {
                if let js = entry["js"] as? [String] { scriptPaths.append(contentsOf: js) }
            }
        }
        for rel in scriptPaths.prefix(1024) {
            guard let url = containedFileURL(rel, in: dir) else { continue }
            if let txt = try? String(contentsOf: url, encoding: .utf8), txt.contains("browser.") {
                return true
            }
        }
        return false
    }

    /// Resolves a manifest-relative path and returns it only if it stays inside `dir` (blocks `..` / symlink escapes).
    func containedFileURL(_ relativePath: String, in dir: URL) -> URL? {
        let clean = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = dir.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = base.appendingPathComponent(clean).standardizedFileURL.resolvingSymlinksInPath()
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return candidate.path.hasPrefix(basePath) ? candidate : nil
    }

    func extractScriptsFromHTML(relativePath: String, in dir: URL) -> [String] {
        let cleanRel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let htmlURL = containedFileURL(relativePath, in: dir) else { return [] }
        guard let html = try? String(contentsOf: htmlURL, encoding: .utf8) else { return [] }
        let baseRelDir = (cleanRel as NSString).deletingLastPathComponent
        let pattern = #"<script[^>]+src=["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        var out: [String] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges >= 2 else { continue }
            let src = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if src.hasPrefix("http://") || src.hasPrefix("https://") || src.isEmpty { continue }
            if src.hasPrefix("/") {
                out.append(String(src.dropFirst()))
            } else if !baseRelDir.isEmpty {
                out.append((baseRelDir as NSString).appendingPathComponent(src))
            } else {
                out.append(src)
            }
        }
        return out
    }

    func injectPolyfillIntoHTML(relativePath: String, polyfillFilename: String, in dir: URL) {
        guard let htmlURL = containedFileURL(relativePath, in: dir) else { return }
        guard var html = try? String(contentsOf: htmlURL, encoding: .utf8),
              !html.contains(polyfillFilename) else { return }
        let tag = "<script src=\"/\(polyfillFilename)\"></script>"
        if let range = html.range(of: "<head>", options: [.caseInsensitive]) {
            html.insert(contentsOf: "\n  \(tag)", at: range.upperBound)
        } else if let range = html.range(of: "<script", options: [.caseInsensitive]) {
            html.insert(contentsOf: "\(tag)\n", at: range.lowerBound)
        } else {
            html = "\(tag)\n" + html
        }
        try? html.write(to: htmlURL, atomically: true, encoding: .utf8)
    }

    func sanitizeMV3CSP(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "'unsafe-inline'", with: "")
            .replacingOccurrences(of: "'unsafe-eval'", with: "'wasm-unsafe-eval'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "script-src 'self'; object-src 'self'" : cleaned
    }

    /// Lightweight universal WebExtension `browser.*` -> `chrome.*` + MV2->MV3 compatibility shim.
    private static let webExtensionPolyfillJS = """
    (function() {
      if (globalThis.__sxMv3PolyfillInstalled) return;
      globalThis.__sxMv3PolyfillInstalled = true;
      if (typeof chrome === 'undefined' || !chrome) return;

      // Alias MV2 browserAction / pageAction onto MV3 chrome.action
      try {
        if (chrome.action) {
          if (!chrome.browserAction) {
            Object.defineProperty(chrome, 'browserAction', { value: chrome.action, configurable: true, writable: true });
          }
          if (!chrome.pageAction) {
            Object.defineProperty(chrome, 'pageAction', { value: chrome.action, configurable: true, writable: true });
          }
        }
      } catch (_) {}

      // Expose WebExtension `browser` namespace backed by Chromium's Promise-capable MV3 `chrome` API
      if (typeof globalThis.browser === 'undefined') {
        try {
          Object.defineProperty(globalThis, 'browser', { value: chrome, configurable: true, writable: true });
        } catch (_) {
          globalThis.browser = chrome;
        }
      }

      // Shim MV2 tabs.executeScript -> MV3 scripting.executeScript when available
      try {
        if (chrome.tabs && !chrome.tabs.executeScript && chrome.scripting && chrome.scripting.executeScript) {
          chrome.tabs.executeScript = function(tabIdOrDetails, maybeDetails, cb) {
            let tabId = typeof tabIdOrDetails === 'number' ? tabIdOrDetails : null;
            let details = typeof tabIdOrDetails === 'number' ? maybeDetails : tabIdOrDetails;
            let callback = typeof maybeDetails === 'function' ? maybeDetails : cb;
            const runWithTab = (tid) => {
              const req = { target: { tabId: tid, allFrames: !!(details && details.allFrames) } };
              if (details && details.file) req.files = [details.file];
              const p = req.files ? chrome.scripting.executeScript(req) : Promise.resolve([]);
              if (typeof callback === 'function') { p.then((r) => callback(r)); return; }
              return p;
            };
            if (tabId !== null) return runWithTab(tabId);
            const qp = chrome.tabs.query({ active: true, currentWindow: true }).then((tabs) => {
              const t = tabs && tabs[0];
              return t && typeof t.id === 'number' ? runWithTab(t.id) : [];
            });
            if (typeof callback === 'function') { qp.then((r) => callback(r)); return; }
            return qp;
          };
        }
      } catch (_) {}
    })();
    """
}
