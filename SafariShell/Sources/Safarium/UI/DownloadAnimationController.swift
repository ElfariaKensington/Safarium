import AppKit
import QuartzCore
import UniformTypeIdentifiers

/// Safari 26 download UX, measured frame-by-frame from a 120 fps reference recording
/// (Reference: Screen Recording 2026-11-26 11.52.15, 2 px per pt):
/// 1. Fly-to-Dock: published as a file `NSProgress` with `fileAnimationImage` + original rect, so the Dock
///    itself flies the gray compass from the click point into the Downloads stack (its own landing light) and shows
///    the stack's progress bar (exactly what Safari does). When the Dock cannot do it (file not on disk yet,
///    folder not in the Dock) a local fallback replays the measured curve.
/// 2. Toolbar button: arrow-only glyph inside a light-accent track ring with an accent progress arc from 12 o'clock.
/// 3. Popover: native glass `NSPopover`, 533 pt wide, 46 pt header, 52 pt rows, accent selection, knock-out circle buttons.
final class DownloadAnimationController: NSObject {
    private var downloads: [BrowserDownloadItem] = []
    private var speedByID: [UInt32: Double] = [:]
    private var lastSampleByID: [UInt32: (bytes: Int64, time: CFAbsoluteTime)] = [:]

    private var activePopover: NSPopover?
    private weak var popoverVC: SafariDownloadsPopoverViewController?
    private var flyOverlayWindows: [NSWindow] = []

    private weak var hostWindow: NSWindow?
    private weak var downloadsButton: NSButton?
    private weak var rightCapsule: GlassActionCapsule?
    private var progressTrackLayer: CAShapeLayer?
    private var progressRingLayer: CAShapeLayer?
    private var ringGlyphShown = false
    private var confirmedDownloadIDs: Set<UInt32> = []

    private struct PendingFlight {
        let originRect: NSRect
        let startedAt: CFAbsoluteTime
    }
    private var pendingFlights: [UInt32: PendingFlight] = [:]
    private var flightPollTimer: Timer?
    private let dockProgress = DockDownloadProgressPublisher()

    private var resumeWatchdogs: [UInt32: Timer] = [:]
    private var resumeBaselineBytes: [UInt32: Int64] = [:]

    var onCancelDownload: ((UInt32) -> Void)?
    var onPauseDownload: ((UInt32) -> Void)?
    var onResumeDownload: ((UInt32) -> Bool)?
    var onRetryDownload: ((URL) -> Void)?
    var onToolbarVisibilityChanged: ((Bool) -> Void)?
    var hasDownloads: Bool { !downloads.isEmpty }
    var needsTemporaryToolbarButton: Bool {
        !downloads.isEmpty || (activePopover?.isShown ?? false)
    }

    override init() {
        super.init()
        dockProgress.onCancel = { [weak self] id in self?.pauseDownload(id: id) }
    }

    deinit {
        for t in resumeWatchdogs.values { t.invalidate() }
        resumeWatchdogs.removeAll()
        flightPollTimer?.invalidate()
        dockProgress.unpublishAll()
        activePopover?.close()
    }

    func attach(window: NSWindow, downloadsButton: NSButton, capsule: GlassActionCapsule? = nil) {
        self.hostWindow = window
        self.downloadsButton = downloadsButton
        self.rightCapsule = capsule
        installRadialProgressRing(on: downloadsButton)
        capsule?.setHidden(downloads.isEmpty, for: "downloads", animated: false)
        updateProgressRing()
    }

    func updateAnchorButton(_ button: NSButton, capsule: GlassActionCapsule? = nil) {
        guard self.downloadsButton !== button else {
            if let capsule { self.rightCapsule = capsule }
            return
        }
        progressTrackLayer?.removeFromSuperlayer()
        progressRingLayer?.removeFromSuperlayer()
        self.downloadsButton = button
        if let capsule { self.rightCapsule = capsule }
        ringGlyphShown = false
        installRadialProgressRing(on: button)
        updateProgressRing()
    }

    // MARK: - Download events

    func handleDownloadStarted(_ item: BrowserDownloadItem, fromOriginInWindow origin: NSPoint? = nil) {
        // Never trigger download animations or toolbar pills when a Save dialog merely opened or was cancelled.
        let hasDestinationOrBytes = item.isComplete || item.receivedBytes > 0 || (item.fullPath?.isEmpty == false)
        guard !item.isCanceled,
              (item.isInProgress || item.isComplete || item.isPaused),
              hasDestinationOrBytes else {
            return
        }
        confirmedDownloadIDs.insert(item.id)
        let wasEmpty = downloads.isEmpty
        lastSampleByID[item.id] = (item.receivedBytes, CFAbsoluteTimeGetCurrent())
        speedByID[item.id] = 0
        upsertDownload(item)
        if wasEmpty {
            rightCapsule?.setHidden(false, for: "downloads", animated: true)
            onToolbarVisibilityChanged?(true)
        }
        updateProgressRing()
        beginFlight(for: item, fromOriginInWindow: origin)
    }

    func handleDownloadUpdated(_ item: BrowserDownloadItem) {
        // Ignore updates for downloads that never cleared Save dialog confirmation.
        let isKnown = confirmedDownloadIDs.contains(item.id) || downloads.contains(where: { $0.id == item.id })
        if !isKnown {
            let hasDestinationOrBytes = item.isComplete || item.receivedBytes > 0 || (item.fullPath?.isEmpty == false)
            guard !item.isCanceled,
                  (item.isInProgress || item.isComplete),
                  hasDestinationOrBytes else {
                return
            }
            confirmedDownloadIDs.insert(item.id)
        }

        // Check if a pending resume attempt succeeded or failed
        if let timer = resumeWatchdogs[item.id] {
            let baseline = resumeBaselineBytes[item.id] ?? 0
            if item.isComplete || (item.isInProgress && item.receivedBytes > baseline) {
                timer.invalidate()
                resumeWatchdogs.removeValue(forKey: item.id)
                resumeBaselineBytes.removeValue(forKey: item.id)
            } else if item.isCanceled {
                timer.invalidate()
                resumeWatchdogs.removeValue(forKey: item.id)
                resumeBaselineBytes.removeValue(forKey: item.id)
                upsertDownload(item)
                restartOrFailDownload(id: item.id)
                return
            }
        }

        let hadActive = downloads.contains { $0.isInProgress }
        let now = CFAbsoluteTimeGetCurrent()
        if item.isInProgress {
            if let prev = lastSampleByID[item.id] {
                let dt = now - prev.time
                if dt >= 0.35 {
                    let delta = max(0, item.receivedBytes - prev.bytes)
                    let instSpeed = Double(delta) / dt
                    let prevSpeed = speedByID[item.id] ?? instSpeed
                    speedByID[item.id] = prevSpeed > 0 ? (prevSpeed * 0.65 + instSpeed * 0.35) : instSpeed
                    lastSampleByID[item.id] = (item.receivedBytes, now)
                }
            } else {
                lastSampleByID[item.id] = (item.receivedBytes, now)
            }
        } else {
            speedByID.removeValue(forKey: item.id)
            lastSampleByID.removeValue(forKey: item.id)
        }

        upsertDownload(item)
        syncDockProgress(for: item)
        let hasActive = downloads.contains { $0.isInProgress }
        updateProgressRing()
        if hadActive && !hasActive && item.isComplete {
            bounceDownloadsButton(scalePeak: 1.14)
        }
        if item.isComplete && !item.isCanceled && BrowserSettings.shared.removeDownloadsMode == 2 {
            let removeID = item.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                self.downloads.removeAll { $0.id == removeID }
                self.popoverVC?.update(items: self.downloads, speeds: self.speedByID)
                if self.downloads.isEmpty {
                    self.closePopover()
                    self.rightCapsule?.setHidden(true, for: "downloads", animated: true)
                    self.onToolbarVisibilityChanged?(true)
                }
            }
        }
    }

    // MARK: - Popover

    func togglePopover() {
        if let activePopover, activePopover.isShown {
            closePopover()
            return
        }
        guard let btn = downloadsButton else { return }

        let vc = SafariDownloadsPopoverViewController(items: downloads, speeds: speedByID)
        vc.onClear = { [weak self] in
            guard let self else { return }
            for d in self.downloads where d.isPaused {
                self.clearResumeWatchdog(id: d.id)
                self.onCancelDownload?(d.id)
            }
            self.downloads.removeAll { !$0.isInProgress }
            self.popoverVC?.update(items: self.downloads, speeds: self.speedByID)
            self.updateProgressRing()
            if self.downloads.isEmpty {
                self.closePopover()
                self.rightCapsule?.setHidden(true, for: "downloads", animated: true)
                self.onToolbarVisibilityChanged?(true)
            }
        }
        vc.onCancel = { [weak self] id in self?.pauseDownload(id: id) }
        vc.onRetry = { [weak self] id in self?.reloadDownload(id: id) }
        vc.onRestart = { [weak self] id in self?.restartOrFailDownload(id: id) }
        vc.onRemove = { [weak self] id in
            guard let self, let item = self.downloads.first(where: { $0.id == id }), !item.isInProgress else { return }
            if item.isPaused {
                self.clearResumeWatchdog(id: id)
                self.onCancelDownload?(id)
            }
            self.downloads.removeAll { $0.id == id }
            self.popoverVC?.update(items: self.downloads, speeds: self.speedByID)
            if self.downloads.isEmpty {
                self.closePopover()
                self.rightCapsule?.setHidden(true, for: "downloads", animated: true)
                self.onToolbarVisibilityChanged?(true)
            }
        }
        self.popoverVC = vc

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = btn.window?.effectiveAppearance ?? NSApp.effectiveAppearance
        popover.contentViewController = vc
        popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: btn.isFlipped ? .maxY : .minY)
        self.activePopover = popover
    }

    func closePopover() {
        activePopover?.close()
        activePopover = nil
        popoverVC = nil
    }

    private func clearResumeWatchdog(id: UInt32) {
        resumeWatchdogs.removeValue(forKey: id)?.invalidate()
        resumeBaselineBytes.removeValue(forKey: id)
    }

    private func pauseDownload(id: UInt32) {
        clearResumeWatchdog(id: id)
        onPauseDownload?(id)
        pendingFlights.removeValue(forKey: id)
        guard let idx = downloads.firstIndex(where: { $0.id == id }) else { return }
        let cur = downloads[idx]
        guard cur.isInProgress else { return }
        downloads[idx] = BrowserDownloadItem(
            id: cur.id,
            suggestedFileName: cur.suggestedFileName,
            fullPath: cur.fullPath,
            url: cur.url,
            totalBytes: cur.totalBytes,
            receivedBytes: cur.receivedBytes,
            percentComplete: cur.percentComplete,
            isInProgress: false,
            isComplete: false,
            isCanceled: false,
            isPaused: true
        )
        speedByID.removeValue(forKey: id)
        lastSampleByID.removeValue(forKey: id)
        dockProgress.finish(id: id, finalPath: nil, success: false)
        updateProgressRing()
        popoverVC?.update(items: downloads, speeds: speedByID)
    }

    private func reloadDownload(id: UInt32) {
        guard let idx = downloads.firstIndex(where: { $0.id == id }) else { return }
        let cur = downloads[idx]
        guard !cur.isInProgress, !cur.isComplete else { return }

        // 1. If paused, try native CEF resume first
        if cur.isPaused, onResumeDownload?(id) == true {
            downloads[idx] = BrowserDownloadItem(
                id: cur.id,
                suggestedFileName: cur.suggestedFileName,
                fullPath: cur.fullPath,
                url: cur.url,
                totalBytes: cur.totalBytes,
                receivedBytes: cur.receivedBytes,
                percentComplete: cur.percentComplete,
                isInProgress: true,
                isComplete: false,
                isCanceled: false,
                isPaused: false
            )
            lastSampleByID[id] = (cur.receivedBytes, CFAbsoluteTimeGetCurrent())
            speedByID[id] = 0
            updateProgressRing()
            popoverVC?.update(items: downloads, speeds: speedByID)

            // Watchdog: if server doesn't support Range resume or download stays stuck, fall back to restart
            clearResumeWatchdog(id: id)
            resumeBaselineBytes[id] = cur.receivedBytes
            let t = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
                guard let self else { return }
                let baseline = self.resumeBaselineBytes.removeValue(forKey: id) ?? 0
                self.resumeWatchdogs.removeValue(forKey: id)
                guard let curItem = self.downloads.first(where: { $0.id == id }) else { return }
                if !curItem.isComplete && (!curItem.isInProgress || curItem.receivedBytes <= baseline) {
                    self.restartOrFailDownload(id: id)
                }
            }
            resumeWatchdogs[id] = t
            return
        }

        // 2. Otherwise fall back to restart (or mark stopped if impossible)
        restartOrFailDownload(id: id)
    }

    private func restartOrFailDownload(id: UInt32) {
        clearResumeWatchdog(id: id)
        guard let idx = downloads.firstIndex(where: { $0.id == id }) else { return }
        let cur = downloads[idx]

        if let url = cur.url, onRetryDownload != nil {
            onCancelDownload?(id)
            downloads.remove(at: idx)
            speedByID.removeValue(forKey: id)
            lastSampleByID.removeValue(forKey: id)
            dockProgress.finish(id: id, finalPath: nil, success: false)
            updateProgressRing()
            popoverVC?.update(items: downloads, speeds: speedByID)
            onRetryDownload?(url)
            return
        }

        // Cannot resume and cannot restart -> mark permanently stopped
        onCancelDownload?(id)
        downloads[idx] = BrowserDownloadItem(
            id: cur.id,
            suggestedFileName: cur.suggestedFileName,
            fullPath: cur.fullPath,
            url: cur.url,
            totalBytes: cur.totalBytes,
            receivedBytes: cur.receivedBytes,
            percentComplete: cur.percentComplete,
            isInProgress: false,
            isComplete: false,
            isCanceled: true,
            isPaused: false
        )
        speedByID.removeValue(forKey: id)
        lastSampleByID.removeValue(forKey: id)
        dockProgress.finish(id: id, finalPath: nil, success: false)
        updateProgressRing()
        popoverVC?.update(items: downloads, speeds: speedByID)
    }

    // MARK: - Fly to Dock (native Dock animation via published NSProgress, local fallback)

    private func beginFlight(for item: BrowserDownloadItem, fromOriginInWindow origin: NSPoint?) {
        guard let win = hostWindow else { return }
        // Measured: the 96 pt image's bottom-left corner sits on the click point (82 pt disc, 7 pt padding).
        let clickInWindow = origin ?? NSPoint(x: win.frame.width * 0.5, y: win.frame.height - 140.0)
        let p = win.convertPoint(toScreen: clickInWindow)
        let rect = NSRect(x: p.x, y: p.y, width: SafariDownloadFlyImage.canvas, height: SafariDownloadFlyImage.canvas)
        pendingFlights[item.id] = PendingFlight(originRect: rect, startedAt: CFAbsoluteTimeGetCurrent())
        resolvePendingFlights()
        if !pendingFlights.isEmpty && flightPollTimer == nil {
            let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in self?.resolvePendingFlights() }
            RunLoop.main.add(t, forMode: .common)
            flightPollTimer = t
        }
    }

    /// The Dock only animates a published progress whose file already exists inside its Downloads stack folder.
    private func resolvePendingFlights() {
        let now = CFAbsoluteTimeGetCurrent()
        for (id, flight) in pendingFlights {
            guard let item = downloads.first(where: { $0.id == id }) else {
                pendingFlights.removeValue(forKey: id)
                continue
            }
            if let fileURL = Self.onDiskProgressURL(for: item, since: flight.startedAt),
               Self.dockStackContains(folder: fileURL.deletingLastPathComponent()) {
                dockProgress.publish(id: id, fileURL: fileURL, item: item,
                                     animationImage: SafariDownloadFlyImage.image, originRect: flight.originRect)
                pendingFlights.removeValue(forKey: id)
                if !item.isInProgress { syncDockProgress(for: item) }
            } else if now - flight.startedAt > 0.9 || !item.isInProgress {
                pendingFlights.removeValue(forKey: id)
                animateFallbackFlight(fromScreenRect: flight.originRect)
                syncDockProgress(for: item)
            }
        }
        if pendingFlights.isEmpty {
            flightPollTimer?.invalidate()
            flightPollTimer = nil
        }
    }

    private func syncDockProgress(for item: BrowserDownloadItem) {
        if pendingFlights[item.id] != nil { return }
        if !dockProgress.isPublished(item.id), item.isInProgress,
           let fileURL = Self.onDiskProgressURL(for: item, since: 0) {
            dockProgress.publish(id: item.id, fileURL: fileURL, item: item, animationImage: nil, originRect: nil)
        }
        if item.isInProgress {
            let speed = speedByID[item.id] ?? 0
            dockProgress.update(id: item.id, item: item, bytesPerSecond: speed)
        } else {
            // Let a just-started native flight finish before the progress goes away.
            dockProgress.finish(id: item.id, finalPath: item.fullPath, success: item.isComplete && !item.isCanceled)
        }
    }

    static func onDiskProgressURL(for item: BrowserDownloadItem, since start: CFAbsoluteTime) -> URL? {
        guard let path = item.fullPath, !path.isEmpty else { return nil }
        let fm = FileManager.default
        for candidate in [path + ".crdownload", path + ".download", path] where fm.fileExists(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        // Chromium may stage unvalidated files as "Unconfirmed NNNN.crdownload" next to the target.
        let dir = (path as NSString).deletingLastPathComponent
        let startDate = Date(timeIntervalSinceReferenceDate: start - 2.0)
        if let names = try? fm.contentsOfDirectory(atPath: dir) {
            let staged = names
                .filter { $0.hasPrefix("Unconfirmed ") && $0.hasSuffix(".crdownload") }
                .map { (dir as NSString).appendingPathComponent($0) }
                .compactMap { p -> (String, Date)? in
                    guard let d = (try? fm.attributesOfItem(atPath: p))?[.creationDate] as? Date, d >= startDate else { return nil }
                    return (p, d)
                }
                .max { $0.1 < $1.1 }
            if let staged { return URL(fileURLWithPath: staged.0) }
        }
        return nil
    }

    static func dockStackContains(folder: URL) -> Bool {
        let target = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let others = (UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-others") as? [[String: Any]]) ?? []
        if others.isEmpty {
            // Unreadable Dock prefs: macOS ships with the Downloads stack, so trust it for ~/Downloads.
            let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            return dl.map { $0.standardizedFileURL.resolvingSymlinksInPath().path == target } ?? false
        }
        for entry in others {
            guard let td = entry["tile-data"] as? [String: Any],
                  let fd = td["file-data"] as? [String: Any],
                  let s = fd["_CFURLString"] as? String,
                  let u = URL(string: s) else { continue }
            if u.standardizedFileURL.resolvingSymlinksInPath().path == target { return true }
        }
        return false
    }

    /// Dock Downloads tile centre (AppKit screen coordinates) and tile size.
    func dockDownloadsTarget(on screen: NSScreen) -> (point: NSPoint, tile: CGFloat) {
        let full = screen.frame
        let visible = screen.visibleFrame
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        let rawTileSize = dockDefaults?.double(forKey: "tilesize") ?? 48.0
        let tileSize = max(32.0, min(96.0, rawTileSize > 0 ? rawTileSize : 48.0))

        if AXIsProcessTrusted(),
           let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            let axApp = AXUIElementCreateApplication(dockApp.processIdentifier)
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    var listRef: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &listRef) == .success,
                          let items = listRef as? [AXUIElement] else { continue }
                    for item in items {
                        var urlRef: CFTypeRef?
                        _ = AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &urlRef)
                        let urlStr = (urlRef as? URL)?.path.lowercased() ?? ""
                        var titleRef: CFTypeRef?
                        _ = AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleRef)
                        let title = (titleRef as? String)?.lowercased() ?? ""
                        guard title == "downloads" || title == "indirilenler" || urlStr.hasSuffix("/downloads") else { continue }
                        var posRef: CFTypeRef?
                        var sizeRef: CFTypeRef?
                        if AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &posRef) == .success,
                           AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeRef) == .success,
                           let posVal = posRef, let sizeVal = sizeRef {
                            var cgPos = CGPoint.zero
                            var cgSize = CGSize.zero
                            AXValueGetValue(posVal as! AXValue, .cgPoint, &cgPos)
                            AXValueGetValue(sizeVal as! AXValue, .cgSize, &cgSize)
                            let primaryH = NSScreen.screens.first?.frame.height ?? full.height
                            let cocoaY = primaryH - (cgPos.y + cgSize.height * 0.5)
                            return (NSPoint(x: cgPos.x + cgSize.width * 0.5, y: cocoaY), min(cgSize.width, cgSize.height))
                        }
                    }
                }
            }
        }

        let orientation = (dockDefaults?.string(forKey: "orientation") ?? "bottom").lowercased()
        let persistentApps = (dockDefaults?.array(forKey: "persistent-apps") as? [[String: Any]]) ?? []
        let recentApps = (dockDefaults?.array(forKey: "recent-apps") as? [[String: Any]]) ?? []
        let persistentOthers = (dockDefaults?.array(forKey: "persistent-others") as? [[String: Any]]) ?? []
        let showRecents = (dockDefaults?.object(forKey: "show-recents") as? Bool) ?? true

        var downloadsIdx = max(0, persistentOthers.count - 1)
        for (idx, dict) in persistentOthers.enumerated() {
            if let td = dict["tile-data"] as? [String: Any] {
                let label = (td["file-label"] as? String)?.lowercased() ?? ""
                let cfurl = ((td["file-data"] as? [String: Any])?["_CFURLString"] as? String)?.lowercased() ?? ""
                if label == "downloads" || label == "indirilenler" || cfurl.contains("/downloads") {
                    downloadsIdx = idx
                    break
                }
            }
        }

        let appCount = persistentApps.count + 1
        let recentCount = showRecents ? recentApps.count : 0
        let otherCount = max(1, persistentOthers.count) + 1
        let totalIcons = appCount + recentCount + otherCount
        let dividerExtra: CGFloat = recentCount > 0 ? 36.0 : 18.0
        let slotsFromEnd = CGFloat(otherCount - downloadsIdx) - 0.5

        switch orientation {
        case "left", "right":
            let dockW = orientation == "left" ? max(56.0, visible.minX - full.minX) : max(56.0, full.maxX - visible.maxX)
            let pitch = min(tileSize + 8.0, (full.height - 80.0 - dividerExtra) / CGFloat(max(1, totalIcons)))
            let totalH = CGFloat(totalIcons) * pitch + dividerExtra
            let bottomOfDock = full.midY - totalH * 0.5
            let x = orientation == "left" ? full.minX + dockW * 0.5 : full.maxX - dockW * 0.5
            return (NSPoint(x: x, y: bottomOfDock + slotsFromEnd * pitch), tileSize)
        default:
            let dockH = max(56.0, visible.minY - full.minY)
            let pitch = min(tileSize + 10.0, (full.width - 80.0 - dividerExtra) / CGFloat(max(1, totalIcons)))
            let totalW = CGFloat(totalIcons) * pitch + dividerExtra
            let rightEdgeOfDock = full.midX + totalW * 0.5
            return (NSPoint(x: rightEdgeOfDock - slotsFromEnd * pitch, y: full.minY + dockH * 0.5), tileSize)
        }
    }

    /// Local replay of the Dock's flight, fitted to the reference: cubic Bézier with control points straight above
    /// the start (0.315 × distance) and the tile (0.93 × distance), timing cubic-bezier(0.425, 0.025, 0.575, 0.925),
    /// 1.08 s, full size until 36 %, shrinking to 46 % by 80 %, sliding under the Dock (the Dock draws its own landing light).
    private func animateFallbackFlight(fromScreenRect originRect: NSRect) {
        guard !MotionPreference.reduced else { return }  // Reduce Motion: skip the fly-to-Dock arc
        guard let screen = hostWindow?.screen ?? NSScreen.main else { return }
        let target = dockDownloadsTarget(on: screen)
        let frame = screen.frame
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))

        let overlay = Self.makeOverlayWindow(screen: screen, level: NSWindow.Level(rawValue: dockLevel - 1))
        guard let root = overlay.contentView?.layer else { return }

        let s = CGPoint(x: originRect.midX - frame.minX, y: originRect.midY - frame.minY)
        let e = CGPoint(x: target.point.x - frame.minX, y: target.point.y - frame.minY)
        let dist = hypot(e.x - s.x, e.y - s.y)
        var rise1 = dist * 0.315
        var rise2 = dist * 0.93
        func bezier(_ u: CGFloat, _ r1: CGFloat, _ r2: CGFloat) -> CGPoint {
            let c1 = CGPoint(x: s.x + (e.x - s.x) * 0.008, y: s.y + r1)
            let c2 = CGPoint(x: e.x - (e.x - s.x) * 0.016, y: e.y + r2)
            let a = (1 - u) * (1 - u) * (1 - u), b = 3 * u * (1 - u) * (1 - u), c = 3 * u * u * (1 - u), d = u * u * u
            return CGPoint(x: a * s.x + b * c1.x + c * c2.x + d * e.x, y: a * s.y + b * c1.y + c * c2.y + d * e.y)
        }
        // Keep the arc's apex on screen.
        for _ in 0..<24 {
            let apex = stride(from: 0.0, through: 1.0, by: 0.05).map { bezier(CGFloat($0), rise1, rise2).y }.max() ?? 0
            if apex <= frame.height - 48.0 { break }
            rise1 *= 0.9
            rise2 *= 0.9
        }

        let icon = CALayer()
        icon.bounds = CGRect(x: 0, y: 0, width: SafariDownloadFlyImage.canvas, height: SafariDownloadFlyImage.canvas)
        icon.contents = SafariDownloadFlyImage.image
        icon.contentsGravity = .resizeAspect
        icon.contentsScale = screen.backingScaleFactor
        icon.position = e
        icon.transform = CATransform3DMakeScale(0.46, 0.46, 1)
        root.addSublayer(icon)

        let steps = 72
        var positions: [NSValue] = []
        var scales: [NSNumber] = []
        var times: [NSNumber] = []
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let u = CGFloat(Self.cubicBezierEase(t, 0.425, 0.025, 0.575, 0.925))
            positions.append(NSValue(point: bezier(u, rise1, rise2)))
            let scale: Double
            if t <= 0.36 {
                scale = 1.0
            } else if t >= 0.80 {
                scale = 0.46
            } else {
                let k = (t - 0.36) / 0.44
                scale = 1.0 - 0.54 * (k * k * (3 - 2 * k))
            }
            scales.append(NSNumber(value: scale))
            times.append(NSNumber(value: t))
        }
        let pos = CAKeyframeAnimation(keyPath: "position")
        pos.values = positions
        pos.keyTimes = times
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = scales
        scale.keyTimes = times
        let group = CAAnimationGroup()
        group.animations = [pos, scale]
        group.duration = 1.08
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        overlay.orderFrontRegardless()
        flyOverlayWindows.append(overlay)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            overlay.orderOut(nil)
            self.flyOverlayWindows.removeAll { $0 === overlay }
        }
        icon.add(group, forKey: "safariDownloadFly")
        CATransaction.commit()
    }

    private static func makeOverlayWindow(screen: NSScreen, level: NSWindow.Level) -> NSWindow {
        let overlay = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        overlay.level = level
        overlay.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        overlay.setFrame(screen.frame, display: false)
        let rootView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        rootView.wantsLayer = true
        overlay.contentView = rootView
        return overlay
    }

    static func cubicBezierEase(_ t: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        func bx(_ s: Double) -> Double { 3 * s * (1 - s) * (1 - s) * x1 + 3 * s * s * (1 - s) * x2 + s * s * s }
        func by(_ s: Double) -> Double { 3 * s * (1 - s) * (1 - s) * y1 + 3 * s * s * (1 - s) * y2 + s * s * s }
        var lo = 0.0, hi = 1.0, s = t
        for _ in 0..<48 {
            let x = bx(s)
            if abs(x - t) < 1e-7 { break }
            if x < t { lo = s } else { hi = s }
            s = (lo + hi) * 0.5
        }
        return by(s)
    }

    private func bounceDownloadsButton(scalePeak: CGFloat) {
        guard !MotionPreference.reduced else { return }
        guard let btn = downloadsButton, let layer = btn.layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: btn.frame.midX, y: btn.frame.midY)

        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [1.0, scalePeak, 0.94, 1.03, 1.0]
        bounce.keyTimes = [0.0, 0.30, 0.62, 0.84, 1.0]
        bounce.duration = 0.36
        bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(bounce, forKey: "downloadBounce")
    }

    // MARK: - Toolbar button progress ring

    /// Measured: 16 pt ring (1.5 pt stroke) exactly where the symbol's circle was; track = accent at ~32 %,
    /// progress = accent with round caps from 12 o'clock clockwise; the arrow keeps the toolbar ink colour.
    private static let arrowOnlyGlyph: NSImage = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 16.0, weight: .regular)
            .applying(.init(paletteColors: [.black, .clear]))
        guard let sym = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Downloads")?
            .withSymbolConfiguration(cfg) else {
            return AssetLoader.shared.symbol(named: "arrow.down", pointSize: 9.0, weight: .regular)
        }
        let img = NSImage(size: sym.size, flipped: false) { rect in
            sym.draw(in: rect)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Downloads"
        return img
    }()

    private func installRadialProgressRing(on button: NSButton) {
        button.wantsLayer = true
        guard let layer = button.layer else { return }

        let track = CAShapeLayer()
        track.fillColor = NSColor.clear.cgColor
        track.lineWidth = 1.5
        track.opacity = 0.0
        layer.addSublayer(track)
        self.progressTrackLayer = track

        let ring = CAShapeLayer()
        ring.fillColor = NSColor.clear.cgColor
        ring.lineWidth = 1.5
        ring.lineCap = .round
        ring.strokeStart = 0.0
        ring.strokeEnd = 0.0
        ring.opacity = 0.0
        layer.addSublayer(ring)
        self.progressRingLayer = ring
    }

    private func updateProgressRing() {
        guard let button = downloadsButton,
              let track = progressTrackLayer,
              let ring = progressRingLayer else { return }

        let b = button.bounds
        let center = CGPoint(x: b.midX > 1 ? b.midX : 18.0, y: b.midY > 1 ? b.midY : 16.0)
        let radius: CGFloat = 7.1
        let path = CGMutablePath()
        // Layer geometry follows the view's flippedness; start at 12 o'clock and run clockwise on screen.
        let flipped = button.layer?.isGeometryFlipped ?? button.isFlipped
        if flipped {
            path.addArc(center: center, radius: radius, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: false)
        } else {
            path.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: -1.5 * .pi, clockwise: true)
        }

        let accent = NSColor.controlAccentColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = b
        ring.frame = b
        track.path = path
        ring.path = path
        track.strokeColor = accent.withAlphaComponent(0.32).cgColor
        ring.strokeColor = accent.cgColor
        CATransaction.commit()

        let active = downloads.filter { $0.isInProgress }
        let isDownloading = !active.isEmpty
        if isDownloading != ringGlyphShown {
            ringGlyphShown = isDownloading
            button.image = isDownloading
                ? Self.arrowOnlyGlyph
                : AssetLoader.shared.symbol(named: "arrow.down.circle", pointSize: 16.0, weight: .regular)
        }

        if !isDownloading {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            ring.opacity = 0.0
            track.opacity = 0.0
            ring.strokeEnd = 0.0
            CATransaction.commit()
        } else {
            let avgProgress = active.reduce(0.0) { acc, item -> Double in
                if item.totalBytes > 0 {
                    return acc + Double(item.receivedBytes) / Double(item.totalBytes)
                }
                return acc + Double(max(0, item.percentComplete)) / 100.0
            } / Double(active.count)

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.14)
            track.opacity = 1.0
            ring.opacity = 1.0
            ring.strokeEnd = CGFloat(max(0.001, min(1.0, avgProgress)))
            CATransaction.commit()
        }
    }

    private func upsertDownload(_ item: BrowserDownloadItem) {
        if let idx = downloads.firstIndex(where: { $0.id == item.id }) {
            let prev = downloads[idx]
            let keptName = !item.suggestedFileName.isEmpty ? item.suggestedFileName : prev.suggestedFileName
            let keptPath = (item.fullPath?.isEmpty == false) ? item.fullPath : prev.fullPath
            let keptURL = item.url ?? prev.url
            let keptTotal = item.totalBytes > 0 ? item.totalBytes : prev.totalBytes
            let keptRecv = (item.receivedBytes > 0 || item.isInProgress) ? item.receivedBytes : prev.receivedBytes
            let keptPct = item.percentComplete >= 0 ? item.percentComplete : prev.percentComplete
            downloads[idx] = BrowserDownloadItem(
                id: item.id,
                suggestedFileName: keptName,
                fullPath: keptPath,
                url: keptURL,
                totalBytes: keptTotal,
                receivedBytes: keptRecv,
                percentComplete: keptPct,
                isInProgress: item.isInProgress,
                isComplete: item.isComplete,
                isCanceled: item.isCanceled,
                isPaused: item.isPaused
            )
        } else {
            downloads.insert(item, at: 0)
        }
        popoverVC?.update(items: downloads, speeds: speedByID)
    }
}

// MARK: - Published file progress (Dock fly-in, Downloads stack progress bar, Finder progress)

private final class DockDownloadProgressPublisher {
    private var progresses: [UInt32: Progress] = [:]
    var onCancel: ((UInt32) -> Void)?

    func isPublished(_ id: UInt32) -> Bool { progresses[id] != nil }

    func publish(id: UInt32, fileURL: URL, item: BrowserDownloadItem, animationImage: NSImage?, originRect: NSRect?) {
        guard progresses[id] == nil else { return }
        let p = Progress(parent: nil, userInfo: [
            .fileOperationKindKey: Progress.FileOperationKind.downloading,
            .fileURLKey: fileURL
        ])
        p.kind = .file
        p.isCancellable = true
        p.isPausable = false
        p.totalUnitCount = item.totalBytes > 0 ? item.totalBytes : -1
        p.completedUnitCount = max(0, item.receivedBytes)
        if let animationImage, let originRect {
            p.setUserInfoObject(animationImage, forKey: .fileAnimationImageKey)
            p.setUserInfoObject(NSValue(rect: originRect), forKey: .fileAnimationImageOriginalRectKey)
        }
        p.cancellationHandler = { [weak self] in
            DispatchQueue.main.async { self?.onCancel?(id) }
        }
        p.publish()
        progresses[id] = p
    }

    func update(id: UInt32, item: BrowserDownloadItem, bytesPerSecond: Double) {
        guard let p = progresses[id] else { return }
        if item.totalBytes > 0 { p.totalUnitCount = item.totalBytes }
        p.completedUnitCount = max(0, item.receivedBytes)
        if bytesPerSecond >= 1 {
            p.throughput = Int(bytesPerSecond)
            if item.totalBytes > item.receivedBytes {
                p.estimatedTimeRemaining = Double(item.totalBytes - item.receivedBytes) / bytesPerSecond
            }
        }
    }

    func finish(id: UInt32, finalPath: String?, success: Bool) {
        guard let p = progresses.removeValue(forKey: id) else {
            if success { Self.postFinished(finalPath) }
            return
        }
        p.cancellationHandler = nil
        if success, p.totalUnitCount > 0 { p.completedUnitCount = p.totalUnitCount }
        // Keep it published long enough for a native flight that started moments ago to land (1.08 s).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            p.unpublish()
            if success { Self.postFinished(finalPath) }
        }
    }

    func unpublishAll() {
        for p in progresses.values { p.cancellationHandler = nil; p.unpublish() }
        progresses.removeAll()
    }

    /// Same notification Safari posts: bounces the Downloads stack in the Dock.
    private static func postFinished(_ path: String?) {
        guard let path, FileManager.default.fileExists(atPath: path) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.DownloadFileFinished"), object: path, userInfo: nil, deliverImmediately: true)
    }
}

// MARK: - Flying compass image (vector redraw of the reference frame)

private enum SafariDownloadFlyImage {
    static let canvas: CGFloat = 96.0

    /// Vector (drawing-handler) image: verified with a live Dock capture that it flies at the full 96 pt canvas;
    /// a pre-rendered 2x bitmap rep flew at half size.
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx)
            return true
        }
        img.accessibilityDescription = "Download"
        return img
    }()

    /// Measured on the 120 fps frame: 82 pt white disc with a soft shadow, 73.5 pt #9C9C9C dial,
    /// 48 ticks (7.5° pitch, r 27.25–33 pt, white 78 %), 61 pt NE–SW needle, NE half filled, SW half outlined.
    private static func draw(in ctx: CGContext) {
        let c = CGPoint(x: canvas / 2, y: canvas / 2)
        func circle(_ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2) }

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 6, color: NSColor.black.withAlphaComponent(0.30).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: circle(41.0))
        ctx.restoreGState()

        ctx.setFillColor(NSColor(white: 156.0 / 255.0, alpha: 1).cgColor)
        ctx.fillEllipse(in: circle(36.75))

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.78).cgColor)
        ctx.setLineWidth(1.3)
        ctx.setLineCap(.butt)
        for k in 0..<48 {
            let a = CGFloat(k) * (.pi / 24.0)
            ctx.move(to: CGPoint(x: c.x + cos(a) * 27.25, y: c.y + sin(a) * 27.25))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * 33.0, y: c.y + sin(a) * 33.0))
        }
        ctx.strokePath()

        let axis = CGPoint(x: cos(CGFloat.pi / 4), y: sin(CGFloat.pi / 4))
        let perp = CGPoint(x: -axis.y, y: axis.x)
        let tip: CGFloat = 30.5
        let half: CGFloat = 4.9
        let ne = CGPoint(x: c.x + axis.x * tip, y: c.y + axis.y * tip)
        let sw = CGPoint(x: c.x - axis.x * tip, y: c.y - axis.y * tip)
        let sa = CGPoint(x: c.x + perp.x * half, y: c.y + perp.y * half)
        let sb = CGPoint(x: c.x - perp.x * half, y: c.y - perp.y * half)

        ctx.setFillColor(NSColor.white.cgColor)
        ctx.beginPath()
        ctx.move(to: sa); ctx.addLine(to: ne); ctx.addLine(to: sb); ctx.closePath()
        ctx.fillPath()

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.0)
        ctx.setLineJoin(.miter)
        ctx.beginPath()
        ctx.move(to: sa); ctx.addLine(to: sw); ctx.addLine(to: sb); ctx.closePath()
        ctx.strokePath()
    }
}

// MARK: - Downloads popover (measured layout, pt)

private enum DLMetrics {
    static let minWidth: CGFloat = 280
    static let maxWidth: CGFloat = 440
    static let header: CGFloat = 46
    static let row: CGFloat = 52
    static let bottom: CGFloat = 12
    static let maxVisibleRows = 8
    static let titleBaseline: CGFloat = 24.5
    static let clearWidth: CGFloat = 56
    static let clearRightInset: CGFloat = 8.5
    static let selectionInsetX: CGFloat = 10
    static let selectionRadius: CGFloat = 7
    static let iconRect = NSRect(x: 20, y: 10, width: 32, height: 32)
    static let textX: CGFloat = 60.5
    static let separatorX: CGFloat = 60.5
    static let separatorRightInset: CGFloat = 17
    static let primaryButtonRightInset: CGFloat = 68.5
    static let revealButtonRightInset: CGFloat = 45.5
    static let buttonCenterY: CGFloat = 26
    static let buttonPointSize: CGFloat = 14.5
    static let textToButtonGap: CGFloat = 16.25
    static let barHeight: CGFloat = 6
    // Baselines (row-relative)
    static let progressNameBaseline: CGFloat = 17
    static let progressBarCenter: CGFloat = 27.75
    static let progressStatusBaseline: CGFloat = 44
    static let nameBaseline: CGFloat = 24.25
    static let statusBaseline: CGFloat = 39.5
    static let nameFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let statusFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .regular)
}

private func drawString(_ s: String, font: NSFont, color: NSColor, baseline: CGFloat, x: CGFloat, width: CGFloat,
                        alignment: NSTextAlignment = .left, truncation: NSLineBreakMode = .byTruncatingTail) {
    let para = NSMutableParagraphStyle()
    para.alignment = alignment
    para.lineBreakMode = truncation
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
    let lineH = ceil(font.ascender - font.descender + font.leading)
    // Flipped view: the line box top sits `ascender` above the baseline.
    let rect = NSRect(x: x, y: baseline - font.ascender, width: max(0, width), height: lineH)
    (s as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
}

private final class SafariDownloadsPopoverViewController: NSViewController {
    var onClear: (() -> Void)?
    var onCancel: ((UInt32) -> Void)?
    var onRetry: ((UInt32) -> Void)?
    var onRestart: ((UInt32) -> Void)?
    var onRemove: ((UInt32) -> Void)?

    private var items: [BrowserDownloadItem]
    private var speeds: [UInt32: Double]
    private var selectedID: UInt32?

    private let header = DownloadsHeaderView()
    private let scrollView = NSScrollView()
    private let listView = DownloadsListView()
    private var rowViewsByID: [UInt32: SafariDownloadRowView] = [:]

    init(items: [BrowserDownloadItem], speeds: [UInt32: Double]) {
        self.items = items
        self.speeds = speeds
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var preferredWidth: CGFloat {
        guard !items.isEmpty else { return DLMetrics.minWidth }
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: DLMetrics.nameFont]
        var maxTextW: CGFloat = 0
        for item in items {
            let name = item.suggestedFileName.isEmpty ? "Download" : item.suggestedFileName
            let w = ceil((name as NSString).size(withAttributes: nameAttrs).width)
            if w > maxTextW { maxTextW = w }
        }
        let needed = DLMetrics.textX + maxTextW + DLMetrics.textToButtonGap + DLMetrics.primaryButtonRightInset + DLMetrics.buttonPointSize * 0.5 + 8
        return max(DLMetrics.minWidth, min(DLMetrics.maxWidth, ceil(needed)))
    }

    private var preferredHeight: CGFloat {
        let rows = max(1, min(items.count, DLMetrics.maxVisibleRows))
        return DLMetrics.header + CGFloat(rows) * DLMetrics.row + DLMetrics.bottom
    }

    override func loadView() {
        let root = DownloadsRootView(frame: NSRect(x: 0, y: 0, width: preferredWidth, height: preferredHeight))
        // ⌘⌫ removes the selected (finished or stopped) download from the list, like Safari.
        root.onCommandDelete = { [weak self] in
            guard let self, let id = self.selectedID,
                  let item = self.items.first(where: { $0.id == id }), !item.isInProgress else { NSSound.beep(); return }
            self.onRemove?(id)
        }
        header.onClear = { [weak self] in self?.onClear?() }
        root.addSubview(header)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = listView
        root.addSubview(scrollView)

        listView.onBackgroundClick = { [weak self] in self?.select(nil) }

        view = root
        preferredContentSize = NSSize(width: preferredWidth, height: preferredHeight)
        syncRows()
    }

    func update(items: [BrowserDownloadItem], speeds: [UInt32: Double]) {
        self.items = items
        self.speeds = speeds
        if isViewLoaded { syncRows() }
    }

    private func select(_ id: UInt32?) {
        selectedID = id
        for (rid, row) in rowViewsByID { row.isSelected = (rid == id) }
        listView.selectedIndex = id.flatMap { sid in items.firstIndex { $0.id == sid } }
    }

    private func syncRows() {
        header.clearEnabled = items.contains { !$0.isInProgress }
        listView.isEmptyState = items.isEmpty

        let ids = Set(items.map(\.id))
        for (id, row) in rowViewsByID where !ids.contains(id) {
            row.removeFromSuperview()
            rowViewsByID.removeValue(forKey: id)
        }
        if let sel = selectedID, !ids.contains(sel) { selectedID = nil }

        for item in items {
            let row: SafariDownloadRowView
            if let existing = rowViewsByID[item.id] {
                row = existing
            } else {
                row = SafariDownloadRowView(item: item)
                let id = item.id
                row.onSelect = { [weak self] in
                    guard let self else { return }
                    self.select(id)
                    self.view.window?.makeFirstResponder(self.view)
                }
                row.onCancel = { [weak self] in self?.onCancel?(id) }
                row.onRetry = { [weak self] in self?.onRetry?(id) }
                row.onRestart = { [weak self] in self?.onRestart?(id) }
                row.onRemove = { [weak self] in self?.onRemove?(id) }
                listView.addSubview(row)
                rowViewsByID[item.id] = row
            }
            row.apply(item: item, bytesPerSecond: speeds[item.id] ?? 0)
        }
        layoutEverything()
        select(selectedID)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutSubviewsToBounds()
    }

    private func layoutEverything() {
        let w = preferredWidth
        let h = preferredHeight
        if abs(preferredContentSize.width - w) > 0.5 || abs(preferredContentSize.height - h) > 0.5 {
            // NSPopover owns the content view's frame (its origin sits above the arrow inset);
            // never assign view.frame here or the content slides down under the bottom edge.
            preferredContentSize = NSSize(width: w, height: h)
        }
        layoutSubviewsToBounds()
    }

    private func layoutSubviewsToBounds() {
        let w = view.bounds.width > 1 ? view.bounds.width : preferredWidth
        let h = view.bounds.height > 1 ? view.bounds.height : preferredHeight
        header.frame = NSRect(x: 0, y: 0, width: w, height: DLMetrics.header)

        let listH = max(0, h - DLMetrics.header - DLMetrics.bottom)
        scrollView.frame = NSRect(x: 0, y: DLMetrics.header, width: w, height: listH)
        var y: CGFloat = 0
        for item in items {
            rowViewsByID[item.id]?.frame = NSRect(x: 0, y: y, width: w, height: DLMetrics.row)
            y += DLMetrics.row
        }
        listView.rowCount = items.count
        listView.frame = NSRect(x: 0, y: 0, width: w, height: max(listH, y))
        listView.needsDisplay = true
    }
}

private class FlippedDownloadsView: NSView {
    override var isFlipped: Bool { true }
}

private final class DownloadsRootView: FlippedDownloadsView {
    var onCommandDelete: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if dark {
            NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 0.46).setFill()
            dirtyRect.fill()
        }
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 51, mods.contains(.command) {   // ⌘⌫
            onCommandDelete?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 51, mods.contains(.command), window?.firstResponder === self {
            onCommandDelete?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class DownloadsHeaderView: FlippedDownloadsView {
    var onClear: (() -> Void)?
    var clearEnabled = false {
        didSet { if oldValue != clearEnabled { needsDisplay = true } }
    }
    private var pressed = false
    private var clearRect: NSRect {
        NSRect(x: bounds.width - DLMetrics.clearWidth - DLMetrics.clearRightInset, y: 7.75, width: DLMetrics.clearWidth, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let titleColor: NSColor = dark ? NSColor.white.withAlphaComponent(0.96) : .labelColor
        let sidePad = DLMetrics.clearWidth + DLMetrics.clearRightInset + 8
        drawString("Downloads", font: DLMetrics.titleFont, color: titleColor, baseline: DLMetrics.titleBaseline,
                   x: sidePad, width: max(60, bounds.width - sidePad * 2), alignment: .center)

        let pill = NSBezierPath(roundedRect: clearRect, xRadius: 6, yRadius: 6)
        let base: CGFloat = pressed && clearEnabled ? 0.22 : 0.14
        (dark ? NSColor.white.withAlphaComponent(base + 0.04) : NSColor.black.withAlphaComponent(base)).setFill()
        pill.fill()
        let clearColor: NSColor = clearEnabled
            ? (dark ? NSColor.white.withAlphaComponent(0.96) : .labelColor)
            : (dark ? NSColor.white.withAlphaComponent(0.50) : .tertiaryLabelColor)
        drawString("Clear", font: DLMetrics.titleFont, color: clearColor,
                   baseline: DLMetrics.titleBaseline, x: clearRect.minX, width: clearRect.width, alignment: .center)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard clearEnabled, clearRect.contains(p) else { return }
        pressed = true
        needsDisplay = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let q = convert(next.locationInWindow, from: nil)
            let inside = clearRect.contains(q)
            if inside != pressed { pressed = inside; needsDisplay = true }
            if next.type == .leftMouseUp {
                pressed = false
                needsDisplay = true
                if inside { onClear?() }
                break
            }
        }
    }
}

private final class DownloadsListView: FlippedDownloadsView {
    var rowCount = 0
    var selectedIndex: Int? { didSet { needsDisplay = true } }
    var isEmptyState = false { didSet { needsDisplay = true } }
    var onBackgroundClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isEmptyState {
            let emptyColor: NSColor = dark ? NSColor.white.withAlphaComponent(0.76) : .secondaryLabelColor
            drawString("No Recent Downloads", font: DLMetrics.nameFont, color: emptyColor,
                       baseline: DLMetrics.row * 0.5 + 4, x: 0, width: bounds.width, alignment: .center)
            return
        }
        guard rowCount > 1 else { return }
        (dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.labelColor.withAlphaComponent(0.09)).setFill()
        for boundary in 1..<rowCount {
            if let sel = selectedIndex, sel == boundary - 1 || sel == boundary { continue }
            let y = CGFloat(boundary) * DLMetrics.row
            let sepRight = max(DLMetrics.separatorX, bounds.width - DLMetrics.separatorRightInset)
            NSRect(x: DLMetrics.separatorX, y: y + 0.1,
                   width: sepRight - DLMetrics.separatorX, height: 1).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }
}

private final class SafariDownloadRowView: FlippedDownloadsView {
    private var item: BrowserDownloadItem
    private var bytesPerSecond: Double = 0
    private var icon: NSImage
    private var hoverStatus: String?

    var onSelect: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onRestart: (() -> Void)?
    var onRemove: (() -> Void)?
    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            for b in [primaryButton, revealButton] { b.isRowSelected = isSelected }
            needsDisplay = true
        }
    }

    private let primaryButton = DownloadCircleButton()
    private let revealButton = DownloadCircleButton()

    private static let etaFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.allowedUnits = [.hour, .minute, .second]
        f.maximumUnitCount = 3
        f.zeroFormattingBehavior = .dropAll
        return f
    }()

    private static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: max(0, n))
    }

    init(item: BrowserDownloadItem) {
        self.item = item
        let ext = (item.suggestedFileName as NSString).pathExtension
        self.icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext.isEmpty ? "data" : ext) ?? .data)
        super.init(frame: .zero)

        revealButton.symbolName = "magnifyingglass.circle.fill"
        revealButton.hoverText = "Show in Finder"
        revealButton.onClick = { [weak self] _ in self?.reveal() }
        for b in [primaryButton, revealButton] {
            b.onHoverChanged = { [weak self] text in
                self?.hoverStatus = text
                self?.needsDisplay = true
            }
            addSubview(b)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(item: BrowserDownloadItem, bytesPerSecond: Double) {
        self.item = item
        self.bytesPerSecond = bytesPerSecond
        if item.isInProgress {
            primaryButton.isHidden = false
            primaryButton.symbolName = "xmark.circle.fill"
            primaryButton.style = .neutral
            primaryButton.hoverText = "Stop downloading"
            primaryButton.optionHoverText = nil
            primaryButton.onClick = { [weak self] _ in self?.onCancel?() }
        } else if item.isPaused {
            primaryButton.isHidden = false
            primaryButton.symbolName = "arrow.clockwise.circle.fill"
            primaryButton.style = .resume
            primaryButton.hoverText = "Resume"
            primaryButton.optionHoverText = item.url != nil ? "Restart" : nil
            primaryButton.onClick = { [weak self] optionHeld in
                if optionHeld { self?.onRestart?() } else { self?.onRetry?() }
            }
        } else if item.isCanceled {
            primaryButton.isHidden = item.url == nil
            primaryButton.symbolName = "arrow.clockwise.circle.fill"
            primaryButton.style = .resume
            primaryButton.hoverText = "Reload"
            primaryButton.optionHoverText = item.url != nil ? "Restart" : nil
            primaryButton.onClick = { [weak self] optionHeld in
                if optionHeld { self?.onRestart?() } else { self?.onRetry?() }
            }
        } else {
            primaryButton.isHidden = true
            primaryButton.optionHoverText = nil
        }
        if primaryButton.isHidden, primaryButton.isHovered {
            primaryButton.isHovered = false
            hoverStatus = nil
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let d: CGFloat = 20
        let primaryX = bounds.width - DLMetrics.primaryButtonRightInset
        let revealX = bounds.width - DLMetrics.revealButtonRightInset
        primaryButton.frame = NSRect(x: primaryX - d / 2, y: DLMetrics.buttonCenterY - d / 2, width: d, height: d)
        revealButton.frame = NSRect(x: revealX - d / 2, y: DLMetrics.buttonCenterY - d / 2, width: d, height: d)
    }

    private var statusText: String {
        if let hoverStatus { return hoverStatus }
        let recv = Self.bytes(item.receivedBytes)
        let tot = item.totalBytes > 0 ? Self.bytes(item.totalBytes) : nil
        if item.isPaused {
            return tot.map { "\(recv) of \($0) — paused" } ?? "\(recv) — paused"
        }
        if item.isCanceled {
            return tot.map { "\(recv) of \($0) — stopped" } ?? "\(recv) — stopped"
        }
        if item.isComplete {
            return Self.bytes(max(item.totalBytes, item.receivedBytes))
        }
        var s = tot.map { "\(recv) of \($0)" } ?? recv
        if bytesPerSecond >= 1 {
            s += " (\(Self.bytes(Int64(bytesPerSecond)))/sec)"
            if item.totalBytes > item.receivedBytes,
               let eta = Self.etaFormatter.string(from: max(1, (Double(item.totalBytes - item.receivedBytes) / bytesPerSecond).rounded())) {
                s += " — \(eta) remaining"
            }
        }
        return s
    }

    override func draw(_ dirtyRect: NSRect) {
        let selected = isSelected
        if selected {
            let r = NSRect(x: DLMetrics.selectionInsetX, y: 0, width: bounds.width - DLMetrics.selectionInsetX * 2, height: bounds.height)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: r, xRadius: DLMetrics.selectionRadius, yRadius: DLMetrics.selectionRadius).fill()
        }

        icon.draw(in: DLMetrics.iconRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)

        let primaryX = bounds.width - DLMetrics.primaryButtonRightInset
        let revealX = bounds.width - DLMetrics.revealButtonRightInset
        let rightLimit = (primaryButton.isHidden ? revealX : primaryX)
            - DLMetrics.buttonPointSize / 2 - DLMetrics.textToButtonGap
        let textW = max(40, rightLimit - DLMetrics.textX)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let nameColor: NSColor = selected ? .white : (dark ? NSColor.white.withAlphaComponent(0.96) : .labelColor)
        let statusColor: NSColor = selected ? NSColor.white.withAlphaComponent(0.92) : (dark ? NSColor.white.withAlphaComponent(0.78) : .secondaryLabelColor)
        let name = item.suggestedFileName.isEmpty ? "Download" : item.suggestedFileName

        if item.isInProgress {
            drawString(name, font: DLMetrics.nameFont, color: nameColor, baseline: DLMetrics.progressNameBaseline,
                       x: DLMetrics.textX, width: textW, truncation: .byTruncatingMiddle)
            let barW = max(40, (primaryX - DLMetrics.buttonPointSize / 2 - 9) - DLMetrics.textX)
            let bar = NSRect(x: DLMetrics.textX, y: DLMetrics.progressBarCenter - DLMetrics.barHeight / 2,
                             width: barW, height: DLMetrics.barHeight)
            (selected ? NSColor.black.withAlphaComponent(0.09)
                : (dark ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.085))).setFill()
            let track = NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2)
            track.fill()
            // Measured: 6 pt track with a faint darker rim, 5 pt fill inset by 0.5 pt.
            let rim = NSBezierPath(roundedRect: bar.insetBy(dx: 0.25, dy: 0.25), xRadius: bar.height / 2 - 0.25, yRadius: bar.height / 2 - 0.25)
            rim.lineWidth = 0.5
            (selected ? NSColor.black.withAlphaComponent(0.05)
                : (dark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.05))).setStroke()
            rim.stroke()
            let frac: CGFloat = item.totalBytes > 0
                ? CGFloat(min(1.0, Double(item.receivedBytes) / Double(item.totalBytes)))
                : CGFloat(max(0, min(100, item.percentComplete))) / 100.0
            let inner = bar.insetBy(dx: 0.5, dy: 0.5)
            let fillW = max(inner.height, inner.width * frac)
            (selected ? NSColor.white : NSColor.controlAccentColor).setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: fillW, height: inner.height),
                         xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
            drawString(statusText, font: DLMetrics.statusFont, color: statusColor, baseline: DLMetrics.progressStatusBaseline,
                       x: DLMetrics.textX, width: textW)
        } else {
            drawString(name, font: DLMetrics.nameFont, color: nameColor, baseline: DLMetrics.nameBaseline,
                       x: DLMetrics.textX, width: textW, truncation: .byTruncatingMiddle)
            drawString(statusText, font: DLMetrics.statusFont, color: statusColor, baseline: DLMetrics.statusBaseline,
                       x: DLMetrics.textX, width: textW)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
        if event.clickCount == 2 { openFile() }
    }

    // MARK: Context menu (reference: right-click selects the row, then Show in Finder / Stop / Copy Address)

    override func menu(for event: NSEvent) -> NSMenu? {
        onSelect?()
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            mi.isEnabled = enabled
            menu.addItem(mi)
        }
        if item.isComplete {
            add("Open", #selector(menuOpen), enabled: fileExists)
        }
        add("Show in Finder", #selector(menuReveal))
        if item.isInProgress {
            add("Stop", #selector(menuStop))
        } else if item.isPaused {
            add("Resume", #selector(menuResume))
        } else if item.isCanceled, item.url != nil {
            add("Reload", #selector(menuResume))
        }
        if item.url != nil {
            add("Restart", #selector(menuRestart))
        }
        add("Copy Address", #selector(menuCopyAddress), enabled: item.url != nil)
        if !item.isInProgress {
            menu.addItem(.separator())
            let remove = NSMenuItem(title: "Remove From List", action: #selector(menuRemove), keyEquivalent: "\u{8}")
            remove.keyEquivalentModifierMask = [.command]
            remove.target = self
            menu.addItem(remove)
        }
        return menu
    }

    private var fileExists: Bool {
        guard let path = item.fullPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func openFile() {
        guard item.isComplete, fileExists, let path = item.fullPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func menuOpen() { openFile() }
    @objc private func menuReveal() { reveal() }
    @objc private func menuStop() { onCancel?() }
    @objc private func menuResume() { onRetry?() }
    @objc private func menuRestart() { onRestart?() }
    @objc private func menuRemove() { onRemove?() }
    @objc private func menuCopyAddress() {
        guard let url = item.url else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        pb.setString(url.absoluteString, forType: .string)
    }

    private func reveal() {
        guard let path = item.fullPath else { return }
        let fm = FileManager.default
        for candidate in [path, path + ".crdownload", path + ".download"] where fm.fileExists(atPath: candidate) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate)])
            return
        }
        let parent = (path as NSString).deletingLastPathComponent
        if fm.fileExists(atPath: parent) {
            NSWorkspace.shared.open(URL(fileURLWithPath: parent))
        }
    }
}

/// Filled circle with the SF Symbol glyph knocked out (the glass shows through), as in the reference.
private final class DownloadCircleButton: NSView {
    enum Style { case neutral, resume }

    var symbolName = "xmark.circle.fill" { didSet { if oldValue != symbolName { glyph = nil; needsDisplay = true } } }
    var style: Style = .neutral { didSet { needsDisplay = true } }
    var isRowSelected = false { didSet { needsDisplay = true } }
    var hoverText: String?
    var optionHoverText: String?
    var onClick: ((_ optionHeld: Bool) -> Void)?
    var onHoverChanged: ((String?) -> Void)?
    var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    private var pressed = false
    private var glyph: NSImage?
    private var tracking: NSTrackingArea?
    private var flagsMonitor: Any?

    deinit {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
    }

    private func currentHoverText() -> String? {
        if let opt = optionHoverText, NSEvent.modifierFlags.contains(.option) {
            return opt
        }
        return hoverText
    }

    override var isFlipped: Bool { true }

    private func glyphImage() -> NSImage? {
        if let glyph { return glyph }
        let cfg = NSImage.SymbolConfiguration(pointSize: DLMetrics.buttonPointSize, weight: .regular)
            .applying(.init(paletteColors: [.black, .clear]))
        glyph = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        return glyph
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let glyph = glyphImage() else { return }
        let d = DLMetrics.buttonPointSize
        let disc = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        let color: NSColor
        if isRowSelected {
            color = NSColor.white.withAlphaComponent(pressed ? 0.7 : 1.0)
        } else if style == .resume {
            color = pressed ? NSColor.systemOrange.blended(withFraction: 0.25, of: .black) ?? .systemOrange : .systemOrange
        } else {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if dark {
                color = NSColor.white.withAlphaComponent(pressed ? 0.90 : (isHovered ? 0.80 : 0.58))
            } else {
                color = NSColor.labelColor.withAlphaComponent(pressed ? 0.75 : (isHovered ? 0.62 : 0.36))
            }
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        color.setFill()
        NSBezierPath(ovalIn: disc).fill()
        let gs = glyph.size
        let gRect = NSRect(x: bounds.midX - gs.width / 2, y: bounds.midY - gs.height / 2, width: gs.width, height: gs.height)
        glyph.draw(in: gRect, from: .zero, operation: .destinationOut, fraction: 1.0, respectFlipped: true, hints: nil)
        ctx.endTransparencyLayer()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHoverChanged?(currentHoverText())
        if optionHoverText != nil, flagsMonitor == nil {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] ev in
                guard let self, self.isHovered else { return ev }
                self.onHoverChanged?(ev.modifierFlags.contains(.option) ? (self.optionHoverText ?? self.hoverText) : self.hoverText)
                return ev
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        onHoverChanged?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if inside != pressed { pressed = inside; needsDisplay = true }
            if next.type == .leftMouseUp {
                pressed = false
                needsDisplay = true
                if inside {
                    let optionHeld = next.modifierFlags.contains(.option) || event.modifierFlags.contains(.option)
                    onClick?(optionHeld)
                }
                break
            }
        }
    }
}
