import Foundation
import SQLite3

struct ProtoFields {
    enum Value { case integer(UInt64), bytes(ArraySlice<UInt8>) }
    var fields: [Int: [Value]] = [:]

    init(_ data: Data) throws { try self.init(Array(data)[...]) }

    init(_ bytes: ArraySlice<UInt8> = []) throws {
        var offset = bytes.startIndex
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < bytes.endIndex else { throw ReadFailure.invalidData }
                let byte = bytes[offset]
                offset += 1
                guard shift < 63 || byte <= 1 else { throw ReadFailure.invalidData }
                value |= UInt64(byte & 127) << shift
                if byte < 128 { return value }
            }
            throw ReadFailure.invalidData
        }
        while offset < bytes.endIndex {
            let tag = try varint()
            guard tag >= 8, tag <= 9_007_199_254_740_991 else { throw ReadFailure.invalidData }
            let key = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                let value = try varint()
                fields[key, default: []].append(.integer(value))
            case 1, 2, 5:
                let wire = tag & 7
                let length: UInt64 = wire == 2 ? try varint() : wire == 1 ? 8 : 4
                guard length <= bytes.endIndex - offset else { throw ReadFailure.invalidData }
                let end = offset + Int(length)
                if wire == 2 { fields[key, default: []].append(.bytes(bytes[offset..<end])) }
                offset = end
            default:
                throw ReadFailure.invalidData
            }
        }
    }

    func integer(_ key: Int) -> Int64 {
        guard case let .integer(value)? = fields[key]?.first, value <= 9_007_199_254_740_991 else { return 0 }
        return Int64(value)
    }

    func bytes(_ key: Int) -> ArraySlice<UInt8>? {
        guard case let .bytes(bytes)? = fields[key]?.first else { return nil }
        return bytes
    }

    func nested(_ key: Int) throws -> Self { try Self(bytes(key) ?? []) }

    func string(_ key: Int) throws -> String {
        guard let bytes = bytes(key) else { return "" }
        guard let value = String(bytes: bytes, encoding: .utf8) else { throw ReadFailure.invalidData }
        return trimmed(value)
    }

    var timestamp: Int64? {
        let seconds = integer(1)
        guard seconds > 0, seconds <= Int64.max / 2_000 else { return nil }
        return seconds * 1_000 + integer(2) / 1_000_000
    }
}

enum Antigravity {
    private static let modelIDs: [Int64: String] = [
        246: "gemini-2.5-pro", 312: "gemini-2.5-flash", 313: "gemini-2.5-flash-thinking",
        329: "gemini-2.5-flash-thinking", 330: "gemini-2.5-flash-lite", 281: "claude-sonnet-4",
        282: "claude-sonnet-4", 290: "claude-opus-4", 291: "claude-opus-4",
        333: "claude-sonnet-4-5", 334: "claude-sonnet-4-5", 340: "claude-haiku-4-5",
        341: "claude-haiku-4-5", 342: "gpt-oss-120b-medium", 1026: "claude-opus-4-6",
        1035: "claude-sonnet-4-6", 1016: "gemini-3.1-pro", 1036: "gemini-3.1-pro",
        1037: "gemini-3.1-pro", 1018: "gemini-3-flash-preview", 1084: "gemini-3-flash-preview",
        1047: "gemini-3-flash-preview", 1020: "gemini-3.5-flash-medium", 1021: "gemini-3.1-flash-image",
        1050: "gemini-3.1-flash-lite", 1071: "gemini-3.6-flash-high", 1072: "gemini-3.6-flash-medium",
        1073: "gemini-3.6-flash-low", 1132: "gemini-3.5-flash-high", 1133: "gemini-3.5-flash-high",
        1187: "gemini-3.5-flash-extra-low", 1196: "gemini-3.6-flash", 1266: "gemini-3.6-flash",
        1298: "gemini-3.7-flash-high", 1299: "gemini-3.7-flash-medium", 1300: "gemini-3.7-flash-low",
        1301: "gemini-3.7-flash-tiered", 1318: "gemini-3.8-flash-high", 1319: "gemini-3.8-flash-medium",
        1320: "gemini-3.8-flash-low", 1322: "gemini-3.8-flash-tiered", 1402: "claude-opus-5-5",
        1417: "gemini-4-argon", 1418: "gemini-4-argon", 1419: "gemini-4-argon",
        1537: "gemini-pro-orchestrator-neon"
    ]
    private static let agentPattern = #"^gemini-3-flash-(?:agent(?:-[ab])?|[ab])$"#

    struct Candidate: Codable {
        var record: UsageRecord
        let modelID: Int64
        var modelQuality: Int
        let keys: [String]
        var timeQuality: Int
    }

    struct Conversation: Codable {
        var candidates: [Candidate] = []
        var models: [Int64: String] = [:]
    }

    private struct Metadata {
        let model: String
        let modelID: Int64
        let timestamp: Int64?
        let usages: [ProtoFields]

        init(_ bytes: Data, step: Bool) throws {
            let root = try ProtoFields(bytes)
            if !step, root.bytes(1) == nil { throw ReadFailure.invalidData }
            let data = step ? root : try root.nested(1)
            let model = step ? try data.nested(24) : data
            let primary = try data.bytes(step ? 9 : 4).map { try ProtoFields(Array($0)[...]) }
            var usages = primary.map { [$0] } ?? []
            for retry in data.fields[step ? 28 : 17] ?? [] {
                guard case let .bytes(bytes) = retry else { throw ReadFailure.invalidData }
                if let usage = try ProtoFields(bytes).bytes(2) {
                    usages.append(try ProtoFields(Array(usage)[...]))
                }
            }
            let names = try [model.string(step ? 12 : 19), model.string(step ? 8 : 21)].map(Antigravity.modelName)
            self.model = names.first(where: Antigravity.concrete)
                ?? names.first { !$0.isEmpty && !matches($0, #"^model[_-]"#) } ?? ""
            let id = model.integer(step ? 1 : 3)
            modelID = id != 0 ? id : primary?.integer(1) ?? 0
            timestamp = step
                ? try data.nested(8).timestamp ?? data.nested(1).timestamp
                : try data.nested(9).nested(4).timestamp
            self.usages = usages
        }
    }

    static func rateModel(_ model: String) -> String {
        if matches(model, agentPattern) { return "gemini-3.5-flash" }
        switch model {
        case "gemini-3.7-flash-safety-le": return "gemini-3.7-flash"
        case "gemini-pro-orchestrator-neon": return "gemini-4-neon"
        case "gemini-pro-orchestrator-g1-pro": return "gemini-4-argon"
        default:
            let base = replacing(model, #"-(?:extra-low|low|medium|high|tiered|control|thinking|agent|orchestrator)$"#, "")
            return base == "gemini-3-flash" ? "gemini-3-flash-preview" : base
        }
    }

    private static func modelName(_ name: String) -> String {
        let normalized = replacing(replacing(name.lowercased(), #"\s*\(([^)]*)\)\s*$"#, "-$1"), #"\s+"#, "-")
        guard normalized.hasPrefix("claude-") else { return normalized }
        return replacing(normalized, #"^claude-(\d+(?:\.\d+)?)-(sonnet|opus|haiku)"#, "claude-$2-$1")
            .replacingOccurrences(of: ".", with: "-")
    }

    private static func concrete(_ model: String) -> Bool {
        matches(model, #"^(?:gemini-\d|claude-(?:sonnet|opus|haiku)-\d|gpt-)"#) && !matches(model, agentPattern)
    }

    private static func remember(_ models: inout [Int64: String], _ id: Int64, _ name: String) {
        models[id] = models[id].map { $0 == name ? name : "" } ?? name
    }

    static func read(_ path: String, fallback: Int64) throws -> Conversation? {
        let database = try ReadDatabase(path)
        let session = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return try database.transaction {
            let tables = try database.tables()
            guard tables.contains("steps") || tables.contains("gen_metadata") else { return nil }
            func readMetadata(step: Bool) throws -> [(Int64, Metadata)] {
                let table = step ? "steps" : "gen_metadata"
                guard tables.contains(table) else { return [] }
                let column = step ? "metadata" : "data"
                var rows: [(Int64, Metadata)] = []
                try database.rows("SELECT idx, \(column) FROM \(table) ORDER BY rowid") { row in
                    if step, sqlite3_column_type(row, 1) == SQLITE_NULL { return }
                    guard let index = ReadDatabase.integer(row, 0), let data = ReadDatabase.data(row, 1) else {
                        throw ReadFailure.invalidData
                    }
                    rows.append((index, try Metadata(data, step: step)))
                }
                return rows.sorted { $0.0 < $1.0 }
            }
            let generations = try readMetadata(step: false)
            let steps = try readMetadata(step: true)
            var trajectory: Int64?
            if tables.contains("trajectory_metadata_blob") {
                try database.rows("SELECT data FROM trajectory_metadata_blob") { row in
                    guard trajectory == nil else { return }
                    guard let data = ReadDatabase.data(row, 0) else { throw ReadFailure.invalidData }
                    trajectory = try ProtoFields(data).nested(2).timestamp
                }
            }
            var result = Conversation()
            for (_, metadata) in generations + steps where metadata.modelID > 0 && concrete(metadata.model) {
                remember(&result.models, metadata.modelID, metadata.model)
            }
            let indexed = Dictionary(generations, uniquingKeysWith: { _, last in last })
            for (source, entries) in [("step", steps), ("generation", generations)] {
                for (position, pair) in entries.enumerated() {
                    let (index, entry) = pair
                    let generation = source == "step" ? indexed[index] : nil
                    for (usageIndex, usage) in entry.usages.enumerated() {
                        let id = usage.integer(1) == 0 ? entry.modelID : usage.integer(1)
                        let model: String
                        if (id == 0 || entry.modelID == id), !entry.model.isEmpty { model = entry.model }
                        else if let generation, id == 0 || generation.modelID == id { model = generation.model }
                        else { model = "" }
                        let output = max(usage.integer(3), usage.integer(9) + usage.integer(10))
                        let totals = Tokens(uncachedInputTokens: usage.integer(2), cachedInputTokens: usage.integer(5),
                                            cacheCreationTokens: usage.integer(4), outputTokens: output,
                                            reasoningTokens: min(output, usage.integer(9)))
                        guard totals.total > 0 else { continue }
                        let keys = try [11, 12, 7].compactMap { key -> String? in
                            let value = try usage.string(key)
                            return value.isEmpty ? nil : "antigravity:\(key):\(value)"
                        }
                        let timestamp = entry.timestamp ?? trajectory ?? fallback
                        let key = keys.first ?? "antigravity:\(session):\(source):\(position):\(usageIndex)"
                        let record = UsageRecord(provider: .antigravity, timestampMs: timestamp,
                                                 model: model, sessionId: session, totals: totals, dedupeKey: key)
                        result.candidates.append(Candidate(record: record, modelID: id,
                            modelQuality: concrete(model) ? 4 : model.isEmpty ? 0 : 1,
                            keys: keys, timeQuality: entry.timestamp != nil ? 2 : trajectory != nil ? 1 : 0))
                    }
                }
            }
            return result
        }
    }

    static func resolve(_ conversations: [(path: String, data: Conversation)], since: Int64) -> [UsageFile] {
        var models: [Int64: String] = [:]
        for conversation in conversations {
            for (id, model) in conversation.data.models { remember(&models, id, model) }
        }
        struct Group {
            var candidate: Candidate
            var parent: Int
            var size = 1
            var owner: Int
            var file: Int
        }
        var groups: [Group] = []
        var identities: [String: Int] = [:]
        func find(_ index: Int) -> Int {
            var root = index
            while groups[root].parent != root { root = groups[root].parent }
            var child = index
            while child != root {
                let next = groups[child].parent
                groups[child].parent = root
                child = next
            }
            return root
        }
        func merge(_ left: Int, _ right: Int) {
            var target = find(left)
            var source = find(right)
            guard target != source else { return }
            if groups[target].size < groups[source].size { swap(&target, &source) }
            let held = groups[target]
            let copy = groups[source]
            let first = held.owner < copy.owner ? held : copy
            let bestModel = held.candidate.modelQuality == copy.candidate.modelQuality
                ? first : held.candidate.modelQuality > copy.candidate.modelQuality ? held : copy
            let lhs = held.candidate
            let rhs = copy.candidate
            let bestTime = rhs.timeQuality > lhs.timeQuality
                || (rhs.timeQuality == lhs.timeQuality && rhs.record.timestampMs < lhs.record.timestampMs) ? rhs : lhs
            var merged = first.candidate
            merged.record.model = bestModel.candidate.record.model
            merged.modelQuality = bestModel.candidate.modelQuality
            merged.record.timestampMs = bestTime.record.timestampMs
            merged.timeQuality = bestTime.timeQuality
            merged.record.totals = lhs.record.totals.merging(rhs.record.totals)
            groups[target] = Group(candidate: merged, parent: target, size: held.size + copy.size,
                                   owner: first.owner, file: first.file)
            groups[source].parent = target
        }
        for (file, conversation) in conversations.enumerated() {
            for var candidate in conversation.data.candidates {
                if candidate.modelQuality != 4 {
                    let learned = models[candidate.modelID]
                    if let learned, !learned.isEmpty {
                        candidate.record.model = learned
                        candidate.modelQuality = 3
                    } else if learned == nil, let model = modelIDs[candidate.modelID] {
                        candidate.record.model = model
                        candidate.modelQuality = 2
                    } else if candidate.record.model.isEmpty {
                        candidate.record.model = candidate.modelID > 0
                            ? "antigravity-model-\(candidate.modelID)" : "antigravity-unknown"
                    }
                }
                let index = groups.count
                groups.append(Group(candidate: candidate, parent: index, owner: index, file: file))
                for key in candidate.keys {
                    if let existing = identities[key] { merge(index, existing) }
                    identities[key] = index
                }
            }
        }
        var files = conversations.map { UsageFile(path: $0.path, records: []) }
        for (index, group) in groups.enumerated() where group.parent == index && group.candidate.record.timestampMs >= since {
            var record = group.candidate.record
            let rate = rateModel(record.model)
            if rate != record.model { record.rateModel = rate }
            files[group.file].records.append(record)
        }
        return files
    }
}
