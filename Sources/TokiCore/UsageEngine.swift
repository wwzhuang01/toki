import Foundation

public actor UsageEngine {
    private struct AntigravityEntry: Codable {
        let version: String
        let data: Antigravity.Conversation?
    }

    private struct Cache: Codable {
        var transcripts: [String: TranscriptEntry] = [:]
        var antigravity: [String: AntigravityEntry] = [:]
        var openCode: [String: [String: OpenCode.Table]] = [:]
    }

    private struct Scan {
        var files: [UsageFile] = []
        var status: [SourceStatus] = []
    }

    private let home: URL
    private let environment: [String: String]
    private let cacheDirectory: URL
    private var cache: Cache
    private var rateTable: Pricing.RateTable?
    private var nextRateAttempt = Date.distantPast
    private var dirty = false
    private let transcriptSlack: Int64 = 36 * 60 * 60 * 1_000

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cacheDirectory: URL? = nil
    ) {
        self.home = home
        self.environment = environment
        let directory = cacheDirectory ?? home.appending(path: "Library/Caches/io.github.wwzhuang01.toki")
        self.cacheDirectory = directory
        cache = (try? Data(contentsOf: directory.appending(path: "scan-v1.json")))
            .flatMap { try? JSONDecoder().decode(Cache.self, from: $0) } ?? Cache()
    }

    public func watchPaths(providers: Set<Provider>) -> [String] {
        let sources = LocalSources(home: home, environment: environment)
        return providers.flatMap(sources.roots) + [
            sources.tokiConfigFile.path,
            sources.t3.appending(path: "settings.json").path,
            sources.t3.appending(path: "providers/antigravity").path
        ]
    }

    public func refresh(days: [Int], providers: Set<Provider> = Set(Provider.allCases),
                        now: Date = Date(), calendar: Calendar = .current, fetchRates: Bool = true) async -> [UsageSummary] {
        let days = days.filter { [1, 7, 30].contains($0) }
        guard let longest = days.max() else { return [] }
        let sources = LocalSources(home: home, environment: environment)
        let broadWindow = UsageWindow(days: longest, now: now, calendar: calendar)
        let retention = UsageWindow(days: 30, now: now, calendar: calendar).start.milliseconds
        let rates = await readRates(fetch: fetchRates)
        let pricing = Pricing(table: rates, overrides: Pricing.parseOverrides(sources.priceOverrides))
        var scan = scanSources(sources, enabled: providers, retention: retention)
        LocalTierHistory.resolve(&scan.files, path: sources.t3.appending(path: "statev2.sqlite").path,
                                 since: broadWindow.start.milliseconds)
        if dirty, let data = try? JSONEncoder().encode(cache) {
            dirty = !persist(data, as: "scan-v1.json")
        }
        return days.map { days in
            let window = UsageWindow(days: days, now: now, calendar: calendar)
            let files = scan.files.compactMap { file -> UsageFile? in
                if file.path.hasSuffix(".db") || file.path.hasSuffix(".json") {
                    return UsageFile(path: file.path, records: file.records.filter { $0.timestampMs >= window.start.milliseconds })
                }
                guard let entry = cache.transcripts[file.path],
                      entry.stamp.mtimeMs >= window.start.milliseconds - transcriptSlack else { return nil }
                return file
            }
            let statuses = scan.status.map { raw in
                var status = raw
                if status.provider == .claude || status.provider == .codex {
                    status.malformedRecords = files.reduce(0) { sum, file in
                        guard let entry = cache.transcripts[file.path], entry.provider == status.provider else { return sum }
                        return sum + entry.malformed.filter(window.contains).count
                    }
                    if status.malformedRecords > 0 { status.state = .partial }
                }
                return status
            }
            return Aggregation.summarize(files: files, window: window, now: now, pricing: pricing,
                                         modelAliases: sources.aliases, filter: sources.filter, sources: statuses)
        }
    }

    private func scanSources(_ sources: LocalSources, enabled: Set<Provider>, retention: Int64) -> Scan {
        var scan = Scan()
        for provider in Provider.allCases {
            let roots = sources.roots(provider)
            var status = SourceStatus(provider: provider, paths: roots, state: enabled.contains(provider) ? .missing : .disabled, files: 0)
            guard enabled.contains(provider) else { scan.status.append(status); continue }
            var failures = false
            var visited: Set<String> = []
            var conversations: [(path: String, data: Antigravity.Conversation)] = []
            for root in roots {
                var openCodeIDs: Set<String> = []
                let accept: (String) -> Bool
                switch provider {
                case .claude, .codex: accept = { $0.hasSuffix(".jsonl") || $0.hasSuffix(".jsonl.zst") }
                case .antigravity: accept = { $0.hasSuffix(".db") }
                case .opencode: accept = { matches($0, #"^opencode(?:-[a-zA-Z0-9_-]+)?\.db$"#) }
                }
                var files = walk(root, recursive: provider != .opencode, accept: accept, partial: &failures)
                if provider == .opencode {
                    files.sort {
                        let first = URL(fileURLWithPath: $0).lastPathComponent == "opencode.db"
                        let second = URL(fileURLWithPath: $1).lastPathComponent == "opencode.db"
                        return first != second ? first : $0 < $1
                    }
                    files += walk(root + "/storage/message", recursive: true,
                                  accept: { $0.hasSuffix(".json") }, partial: &failures)
                } else if provider != .antigravity, FileManager.default.fileExists(atPath: root) {
                    status.state = .ready
                }
                let paths = Set(files)
                for path in files {
                    let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                    guard visited.insert(canonical).inserted else { continue }
                    guard let stamp = FileStamp(canonical) else { failures = true; continue }
                    do {
                        switch provider {
                        case .claude, .codex:
                            guard stamp.mtimeMs >= retention - transcriptSlack else { continue }
                            let previous = cache.transcripts[canonical]
                            let entry = try Transcripts.read(canonical, provider: provider, stamp: stamp, previous: previous)
                            if previous?.stamp != stamp || previous?.provider != provider {
                                cache.transcripts[canonical] = entry
                                dirty = true
                            }
                            status.files += 1
                            scan.files.append(UsageFile(path: canonical, records: entry.allRecords))
                            if canonical.hasSuffix(".jsonl.zst") {
                                let original = String(canonical.dropLast(4))
                                if !paths.contains(original), cache.transcripts.removeValue(forKey: original) != nil {
                                    dirty = true
                                }
                            }
                        case .antigravity:
                            let version = stamp.fingerprint + "/" + (FileStamp(canonical + "-wal")?.fingerprint ?? "-")
                            let entry: AntigravityEntry
                            if let previous = cache.antigravity[canonical], previous.version == version { entry = previous }
                            else {
                                entry = AntigravityEntry(version: version, data: try Antigravity.read(canonical, fallback: stamp.mtimeMs))
                                cache.antigravity[canonical] = entry
                                dirty = true
                            }
                            if let data = entry.data { conversations.append((canonical, data)); status.files += 1 }
                            status.state = .ready
                        case .opencode:
                            status.state = .ready
                            let records: [UsageRecord]
                            if canonical.hasSuffix(".db") {
                                var rows = cache.openCode[canonical] ?? [:]
                                records = try OpenCode.read(canonical, since: retention, identity: stamp.fingerprint,
                                                            wal: FileStamp(canonical + "-wal")?.fingerprint ?? "-", cache: &rows)
                                cache.openCode[canonical] = rows
                                dirty = true
                            } else {
                                guard stamp.mtimeMs >= retention else { continue }
                                let id = URL(fileURLWithPath: canonical).deletingPathExtension().lastPathComponent
                                guard !openCodeIDs.contains("opencode:\(id)") else { continue }
                                let data = try Data(contentsOf: URL(fileURLWithPath: canonical))
                                records = json(data).flatMap { OpenCode.parse($0, id: id) }.map { [$0] } ?? []
                            }
                            scan.files.append(UsageFile(path: canonical, records: records.filter { record in
                                record.dedupeKey.map { openCodeIDs.insert($0).inserted } ?? true
                            }))
                            status.files += 1
                        }
                    } catch {
                        failures = true
                        if let previous = cache.transcripts[canonical], previous.provider == provider {
                            scan.files.append(UsageFile(path: canonical, records: previous.allRecords))
                        }
                    }
                }
                if provider == .claude || provider == .codex {
                    for (path, entry) in cache.transcripts.sorted(by: { $0.key < $1.key })
                    where entry.provider == provider && entry.stamp.mtimeMs >= retention
                        && path.hasPrefix(root + "/") && visited.insert(path).inserted {
                        scan.files.append(UsageFile(path: path, records: entry.allRecords))
                    }
                }
            }
            if provider == .antigravity { scan.files += Antigravity.resolve(conversations, since: retention) }
            if failures { status.state = .partial }
            scan.status.append(status)
        }
        let oldCount = cache.transcripts.count
        cache.transcripts = cache.transcripts.filter { $0.value.stamp.mtimeMs >= retention - transcriptSlack }
        if oldCount != cache.transcripts.count { dirty = true }
        return scan
    }

    private func walk(_ path: String, recursive: Bool, accept: (String) -> Bool, partial: inout Bool) -> [String] {
        let manager = FileManager.default
        let directory = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        do {
            let entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: [.caseInsensitive]) == .orderedAscending }
            var files: [String] = []
            for entry in entries {
                do {
                    let info = try entry.resourceValues(forKeys: keys)
                    guard info.isSymbolicLink != true else { continue }
                    if recursive && info.isDirectory == true {
                        files += walk(entry.path, recursive: true, accept: accept, partial: &partial)
                    } else if info.isRegularFile == true, accept(entry.lastPathComponent) { files.append(entry.path) }
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
                catch { partial = true }
            }
            return files
        } catch let error as CocoaError where [.fileReadNoSuchFile, .fileNoSuchFile].contains(error.code) {
            return []
        } catch {
            partial = true
            return []
        }
    }

    private func persist(_ data: Data, as name: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try data.write(to: cacheDirectory.appending(path: name), options: .atomic)
            return true
        } catch { return false }
    }

    private func readRates(fetch: Bool) async -> Pricing.RateTable {
        let now = Date()
        let file = cacheDirectory.appending(path: "litellm-rates.json")
        if rateTable == nil, let data = try? Data(contentsOf: file), let document = json(data) {
            rateTable = Pricing.parse(document)
        }
        let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let fresh = modified.map { now.timeIntervalSince($0) < 86_400 } ?? false
        if !fresh, fetch, now >= nextRateAttempt,
           let url = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json") {
            nextRateAttempt = now.addingTimeInterval(300)
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 12
            config.httpShouldSetCookies = false
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            if let (data, response) = try? await session.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200, let document = json(data) {
                let parsed = Pricing.parse(document)
                if !parsed.isEmpty {
                    _ = persist(data, as: "litellm-rates.json")
                    rateTable = parsed
                }
            }
        }
        return rateTable ?? [:]
    }
}
