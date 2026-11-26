import Foundation
import SQLite3
import Testing
@testable import TokiCore

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func createDatabase(_ path: String, sql: String) throws {
    var database: OpaquePointer?
    let status = sqlite3_open(path, &database)
    defer { if let database { sqlite3_close(database) } }
    try #require(status == SQLITE_OK)
    try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
}

private func iso(_ seconds: Int) -> String { "2026-11-26T00:00:\(String(format: "%02d", seconds))Z" }

private func record(_ source: String) throws -> JSONObject {
    try #require(json(Data(source.utf8)))
}

@Test func claudeStreamingCopiesMergeChannelsAndBillAdvisorSeparately() throws {
    let value = try record("""
        {"type":"assistant","sessionId":"thread","timestamp":"\(iso(0))","requestId":"r","costUSD":0.03,
         "message":{"id":"m","model":"claude-opus-4-6","usage":{"input_tokens":22,"output_tokens":4,
         "cache_read_input_tokens":200,"cache_creation_input_tokens":16,"cache_creation":{"ephemeral_1h_input_tokens":13},
         "speed":"fast","iterations":[{"type":"message","input_tokens":22},{"type":"advisor_message",
         "model":"claude-sonnet-4-6","input_tokens":5,"output_tokens":6}]}}}
        """)
    var values = Claude.parse(value, timestamps: TimestampParser())
    try #require(values.count == 2)
    #expect(values[0].totals.total == 242)
    #expect(values[0].cacheCreation1hTokens == 13)
    #expect(values[0].reportedCostUsd == 0.03)
    #expect(values[1].dedupeKey == "m:r:advisor:1")
    #expect(values[1].totals.total == 11)
    #expect(values[1].speed == .fast)
    var copy = values[0]
    copy.totals.outputTokens = 20
    copy.totals.uncachedInputTokens = 0
    copy.reportedCostUsd = 0.04
    values.append(copy)
    let merged = Aggregation.dedupeWithinFile(values)
    #expect(merged.count == 2)
    #expect(merged[0].totals.total == 258)
    #expect(merged[0].reportedCostUsd == 0.04)
    let synthetic = try record("""
        {"type":"assistant","timestamp":"\(iso(0))","message":{"model":"<synthetic>","usage":{"input_tokens":100}}}
        """)
    #expect(Claude.parse(synthetic, timestamps: TimestampParser()).isEmpty)
}

private struct CodexFixture {
    var state = CodexState()
    let timestamps = TimestampParser()

    mutating func event(_ type: String, _ payload: JSONObject, at time: Int) -> [UsageRecord] {
        state.parse(["type": type, "timestamp": iso(time), "payload": payload], timestamps: timestamps)
    }

    mutating func snapshot(_ last: Int, _ cumulative: Int?, at time: Int) -> [UsageRecord] {
        var info: JSONObject = ["last_token_usage": counters(last)]
        if let cumulative { info["total_token_usage"] = counters(cumulative) }
        return event("event_msg", ["type": "token_count", "info": info], at: time)
    }

    func counters(_ input: Int) -> JSONObject { ["input_tokens": input, "output_tokens": 0] }
}

@Test func codexReconcilesPendingGapAndKeepsOriginalAttribution() {
    var fixture = CodexFixture()
    _ = fixture.event("session_meta", ["id": "session", "model_provider": "openai"], at: 0)
    _ = fixture.event("turn_context", ["model": "older", "turn_id": "turn"], at: 1)
    #expect(fixture.snapshot(20, 20, at: 2).first?.unresolvedTurnId == "turn")
    #expect(fixture.event("token_usage_record", ["usage": fixture.counters(12)], at: 3).isEmpty)
    _ = fixture.event("turn_context", ["model": "newer"], at: 4)
    _ = fixture.event("event_msg", ["type": "thread_settings_applied", "thread_settings": ["service_tier": "priority"]], at: 4)
    #expect(fixture.event("token_usage_record", ["usage": fixture.counters(8)], at: 5).isEmpty)
    let gap = fixture.snapshot(5, 40, at: 6)
    #expect(gap.map(\.totals.total) == [12, 3, 5])
    #expect(gap.map(\.model) == ["older", "newer", "newer"])
    #expect(gap.map(\.speed) == [.standard, .fast, .fast])
    #expect(fixture.snapshot(5, 40, at: 6).isEmpty)
}

@Test func codexRebaseAndReplayDoNotDoubleCount() {
    var fixture = CodexFixture()
    _ = fixture.event("turn_context", ["model": "model"], at: 0)
    #expect(fixture.snapshot(30, 30, at: 1).count == 1)
    #expect(fixture.snapshot(10, 40, at: 2).count == 1)
    #expect(fixture.snapshot(30, 30, at: 1).isEmpty)
    #expect(fixture.snapshot(5, 45, at: 3).count == 1)
    #expect(fixture.snapshot(10, 15, at: 4).count == 1)
    #expect(fixture.snapshot(2, 17, at: 5).count == 1)
    #expect(fixture.snapshot(0, 0, at: 6).isEmpty)
    #expect(fixture.snapshot(30, 30, at: 7).count == 1)
}

@Test func codexSuppressesForkCopiesAndPrefersRequestLedger() {
    var fixture = CodexFixture()
    _ = fixture.event("session_meta", ["id": "fork", "forked_from_id": "parent"], at: 0)
    _ = fixture.event("session_meta", ["id": "parent"], at: 0)
    _ = fixture.event("turn_context", ["model": "model"], at: 0)
    #expect(fixture.snapshot(30, 30, at: 0).isEmpty)
    let ledger = fixture.event("token_usage_record", ["usage": fixture.counters(12), "response_id": "response"], at: 2)
    #expect(ledger.first?.sessionId == "fork")
    #expect(ledger.first?.dedupeKey != nil)
    #expect(fixture.snapshot(12, 42, at: 3).isEmpty)
}

@Test func transcriptResumesFromBeforeTentativeLineAndInvalidatesRewrites() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "session.jsonl")
    let first = #"{"type":"turn_context","payload":{"model":"gpt-model"}}"# + "\n"
    let event = """
        {"timestamp":"\(iso(4))","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":15,"output_tokens":3}}}}
        """
    try Data((first + event).utf8).write(to: url)
    let original = try Transcripts.read(url.path, provider: .codex, stamp: #require(FileStamp(url.path)), previous: nil)
    #expect(original.byteOffset == first.utf8.count)
    #expect(original.tailRecords.first?.totals.total == 18)
    let writer = try FileHandle(forWritingTo: url)
    try writer.seekToEnd()
    try writer.write(contentsOf: Data("\n".utf8))
    try writer.close()
    let next = try Transcripts.read(url.path, provider: .codex, stamp: #require(FileStamp(url.path)), previous: original)
    #expect(next.records.first?.totals.total == 18)
    #expect(next.records.count == 1)
    #expect(next.tailRecords.isEmpty)
    try Data().write(to: url, options: .atomic)
    let shortened = try Transcripts.read(url.path, provider: .codex, stamp: #require(FileStamp(url.path)), previous: next)
    #expect(shortened.allRecords.isEmpty)
}

private func varint(_ value: UInt64) -> [UInt8] {
    var remaining = value
    var bytes: [UInt8] = []
    while remaining >= 128 {
        bytes.append(UInt8(remaining & 127) | 128)
        remaining >>= 7
    }
    return bytes + [UInt8(remaining)]
}

private func proto(_ field: UInt64, _ value: UInt64) -> [UInt8] { varint(field * 8) + varint(value) }
private func proto(_ field: UInt64, _ value: [UInt8]) -> [UInt8] {
    varint(field * 8 + 2) + varint(UInt64(value.count)) + value
}
private func hex(_ data: [UInt8]) -> String { data.map { String(format: "%02x", $0) }.joined() }

@Test func antigravityDecodesSQLiteProtobufAndMergesLinkedDuplicates() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "session.db").path
    let usage = proto(1, 1026) + proto(2, 30) + proto(9, 5) + proto(10, 6) + proto(11, Array("request".utf8))
    let names = proto(3, 1026) + proto(19, Array("Claude 4.6 Opus".utf8))
    let generation = proto(1, names + proto(4, usage))
    let stepUsage = proto(1, 1026) + proto(5, 40) + proto(11, Array("request".utf8))
    let time = proto(1, 1_790_000_000) + proto(2, 90_000_000)
    let step = proto(8, time) + proto(9, stepUsage)
    try createDatabase(path, sql: """
        CREATE TABLE gen_metadata (idx INTEGER, data BLOB);
        CREATE TABLE steps (idx INTEGER, metadata BLOB);
        INSERT INTO gen_metadata VALUES (1, X'\(hex(generation))');
        INSERT INTO steps VALUES (1, X'\(hex(step))');
        """)
    let decoded = try Antigravity.read(path, fallback: 100)
    let conversation = try #require(decoded)
    let merged = Antigravity.resolve([(path, conversation)], since: 0)
    let value = try #require(merged.first?.records.first)
    #expect(merged[0].records.count == 1)
    #expect(value.timestampMs == 1_790_000_000_090)
    #expect(value.model == "claude-opus-4-6")
    #expect(value.totals.total == 81)
    #expect(value.totals.reasoningTokens == 5)
    #expect(Antigravity.rateModel("gemini-3.7-flash-extra-low") == "gemini-3.7-flash")
    #expect(throws: ReadFailure.self) { try ProtoFields(Data([0x80])) }
}

@Test func antigravityLearnsModelNamesAndFallsBackForAnonymousMetadata() {
    let totals = Tokens(uncachedInputTokens: 10)
    let record = UsageRecord(provider: .antigravity, timestampMs: 100, model: "", sessionId: "s", totals: totals)
    let prototype = Antigravity.Candidate(record: record, modelID: 1026, modelQuality: 0, keys: [], timeQuality: 1)
    let original = Antigravity.Conversation(candidates: [prototype])
    let learned = Antigravity.Conversation(models: [1026: "claude-opus-5-5"])
    #expect(Antigravity.resolve([("first", original)], since: 0)[0].records[0].model == "claude-opus-4-6")
    #expect(Antigravity.resolve([("first", original), ("later", learned)], since: 0)[0].records[0].model == "claude-opus-5-5")
}

@Test func openCodeScansBothSchemasAndRefreshesCachedRow() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "opencode.db").path
    let message = """
        {"role":"assistant","model":{"id":"example-free","providerID":"opencode-go"},"cost":0,
        "tokens":{"input":20,"output":4,"reasoning":5,"cache":{"read":30,"write":1}}}
        """
    try createDatabase(path, sql: """
        CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
        CREATE TABLE session_message (id TEXT, session_id TEXT, type TEXT, time_created INTEGER, data TEXT);
        INSERT INTO message VALUES ('one', 'parent', 100, 100, '\(message)');
        INSERT INTO session_message VALUES ('one', 'parent', 'assistant', 100, '\(message)');
        INSERT INTO session_message VALUES ('two', 'parent', 'compaction', 200, '\(message)');
        INSERT INTO session_message VALUES ('three', 'parent', 'user', 300, '\(message)');
        """)
    var cache: [String: OpenCode.Table] = [:]
    let first = try OpenCode.read(path, since: 99, identity: "db", wal: "wal", cache: &cache)
    #expect(first.count == 2)
    #expect(first.first?.totals.total == 60)
    #expect(first.first?.totals.outputTokens == 9)
    #expect(first.first?.reportedCostUsd == 0)
    #expect(first.first?.rateModel == "opencode_go/example-free")
    try createDatabase(path, sql: "UPDATE message SET data = replace(data, '20', '25'), time_updated = 101;")
    let second = try OpenCode.read(path, since: 99, identity: "db", wal: "wal2", cache: &cache)
    #expect(second.first?.totals.total == 65)
    #expect(second.count == 2)
}

@Test func openCodeV2ForkBoundaryKeepsOnlyOriginalAndNewMessages() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "opencode.db").path
    let message = #"{"modelID":"model","tokens":{"input":20}}"#
    try createDatabase(path, sql: """
        CREATE TABLE session_v2 (id TEXT, fork_session_id TEXT, time_created INTEGER, fork_boundary TEXT);
        CREATE TABLE session_message (id TEXT, session_id TEXT, type TEXT, time_created INTEGER, seq INTEGER, data TEXT);
        INSERT INTO session_v2 VALUES ('fork', 'parent', 200, '{"type":"through","messageID":"first"}');
        INSERT INTO session_message VALUES ('first', 'parent', 'assistant', 100, 1, '\(message)');
        INSERT INTO session_message VALUES ('copy', 'fork', 'assistant', 100, 1, '\(message)');
        INSERT INTO session_message VALUES ('new', 'fork', 'assistant', 300, 2, '\(message)');
        """)
    var cache: [String: OpenCode.Table] = [:]
    let records = try OpenCode.read(path, since: 0, identity: "db", wal: "-", cache: &cache)
    #expect(records.map(\.dedupeKey) == ["opencode:first", "opencode:new"])
}

@Test func pricingAppliesContextTierSpeedAndOneHourWrites() {
    let table = Pricing.parse([
        "anthropic/example": [
            "input_cost_per_token": 2.0, "output_cost_per_token": 4.0,
            "cache_read_input_token_cost": 0.2, "cache_creation_input_token_cost": 3.0,
            "cache_creation_input_token_cost_above_1hr": 5.0,
            "input_cost_per_token_above_1k_tokens": 4.0,
            "provider_specific_entry": ["fast": 2.0]
        ],
        "reseller/example": ["input_cost_per_token": 9.0, "output_cost_per_token": 9.0]
    ])
    let pricing = Pricing(table: table)
    var value = UsageRecord(provider: .claude, timestampMs: 100, model: "example[1m]", sessionId: "",
                            totals: Tokens(uncachedInputTokens: 1_000, cachedInputTokens: 20, cacheCreationTokens: 2,
                                           outputTokens: 3, reasoningTokens: 2), cacheCreation1hTokens: 1, speed: .fast)
    #expect(pricing.price(value).cost == 8_072)
    #expect(pricing.price(value).savings == 144)
    value.reportedCostUsd = 9
    #expect(pricing.price(value).cost == 9)
    value.reportedCostUsd = nil
    value.model = "unknown"
    #expect(pricing.price(value).cost == nil)
}

@Test func aggregationFiltersBeforeAliasingAndDedupesMovedCodexWithOccurrences() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = Date(milliseconds: try #require(TimestampParser().parse(iso(0))))
    let window = UsageWindow(days: 1, now: now, calendar: calendar)
    let original = UsageRecord(provider: .codex, timestampMs: now.milliseconds, model: "raw", sessionId: "same",
                               totals: Tokens(uncachedInputTokens: 15, outputTokens: 1))
    var excluded = original
    excluded.model = "excluded"
    let summary = Aggregation.summarize(
        files: [UsageFile(path: "one", records: [original, original, excluded]),
                UsageFile(path: "two", records: [original, original])],
        window: window, now: now, modelAliases: ["raw": "target", "excluded": "target"],
        filter: ModelFilter(include: [ModelSelector(model: "raw", provider: "codex")])
    )
    #expect(summary.totalTokens == 32)
    #expect(summary.duplicatesDropped == 2)
    #expect(summary.models.first?.model == "target")
    #expect(summary.usage.sessions == 1)
    #expect(summary.trend.reduce(0) { $0 + $1.tokens } == 32)
    #expect(Aggregation.aliases(["x": "y", "y": "x", "a": "b", "b": "c"]) == ["a": "c", "b": "c"])
}

@Test func dayWindowUsesLocalMidnight() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let formatter = ISO8601DateFormatter()
    let date = try #require(formatter.date(from: "2026-03-08T18:00:00Z"))
    let window = UsageWindow(days: 1, now: date, calendar: calendar)
    #expect(formatter.string(from: window.start) == "2026-03-08T08:00:00Z")
    #expect(formatter.string(from: window.end) == "2026-03-09T07:00:00Z")
    #expect(window.buckets.count == 23)
    #expect(window.contains(window.start.milliseconds))
    #expect(!window.contains(window.end.milliseconds))
}

@Test func resolvesDefaultConfiguredAndEnvironmentHomes() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let settings = home.appending(path: ".t3/userdata/settings.json")
    try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("""
        {"providerInstances":{
          "configured":{"driver":"claude","config":{"homePath":"~/configured"}},
          "env":{"driver":"codex","environment":[{"name":"CODEX_HOME","value":"~/instance"}]}
        },"usageModelAliases":{"model-a":"model-b"},"usageModelFilter":{"include":[]}}
        """.utf8).write(to: settings)
    let roots = LocalSources(home: home, environment: ["CLAUDE_CONFIG_DIR": "~/global"])
    let base = settings.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
    #expect(Set(roots.roots(.claude)) == Set(["configured/projects", ".claude/projects", "global/projects"]
        .map { base.appending(path: $0).path }))
    #expect(Set(roots.roots(.codex)) == Set(["instance/sessions", ".codex/sessions"].map { base.appending(path: $0).path }))
    #expect(roots.aliases == ["model-a": "model-b"])
    #expect(roots.filter?.include?.isEmpty == true)
}

@Test func tokiIndependentConfigOverridesT3AndResolvesCustomSources() async throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }

    // T3 settings (lower priority fallback)
    let t3Settings = home.appending(path: ".t3/userdata/settings.json")
    try FileManager.default.createDirectory(at: t3Settings.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("""
        {
          "usageModelAliases": {"shared": "from-t3", "only-t3": "kept-t3"},
          "usagePriceOverrides": {
            "custom-model": {"inputCostPerMillionTokens": 1.0, "outputCostPerMillionTokens": 2.0}
          },
          "usageModelFilter": {"exclude": [{"model": "blocked-by-t3"}]}
        }
        """.utf8).write(to: t3Settings)

    // Toki independent config (~/.config/toki/config.json, higher priority)
    let tokiConfig = home.appending(path: ".config/toki/config.json")
    try FileManager.default.createDirectory(at: tokiConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("""
        {
          "modelAliases": {"shared": "from-toki", "raw-claude": "custom-model"},
          "priceOverrides": {
            "custom-model": {"inputCostPerMillionTokens": 10.0, "outputCostPerMillionTokens": 20.0}
          },
          "modelFilter": {"exclude": [{"model": "skip-me"}]},
          "sources": {
            "claude": ["~/work-claude", "~/direct-claude/projects"],
            "codex": "~/work-codex",
            "opencode": ["~/custom-opencode"]
          }
        }
        """.utf8).write(to: tokiConfig)

    let sources = LocalSources(home: home, environment: [:])
    let resolvedHome = home.resolvingSymlinksInPath()
    #expect(sources.aliases == ["shared": "from-toki", "only-t3": "kept-t3", "raw-claude": "custom-model"])
    #expect(sources.filter?.exclude?.map(\.model) == ["skip-me"])
    #expect(sources.roots(.claude).contains(resolvedHome.appending(path: "work-claude/projects").path))
    #expect(sources.roots(.claude).contains(resolvedHome.appending(path: "direct-claude/projects").path))
    #expect(sources.roots(.codex).contains(resolvedHome.appending(path: "work-codex/sessions").path))
    #expect(sources.roots(.opencode).contains(resolvedHome.appending(path: "custom-opencode").path))

    // End-to-end UsageEngine test reading from Toki custom source + applying Toki alias, filter & price override
    let projectsDir = home.appending(path: "work-claude/projects/demo")
    try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
    let now = Date(milliseconds: try #require(TimestampParser().parse("2026-11-26T12:00:00Z")))
    let transcript = """
        {"type":"assistant","sessionId":"s1","timestamp":"2026-11-26T11:30:00Z","requestId":"r1","message":{"id":"m1","model":"raw-claude","usage":{"input_tokens":1000000,"output_tokens":500000}}}
        {"type":"assistant","sessionId":"s1","timestamp":"2026-11-26T11:31:00Z","requestId":"r2","message":{"id":"m2","model":"skip-me","usage":{"input_tokens":999999,"output_tokens":999999}}}
        """
    try Data(transcript.utf8).write(to: projectsDir.appending(path: "session.jsonl"))

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let engine = UsageEngine(home: home, environment: [:], cacheDirectory: home.appending(path: "cache"))
    let summaries = await engine.refresh(days: [1], providers: [.claude], now: now, calendar: calendar, fetchRates: false)
    let summary = try #require(summaries.first)
    #expect(summary.totalTokens == 1_500_000)
    #expect(summary.models.map(\.model) == ["custom-model"])
    // 1M input * $10 + 0.5M output * $20 = $20.0 (Toki override wins over T3's $1/$2)
    #expect(abs(summary.usage.costUsd - 20.0) < 0.0001)
    let activeTrend = summary.trend.filter { $0.tokens > 0 }
    #expect(activeTrend.count == 1)
    #expect(activeTrend.first?.requests == 1)
    #expect(abs((activeTrend.first?.costUsd ?? 0) - 20.0) < 0.0001)
}

@Test func readDatabaseReadsClosedWalDatabaseWithoutSidecars() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "wal-closed.db").path
    try createDatabase(path, sql: """
        PRAGMA journal_mode = WAL;
        CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT);
        INSERT INTO items VALUES (1, 'ok');
        PRAGMA wal_checkpoint(TRUNCATE);
        """)
    try? FileManager.default.removeItem(atPath: path + "-wal")
    try? FileManager.default.removeItem(atPath: path + "-shm")
    let db = try ReadDatabase(path)
    var names: [String] = []
    try db.rows("SELECT name FROM items") { row in
        names.append(ReadDatabase.string(row, 0))
    }
    #expect(names == ["ok"])
    #expect(!FileManager.default.fileExists(atPath: path + "-shm"))
}
