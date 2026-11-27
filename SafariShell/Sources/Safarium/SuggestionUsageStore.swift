import Foundation

/// Adaptive, on-device usage learner for address bar suggestions.
/// Tracks which URLs and searches the user actually chooses for typed prefixes and queries,
/// applies exponential time decay + competitive demotion so changing habits rapidly shift rankings,
/// and persists compactly under `~/Library/Application Support/Safarium/suggestion-usage.json`.
final class SuggestionUsageStore {
    static let shared = SuggestionUsageStore()

    struct UsageEntry: Codable {
        var score: Double
        var count: Int
        var lastSelected: TimeInterval
        var displayURL: String
        var title: String
    }

    private struct StoreData: Codable {
        var version: Int = 1
        /// Typed prefix (lowercased, trimmed) -> [normalizedURLKey: UsageEntry]
        var prefixURLStats: [String: [String: UsageEntry]] = [:]
        /// Global omnibox selections per normalizedURLKey
        var urlStats: [String: UsageEntry] = [:]
        /// Global omnibox selections per display domain
        var domainStats: [String: UsageEntry] = [:]
        /// Typed prefix -> [searchQueryLower: UsageEntry]
        var prefixSearchStats: [String: [String: UsageEntry]] = [:]
    }

    struct LearnedBoost {
        let totalScore: Double
        let hasStrongPrefixMatch: Bool
    }

    struct LearnedURLCandidate {
        let url: URL
        let urlKey: String
        let title: String
        let count: Int
        let lastSelected: Date
    }

    /// 14-day half-life so recent usage changes naturally overtake older habits.
    private static let halfLifeSeconds: TimeInterval = 14.0 * 86_400.0
    private static let competitiveDecayFactor: Double = 0.84
    private static let maxPrefixBuckets = 400
    private static let maxEntriesPerPrefix = 8
    private static let maxGlobalURLs = 500
    private static let maxGlobalDomains = 250
    private static let maxSearchPrefixBuckets = 200

    private let lock = NSLock()
    private var data = StoreData()
    private let fileURL: URL
    private let saveQueue = DispatchQueue(label: "com.safarium.suggestion-usage.save", qos: .utility)
    private var pendingSaveWorkItem: DispatchWorkItem?

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("Safarium", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("suggestion-usage.json")
        loadFromDisk()
    }

    // MARK: - Recording

    func recordURLSelection(query: String, url: URL, title: String, isPrivate: Bool) {
        guard !isPrivate else { return }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let urlKey = Self.normalizeURLKey(url)
        guard !urlKey.isEmpty else { return }

        let domain = URLInputNormalizer.displayDomain(for: url).lowercased()
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanQuery = Self.normalizeQuery(query)
        let now = Date().timeIntervalSince1970

        lock.lock()
        defer { lock.unlock() }

        // 1. Update global URL & domain stats
        bumpEntry(in: &data.urlStats, key: urlKey, weight: 1.0, displayURL: url.absoluteString, title: cleanTitle, now: now)
        if !domain.isEmpty {
            bumpEntry(in: &data.domainStats, key: domain, weight: 1.0, displayURL: domain, title: "", now: now)
        }

        // 2. Update prefix -> URL stats (exact typed query + shorter prefixes so typing "g" or "gi" learns too)
        if !cleanQuery.isEmpty {
            let maxPrefixLen = min(cleanQuery.count, 24)
            let truncated = String(cleanQuery.prefix(maxPrefixLen))

            // Record exact typed query with full weight (1.0) and shorter prefixes with proportional weight
            for len in 1...truncated.count {
                let prefix = String(truncated.prefix(len))
                let isExact = (len == truncated.count)
                let weight: Double = isExact ? 1.0 : (len >= 2 ? 0.65 : 0.45)

                var bucket = data.prefixURLStats[prefix] ?? [:]
                // Competitively decay other URLs under this prefix so shifting habits overtake old favorites quickly
                let decayFactor = isExact ? Self.competitiveDecayFactor : 0.92
                for (otherKey, var otherEntry) in bucket where otherKey != urlKey {
                    let current = Self.decayedValue(otherEntry.score, lastSelected: otherEntry.lastSelected, now: now)
                    otherEntry.score = current * decayFactor
                    otherEntry.lastSelected = now
                    bucket[otherKey] = otherEntry
                }
                bumpEntry(in: &bucket, key: urlKey, weight: weight, displayURL: url.absoluteString, title: cleanTitle, now: now)
                Self.trimBucket(&bucket, maxCount: Self.maxEntriesPerPrefix, now: now)
                data.prefixURLStats[prefix] = bucket
            }

            // Gently demote competing search entries for this exact prefix since the user chose a URL
            if var searchBucket = data.prefixSearchStats[truncated] {
                for (k, var entry) in searchBucket {
                    entry.score = Self.decayedValue(entry.score, lastSelected: entry.lastSelected, now: now) * 0.85
                    entry.lastSelected = now
                    searchBucket[k] = entry
                }
                data.prefixSearchStats[truncated] = searchBucket
            }
        }

        pruneIfNeeded(now: now)
        scheduleSave()
    }

    func recordSearchSelection(query: String, searchQuery: String, isPrivate: Bool) {
        guard !isPrivate else { return }
        let cleanQuery = Self.normalizeQuery(query)
        let cleanSearch = Self.normalizeQuery(searchQuery)
        guard !cleanQuery.isEmpty, !cleanSearch.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        let prefix = String(cleanQuery.prefix(24))

        lock.lock()
        defer { lock.unlock() }

        var bucket = data.prefixSearchStats[prefix] ?? [:]
        bumpEntry(in: &bucket, key: cleanSearch, weight: 1.0, displayURL: cleanSearch, title: cleanSearch, now: now)
        Self.trimBucket(&bucket, maxCount: 6, now: now)
        data.prefixSearchStats[prefix] = bucket

        // Slightly soften URL scores for this exact prefix when the user explicitly chose a web search
        if var urlBucket = data.prefixURLStats[prefix] {
            for (k, var entry) in urlBucket {
                entry.score = Self.decayedValue(entry.score, lastSelected: entry.lastSelected, now: now) * 0.90
                entry.lastSelected = now
                urlBucket[k] = entry
            }
            data.prefixURLStats[prefix] = urlBucket
        }

        pruneIfNeeded(now: now)
        scheduleSave()
    }

    func clearAll() {
        lock.lock()
        data = StoreData()
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        lock.unlock()
        saveQueue.async { [fileURL] in
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Scoring & Retrieval

    func learnedBoost(
        forQuery rawQuery: String,
        urlKey: String,
        domain: String,
        now: Date = Date()
    ) -> LearnedBoost {
        let q = Self.normalizeQuery(rawQuery)
        let domKey = domain.lowercased()
        let nowTs = now.timeIntervalSince1970

        lock.lock()
        defer { lock.unlock() }

        var boost: Double = 0.0
        var strongPrefix = false

        if !q.isEmpty {
            let prefixKey = String(q.prefix(24))

            // 1. Exact prefix match: strongest signal of what the user picks when typing this exact string
            if let bucket = data.prefixURLStats[prefixKey], let entry = bucket[urlKey] {
                let decayed = Self.decayedValue(entry.score, lastSelected: entry.lastSelected, now: nowTs)
                if decayed > 0.05 {
                    let prefixBoost = min(1_550.0, 420.0 + log2(decayed + 1.0) * 520.0)
                    boost += prefixBoost
                    if decayed >= 0.75 {
                        strongPrefix = true
                    }
                }
            } else {
                // 2. Check if user previously typed a longer query starting with `prefixKey` and picked this URL
                var bestExtended: Double = 0.0
                for (storedPrefix, bucket) in data.prefixURLStats {
                    if storedPrefix.count > prefixKey.count,
                       storedPrefix.hasPrefix(prefixKey),
                       let entry = bucket[urlKey] {
                        let decayed = Self.decayedValue(entry.score, lastSelected: entry.lastSelected, now: nowTs)
                        if decayed > bestExtended {
                            bestExtended = decayed
                        }
                    }
                }
                if bestExtended > 0.15 {
                    boost += min(680.0, 180.0 + log2(bestExtended + 1.0) * 240.0)
                }
            }
        }

        // 3. Global omnibox selection frequency for this exact URL
        if let entry = data.urlStats[urlKey] {
            let decayed = Self.decayedValue(entry.score, lastSelected: entry.lastSelected, now: nowTs)
            if decayed > 0.05 {
                boost += min(520.0, 110.0 + log2(decayed + 1.0) * 165.0)
            }
        }

        // 4. Global omnibox selection frequency for this domain
        if !domKey.isEmpty, let entry = data.domainStats[domKey] {
            let decayed = Self.decayedValue(entry.score, lastSelected: entry.lastSelected, now: nowTs)
            if decayed > 0.05 {
                boost += min(240.0, log2(decayed + 1.0) * 80.0)
            }
        }

        return LearnedBoost(totalScore: boost, hasStrongPrefixMatch: strongPrefix)
    }

    /// Returns previously chosen URLs for this prefix so learned destinations can still surface
    /// even if they aged out of the recent browsing-history window.
    func learnedURLCandidates(forQuery rawQuery: String, now: Date = Date()) -> [LearnedURLCandidate] {
        let q = Self.normalizeQuery(rawQuery)
        guard !q.isEmpty else { return [] }
        let prefixKey = String(q.prefix(24))
        let nowTs = now.timeIntervalSince1970

        lock.lock()
        defer { lock.unlock() }

        var scored: [(Double, LearnedURLCandidate)] = []
        if let bucket = data.prefixURLStats[prefixKey] {
            for (urlKey, entry) in bucket {
                let decayed = Self.decayedValue(entry.score, lastSelected: entry.lastSelected, now: nowTs)
                guard decayed >= 0.20, let url = URL(string: entry.displayURL) else { continue }
                let cand = LearnedURLCandidate(
                    url: url,
                    urlKey: urlKey,
                    title: entry.title,
                    count: entry.count,
                    lastSelected: Date(timeIntervalSince1970: entry.lastSelected)
                )
                scored.append((decayed, cand))
            }
        }
        scored.sort { $0.0 > $1.0 }
        return scored.prefix(6).map(\.1)
    }

    /// Returns previously chosen search queries matching the typed prefix (ordered by decayed preference).
    func learnedSearchSuggestions(forQuery rawQuery: String, now: Date = Date()) -> [String] {
        let q = Self.normalizeQuery(rawQuery)
        guard !q.isEmpty else { return [] }
        let prefixKey = String(q.prefix(24))
        let nowTs = now.timeIntervalSince1970

        lock.lock()
        defer { lock.unlock() }

        var bestByQuery: [String: Double] = [:]
        for (storedPrefix, bucket) in data.prefixSearchStats where storedPrefix == prefixKey || storedPrefix.hasPrefix(prefixKey) {
            let weight: Double = (storedPrefix == prefixKey) ? 1.0 : 0.6
            for (searchQ, entry) in bucket where searchQ != q && searchQ.hasPrefix(q) {
                let val = Self.decayedValue(entry.score, lastSelected: entry.lastSelected, now: nowTs) * weight
                if val >= 0.35 {
                    bestByQuery[searchQ] = max(bestByQuery[searchQ] ?? 0, val)
                }
            }
        }
        return bestByQuery.sorted { $0.value > $1.value }.prefix(3).map(\.key)
    }

    // MARK: - Helpers

    static func normalizeURLKey(_ url: URL) -> String {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = comps.host?.lowercased(), !host.isEmpty else {
            return url.absoluteString.lowercased()
        }
        let cleanHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var path = comps.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        let query = comps.query.map { "?\($0)" } ?? ""
        return "\(cleanHost)\(path == "/" ? "" : path)\(query)"
    }

    private static func normalizeQuery(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func decayedValue(_ score: Double, lastSelected: TimeInterval, now: TimeInterval) -> Double {
        let age = max(0, now - lastSelected)
        return score * pow(0.5, age / halfLifeSeconds)
    }

    private func bumpEntry(
        in dict: inout [String: UsageEntry],
        key: String,
        weight: Double,
        displayURL: String,
        title: String,
        now: TimeInterval
    ) {
        if var existing = dict[key] {
            let decayed = Self.decayedValue(existing.score, lastSelected: existing.lastSelected, now: now)
            existing.score = decayed + weight
            existing.count += 1
            existing.lastSelected = now
            if !displayURL.isEmpty { existing.displayURL = displayURL }
            if !title.isEmpty { existing.title = title }
            dict[key] = existing
        } else {
            dict[key] = UsageEntry(
                score: weight,
                count: 1,
                lastSelected: now,
                displayURL: displayURL,
                title: title
            )
        }
    }

    private static func trimBucket(_ bucket: inout [String: UsageEntry], maxCount: Int, now: TimeInterval) {
        guard bucket.count > maxCount else { return }
        let sorted = bucket.sorted {
            decayedValue($0.value.score, lastSelected: $0.value.lastSelected, now: now)
                > decayedValue($1.value.score, lastSelected: $1.value.lastSelected, now: now)
        }
        var next: [String: UsageEntry] = [:]
        for (k, v) in sorted.prefix(maxCount) {
            next[k] = v
        }
        bucket = next
    }

    private func pruneIfNeeded(now: TimeInterval) {
        if data.urlStats.count > Self.maxGlobalURLs {
            Self.trimBucket(&data.urlStats, maxCount: Self.maxGlobalURLs, now: now)
        }
        if data.domainStats.count > Self.maxGlobalDomains {
            Self.trimBucket(&data.domainStats, maxCount: Self.maxGlobalDomains, now: now)
        }
        if data.prefixURLStats.count > Self.maxPrefixBuckets {
            let ranked = data.prefixURLStats.map { (prefix, bucket) -> (String, Double) in
                let best = bucket.values.map { Self.decayedValue($0.score, lastSelected: $0.lastSelected, now: now) }.max() ?? 0
                return (prefix, best)
            }.sorted { $0.1 > $1.1 }
            let keep = Set(ranked.prefix(Self.maxPrefixBuckets).map(\.0))
            data.prefixURLStats = data.prefixURLStats.filter { keep.contains($0.key) }
        }
        if data.prefixSearchStats.count > Self.maxSearchPrefixBuckets {
            let ranked = data.prefixSearchStats.map { (prefix, bucket) -> (String, Double) in
                let best = bucket.values.map { Self.decayedValue($0.score, lastSelected: $0.lastSelected, now: now) }.max() ?? 0
                return (prefix, best)
            }.sorted { $0.1 > $1.1 }
            let keep = Set(ranked.prefix(Self.maxSearchPrefixBuckets).map(\.0))
            data.prefixSearchStats = data.prefixSearchStats.filter { keep.contains($0.key) }
        }
    }

    private func loadFromDisk() {
        guard let raw = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(StoreData.self, from: raw) else {
            return
        }
        lock.lock()
        data = decoded
        lock.unlock()
    }

    private func scheduleSave() {
        pendingSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let snapshot = self.data
            self.lock.unlock()
            if let encoded = try? JSONEncoder().encode(snapshot) {
                try? encoded.write(to: self.fileURL, options: .atomic)
            }
        }
        pendingSaveWorkItem = work
        saveQueue.asyncAfter(deadline: .now() + 0.45, execute: work)
    }
}
