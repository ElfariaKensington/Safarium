import AppKit
import ImageIO

/// Immutable snapshot payload passed to `SwipeNavigationController` with viewport metadata
/// so resized windows anchor cleanly over the page's background color instead of stretching text.
struct NavigationSnapshotPayload {
    let image: NSImage
    let logicalSize: CGSize
    let backgroundColor: NSColor
    /// True for full-bleed native pages (`Start Page`, `History`, `Inspect`) spanning behind the 52pt toolbar;
    /// false for web page snapshots captured inside `webContentHost` below the toolbar.
    let isFullBleedBehindToolbar: Bool

    init(image: NSImage, logicalSize: CGSize, backgroundColor: NSColor, isFullBleedBehindToolbar: Bool = false) {
        self.image = image
        self.logicalSize = logicalSize
        self.backgroundColor = backgroundColor
        self.isFullBleedBehindToolbar = isFullBleedBehindToolbar
    }
}

/// Entry-ID keyed, two-tier (warm compressed JPEG + hot decoded NSImage) navigation snapshot store
/// modeled on WebKit's `ViewSnapshotStore` and Chromium's `NavigationEntryScreenshotCache`.
/// - Strictly keyed by `(tabID, CefNavigationEntry::GetIdentifier())` so redirects, SPA `pushState`,
///   and multi-step history jumps never desync snapshots.
/// - Enforces a global 64 MB LRU cap across all tabs and responds automatically to macOS memory pressure.
final class NavigationSnapshotStore {
    static let shared = NavigationSnapshotStore()

    static let startPageEntryID: Int = -1
    static let historyPageEntryID: Int = -2
    static let inspectPageEntryID: Int = -3

    private struct Key: Hashable {
        let tabID: String
        let entryID: Int
    }

    private struct WarmEntry {
        let jpegData: Data
        let logicalSize: CGSize
        let backingScale: CGFloat
        let backgroundColor: NSColor
        let isFullBleedBehindToolbar: Bool
        var lastAccess: CFTimeInterval
    }

    private struct HotEntry {
        let payload: NavigationSnapshotPayload
        var lastAccess: CFTimeInterval
    }

    private static let maxWarmBytes: Int = 64 * 1024 * 1024
    private static let maxHotEntries: Int = 6

    private let lock = NSLock()
    private var warmEntries: [Key: WarmEntry] = [:]
    private var hotEntries: [Key: HotEntry] = [:]
    private var totalWarmBytes: Int = 0
    private let decodeQueue = DispatchQueue(label: "com.safarium.nav-snapshot.decode", qos: .userInitiated)
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            self.handleMemoryPressure(critical: event.contains(.critical))
        }
        source.resume()
        self.memoryPressureSource = source
    }

    // MARK: - Storage

    func storeJPEG(
        _ data: Data,
        tabID: String,
        entryID: Int,
        logicalSize: CGSize,
        backingScale: CGFloat,
        backgroundColor: NSColor?,
        isFullBleedBehindToolbar: Bool = true
    ) {
        guard !data.isEmpty, entryID != 0, logicalSize.width >= 32, logicalSize.height >= 32 else { return }
        let key = Key(tabID: tabID, entryID: entryID)
        let now = CACurrentMediaTime()
        let bg = backgroundColor ?? .windowBackgroundColor

        lock.lock()
        if let prev = warmEntries[key] {
            totalWarmBytes = max(0, totalWarmBytes - prev.jpegData.count)
        }
        warmEntries[key] = WarmEntry(
            jpegData: data,
            logicalSize: logicalSize,
            backingScale: max(1.0, backingScale),
            backgroundColor: bg,
            isFullBleedBehindToolbar: isFullBleedBehindToolbar,
            lastAccess: now
        )
        totalWarmBytes += data.count
        hotEntries.removeValue(forKey: key)
        evictWarmIfNeededLocked(limitBytes: Self.maxWarmBytes)
        lock.unlock()
    }

    func storeImage(
        _ image: NSImage,
        tabID: String,
        entryID: Int,
        logicalSize: CGSize,
        backgroundColor: NSColor?,
        isFullBleedBehindToolbar: Bool? = nil
    ) {
        guard entryID != 0, logicalSize.width >= 32, logicalSize.height >= 32 else { return }
        let key = Key(tabID: tabID, entryID: entryID)
        let now = CACurrentMediaTime()
        // Native pages and web pages both run behind the toolbar now.
        let fullBleed = isFullBleedBehindToolbar ?? true
        let payload = NavigationSnapshotPayload(
            image: image,
            logicalSize: logicalSize,
            backgroundColor: backgroundColor ?? .windowBackgroundColor,
            isFullBleedBehindToolbar: fullBleed
        )

        lock.lock()
        hotEntries[key] = HotEntry(payload: payload, lastAccess: now)
        evictHotIfNeededLocked()
        lock.unlock()
    }

    // MARK: - Prewarming & Retrieval

    /// Asynchronously decodes the active tab's immediate `prev`/`next` entries into the hot tier
    /// so starting a trackpad swipe has 0ms decode latency.
    func prewarm(tabID: String, entryIDs: [Int]) {
        let candidates = entryIDs.filter { $0 > 0 }
        guard !candidates.isEmpty else { return }

        var toDecode: [(Key, WarmEntry)] = []
        lock.lock()
        for eid in candidates {
            let key = Key(tabID: tabID, entryID: eid)
            if hotEntries[key] == nil, let warm = warmEntries[key] {
                toDecode.append((key, warm))
            }
        }
        lock.unlock()

        guard !toDecode.isEmpty else { return }
        for (key, warm) in toDecode {
            decodeQueue.async { [weak self] in
                guard let self,
                      let img = Self.decodeImage(from: warm.jpegData, logicalSize: warm.logicalSize) else {
                    return
                }
                let payload = NavigationSnapshotPayload(
                    image: img,
                    logicalSize: warm.logicalSize,
                    backgroundColor: warm.backgroundColor,
                    isFullBleedBehindToolbar: warm.isFullBleedBehindToolbar
                )
                self.lock.lock()
                // Only cache if warm entry still exists and matches this data length.
                if let currentWarm = self.warmEntries[key], currentWarm.jpegData.count == warm.jpegData.count {
                    self.hotEntries[key] = HotEntry(payload: payload, lastAccess: CACurrentMediaTime())
                    self.evictHotIfNeededLocked()
                }
                self.lock.unlock()
            }
        }
    }

    func snapshot(tabID: String, entryID: Int) -> NavigationSnapshotPayload? {
        guard entryID != 0 else { return nil }
        let key = Key(tabID: tabID, entryID: entryID)
        let now = CACurrentMediaTime()

        lock.lock()
        if var hot = hotEntries[key] {
            hot.lastAccess = now
            hotEntries[key] = hot
            lock.unlock()
            return hot.payload
        }
        guard var warm = warmEntries[key] else {
            lock.unlock()
            return nil
        }
        warm.lastAccess = now
        warmEntries[key] = warm
        lock.unlock()

        guard let img = Self.decodeImage(from: warm.jpegData, logicalSize: warm.logicalSize) else {
            return nil
        }
        let payload = NavigationSnapshotPayload(
            image: img,
            logicalSize: warm.logicalSize,
            backgroundColor: warm.backgroundColor,
            isFullBleedBehindToolbar: warm.isFullBleedBehindToolbar
        )
        lock.lock()
        hotEntries[key] = HotEntry(payload: payload, lastAccess: now)
        evictHotIfNeededLocked()
        lock.unlock()
        return payload
    }

    // MARK: - Pruning & Cleanup

    /// Removes orphaned history entries (e.g., truncated forward stack) for `tabID`.
    /// Negative sentinel IDs (native Start Page / History / Inspect) are preserved.
    func prune(tabID: String, keepingEntryIDs validIDs: Set<Int>) {
        lock.lock()
        let warmKeys = warmEntries.keys.filter { $0.tabID == tabID && $0.entryID > 0 && !validIDs.contains($0.entryID) }
        for k in warmKeys {
            if let removed = warmEntries.removeValue(forKey: k) {
                totalWarmBytes = max(0, totalWarmBytes - removed.jpegData.count)
            }
        }
        let hotKeys = hotEntries.keys.filter { $0.tabID == tabID && $0.entryID > 0 && !validIDs.contains($0.entryID) }
        for k in hotKeys {
            hotEntries.removeValue(forKey: k)
        }
        lock.unlock()
    }

    func removeTab(_ tabID: String) {
        lock.lock()
        for k in warmEntries.keys where k.tabID == tabID {
            if let removed = warmEntries.removeValue(forKey: k) {
                totalWarmBytes = max(0, totalWarmBytes - removed.jpegData.count)
            }
        }
        for k in hotEntries.keys where k.tabID == tabID {
            hotEntries.removeValue(forKey: k)
        }
        lock.unlock()
    }

    // MARK: - Internal Helpers

    private func handleMemoryPressure(critical: Bool) {
        lock.lock()
        hotEntries.removeAll(keepingCapacity: false)
        if critical {
            evictWarmIfNeededLocked(limitBytes: Self.maxWarmBytes / 4)
        }
        lock.unlock()
    }

    private func evictWarmIfNeededLocked(limitBytes: Int) {
        guard totalWarmBytes > limitBytes else { return }
        let sorted = warmEntries.sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (key, entry) in sorted {
            guard totalWarmBytes > limitBytes else { break }
            warmEntries.removeValue(forKey: key)
            hotEntries.removeValue(forKey: key)
            totalWarmBytes = max(0, totalWarmBytes - entry.jpegData.count)
        }
    }

    private func evictHotIfNeededLocked() {
        guard hotEntries.count > Self.maxHotEntries else { return }
        let sorted = hotEntries.sorted { $0.value.lastAccess < $1.value.lastAccess }
        let removeCount = hotEntries.count - Self.maxHotEntries
        for (key, _) in sorted.prefix(removeCount) {
            hotEntries.removeValue(forKey: key)
        }
    }

    private static func decodeImage(from data: Data, logicalSize: CGSize) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: logicalSize)
    }
}
