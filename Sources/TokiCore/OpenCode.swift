import Foundation

enum OpenCode {
    struct Row: Codable {
        let updated: Int64?
        let size: Int64?
        let record: UsageRecord?
    }

    struct Table: Codable {
        let version: String
        var rows: [Int64: Row] = [:]
    }

    private struct Fork {
        let parent: String
        let boundary: Int64
        let created: Int64
    }

    static func parse(_ message: JSONObject, id: String = "", session: String = "", created: Int64? = nil) -> UsageRecord? {
        if let role = message["role"], text(role) != "assistant" { return nil }
        let usage = object(message["tokens"])
        let cache = object(usage["cache"])
        let reference = object(message["model"])
        guard let model = [text(reference["id"]), text(reference["modelID"]), text(message["modelID"])]
            .first(where: { !$0.isEmpty }) else { return nil }
        let provider = text(reference["providerID"]).isEmpty ? text(message["providerID"]) : text(reference["providerID"])
        let rawTime = object(message["time"])["created"]
        guard let timestamp = rawTime == nil || rawTime is NSNull ? created
            : number(rawTime).flatMap({ Int64(exactly: $0.rounded(.towardZero)) }) else { return nil }
        let reasoning = count(usage["reasoning"])
        let totals = Tokens(uncachedInputTokens: count(usage["input"]), cachedInputTokens: count(cache["read"]),
                            cacheCreationTokens: count(cache["write"]), outputTokens: count(usage["output"]) + reasoning,
                            reasoningTokens: reasoning)
        guard totals.total > 0 else { return nil }
        let id = id.isEmpty ? text(message["id"]) : id
        let free = ["opencode", "opencode-go"].contains(provider) && model.hasSuffix("-free")
        let cost = number(message["cost"]).flatMap { $0 > 0 || (free && $0 == 0) ? $0 : nil }
        return UsageRecord(provider: .opencode, timestampMs: timestamp, model: model,
                           sessionId: session.isEmpty ? text(message["sessionID"]) : session,
                           totals: totals, reportedCostUsd: cost, dedupeKey: id.isEmpty ? nil : "opencode:\(id)",
                           rateModel: provider == "opencode-go" && !model.contains("/") ? "opencode_go/\(model)" : nil)
    }

    static func read(_ path: String, since: Int64, identity: String, wal: String,
                     cache: inout [String: Table]) throws -> [UsageRecord] {
        let database = try ReadDatabase(path)
        return try database.transaction {
            let tables = try database.tables()
            guard tables.contains("message") || tables.contains("session_message") else { throw ReadFailure.invalidData }
            var forks: [String: Fork] = [:]
            if tables.contains("session_v2"), tables.contains("session_message"),
               try database.columns("session_message").contains("seq"),
               try database.columns("session_v2").contains("fork_boundary") {
                try database.rows("""
                    SELECT fork.id, fork.fork_session_id, fork.time_created,
                      (SELECT MAX(copied.seq) FROM session_message AS copied
                       WHERE copied.session_id = fork.fork_session_id AND CASE json_extract(fork.fork_boundary, '$.type')
                       WHEN 'through' THEN copied.seq <= boundary.seq WHEN 'before' THEN copied.seq < boundary.seq END)
                    FROM session_v2 AS fork JOIN session_message AS boundary
                      ON boundary.session_id = fork.fork_session_id
                     AND boundary.id = json_extract(fork.fork_boundary, '$.messageID')
                    WHERE fork.fork_session_id IS NOT NULL AND json_valid(fork.fork_boundary)
                    """) { row in
                    guard let created = ReadDatabase.integer(row, 2), let boundary = ReadDatabase.integer(row, 3) else { return }
                    forks[ReadDatabase.string(row, 0)] = Fork(parent: ReadDatabase.string(row, 1),
                                                              boundary: boundary, created: created)
                }
            }
            var result: [UsageRecord] = []
            var originals: Set<String> = []
            var messages: Set<String> = []
            for table in ["message", "session_message"] where tables.contains(table) {
                let columns = try database.columns(table)
                let timestamp = columns.contains("time_created") ? "time_created" : "NULL"
                let updated = columns.contains("time_updated") ? "time_updated" : "NULL"
                let lineage = table == "session_message" && !forks.isEmpty && columns.contains("seq") ? "seq" : "NULL"
                let version = updated == "NULL" ? "\(identity)/\(wal)" : identity
                let previous = cache[table]?.version == version ? cache[table]?.rows ?? [:] : [:]
                var next = Table(version: version)
                var listed: [(id: Int64, updated: Int64?, size: Int64?, seq: Int64?)] = []
                var predicates: [String] = []
                if table == "session_message" { predicates.append("type IN ('assistant', 'compaction')") }
                if timestamp != "NULL" { predicates.append("time_created >= CAST(? AS INTEGER)") }
                let condition = predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
                do {
                    try database.rows("""
                        SELECT rowid, \(updated), octet_length(data), \(lineage) FROM \(table) \(condition) ORDER BY rowid
                        """, binds: timestamp == "NULL" ? [] : [String(since)]) { row in
                        guard let id = ReadDatabase.integer(row, 0) else { return }
                        listed.append((id, ReadDatabase.integer(row, 1), ReadDatabase.integer(row, 2), ReadDatabase.integer(row, 3)))
                    }
                } catch ReadFailure.sqlite(let message) where message.contains("octet_length") {
                    try database.rows("""
                        SELECT rowid, \(updated), length(CAST(data AS BLOB)), \(lineage) FROM \(table) \(condition) ORDER BY rowid
                        """, binds: timestamp == "NULL" ? [] : [String(since)]) { row in
                        guard let id = ReadDatabase.integer(row, 0) else { return }
                        listed.append((id, ReadDatabase.integer(row, 1), ReadDatabase.integer(row, 2), ReadDatabase.integer(row, 3)))
                    }
                }
                let misses = listed.filter { marker in
                    guard let hit = previous[marker.id], hit.updated == marker.updated, hit.size == marker.size else { return true }
                    next.rows[marker.id] = hit
                    return false
                }
                for start in stride(from: 0, to: misses.count, by: 64) {
                    let page = misses[start..<min(start + 64, misses.count)]
                    let placeholders = Array(repeating: "?", count: page.count).joined(separator: ", ")
                    var parsed: [Int64: UsageRecord] = [:]
                    try database.rows("""
                        SELECT rowid, id, session_id, \(timestamp), json_object(
                            'tokens', data -> '$.tokens', 'cost', data -> '$.cost', 'model', data -> '$.model',
                            'modelID', data -> '$.modelID', 'providerID', data -> '$.providerID', 'time', data -> '$.time',
                            'id', data -> '$.id', 'sessionID', data -> '$.sessionID')
                        FROM \(table) WHERE rowid IN (\(placeholders))
                          AND CASE WHEN typeof(data) = 'text' AND json_valid(data)
                            THEN json_type(data, '$.role') IS NULL OR data ->> '$.role' = 'assistant' END
                        """, binds: page.map { String($0.id) }) { row in
                        guard let id = ReadDatabase.integer(row, 0),
                              let data = json(Data(ReadDatabase.string(row, 4).utf8)) else { return }
                        parsed[id] = parse(data, id: ReadDatabase.string(row, 1), session: ReadDatabase.string(row, 2),
                                           created: ReadDatabase.integer(row, 3))
                    }
                    for marker in page {
                        next.rows[marker.id] = Row(updated: marker.updated, size: marker.size, record: parsed[marker.id])
                    }
                }
                cache[table] = next
                for marker in listed {
                    guard let record = next.rows[marker.id]?.record else { continue }
                    if let sequence = marker.seq {
                        var origin = record.sessionId
                        var visited: Set<String> = []
                        while let fork = forks[origin], sequence <= fork.boundary,
                              record.timestampMs < fork.created, visited.insert(origin).inserted {
                            origin = fork.parent
                        }
                        guard originals.insert("\(origin):\(sequence)").inserted else { continue }
                    }
                    guard record.timestampMs >= since else { continue }
                    if let key = record.dedupeKey, !messages.insert(key).inserted { continue }
                    result.append(record)
                }
            }
            return result
        }
    }
}
