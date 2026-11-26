import Foundation

struct LocalSources {
    let home: URL
    let environment: [String: String]
    let t3: URL
    let tokiConfigFile: URL
    var t3Settings: JSONObject
    var tokiConfig: JSONObject

    init(home: URL, environment: [String: String]) {
        self.home = home
        self.environment = environment
        self.t3 = URL(fileURLWithPath: environment["T3CODE_HOME"] ?? home.appending(path: ".t3").path)
            .appending(path: "userdata")
        let explicitConfig = trimmed(environment["TOKI_CONFIG_PATH"] ?? "")
        let xdgConfig = trimmed(environment["XDG_CONFIG_HOME"] ?? "")
        if !explicitConfig.isEmpty {
            let expanded = Self.expandPath(explicitConfig, home: home)
            self.tokiConfigFile = URL(fileURLWithPath: expanded)
        } else if xdgConfig.hasPrefix("/") {
            self.tokiConfigFile = URL(fileURLWithPath: xdgConfig).appending(path: "toki/config.json")
        } else {
            self.tokiConfigFile = home.appending(path: ".config/toki/config.json")
        }
        t3Settings = (try? Data(contentsOf: t3.appending(path: "settings.json"))).flatMap(json) ?? [:]
        tokiConfig = (try? Data(contentsOf: tokiConfigFile)).flatMap(json) ?? [:]
    }

    var aliases: [String: String] {
        var merged = t3Settings["usageModelAliases"] as? [String: String] ?? [:]
        if let legacy = tokiConfig["usageModelAliases"] as? [String: String] {
            for (key, value) in legacy { merged[key] = value }
        }
        if let own = tokiConfig["modelAliases"] as? [String: String] {
            for (key, value) in own { merged[key] = value }
        }
        return merged
    }

    var filter: ModelFilter? {
        if let raw = tokiConfig["modelFilter"] ?? tokiConfig["usageModelFilter"],
           let data = try? JSONSerialization.data(withJSONObject: raw),
           let decoded = try? JSONDecoder().decode(ModelFilter.self, from: data) {
            return decoded
        }
        guard let raw = t3Settings["usageModelFilter"],
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(ModelFilter.self, from: data)
    }

    var priceOverrides: JSONObject {
        var merged = object(t3Settings["usagePriceOverrides"])
        for (model, raw) in object(tokiConfig["usagePriceOverrides"]) {
            merged[model] = raw
        }
        for (model, raw) in object(tokiConfig["priceOverrides"]) {
            merged[model] = raw
        }
        return merged
    }

    func roots(_ provider: Provider) -> [String] {
        var paths: [String] = []

        // 1. Toki independent config custom source paths (~/.config/toki/config.json)
        let customSources = object(tokiConfig["sources"])
        for rawPath in stringList(customSources[provider.rawValue]) {
            let expanded = expand(rawPath)
            paths.append(normalizeCustomRoot(expanded, for: provider))
        }

        // 2. Compatible T3 settings + standard locations + environment variables
        let instances = object(t3Settings["providerInstances"]).sorted { $0.key < $1.key }.compactMap { _, raw -> JSONObject? in
            let instance = object(raw)
            let driver = text(instance["driver"])
            return driver == provider.rawValue || (provider == .claude && driver == "claudeAgent") ? instance : nil
        }
        for instance in instances + [[:]] {
            let config = object(instance["config"])
            var env = environment
            for variable in instance["environment"] as? [JSONObject] ?? [] {
                let name = text(variable["name"])
                if !name.isEmpty, let value = variable["value"] as? String { env[name] = value }
            }
            let custom = trimmed(text(config["homePath"]))
            let path: (String) -> String = { self.home.appending(path: $0).path }
            switch provider {
            case .claude:
                let preferred = trimmed(env["CLAUDE_CONFIG_DIR"] ?? "")
                let defaults = instance.isEmpty ? [path(".claude"), preferred] : [custom.isEmpty ? preferred : custom]
                paths += defaults.filter { !$0.isEmpty }.map { "\(expand($0))/projects" }
            case .codex:
                let preferred = trimmed(env["CODEX_HOME"] ?? "")
                let defaults = instance.isEmpty ? [path(".codex"), preferred] : [
                    custom.isEmpty && text(config["setupMode"]) != "managed" ? preferred : custom
                ]
                paths += defaults.filter { !$0.isEmpty }.map { "\(expand($0))/sessions" }
            case .antigravity:
                let configured = split(env["ANTIGRAVITY_DATA_DIR"])
                paths += configured.isEmpty ? [
                    ".gemini/antigravity", ".gemini/antigravity-cli", ".gemini/antigravity-ide",
                    ".gemini/antigravity-backup", ".config/antigravity"
                ].map(path) : configured
                if !custom.isEmpty { paths.append(custom) }
            case .opencode:
                let configured = split(env["OPENCODE_DATA_DIR"])
                let data = trimmed(env["XDG_DATA_HOME"] ?? "")
                paths += configured.isEmpty ? [(data.hasPrefix("/") ? data : path(".local/share")) + "/opencode"] : configured
                if !custom.isEmpty { paths.append(custom) }
            }
        }
        if provider == .antigravity {
            let profiles = t3.appending(path: "providers/antigravity")
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? []).sorted() {
                paths.append(profiles.appending(path: "\(name)/antigravity-acp").path)
            }
            paths = paths.map { candidate in
                let resolved = URL(fileURLWithPath: expand(candidate)).standardizedFileURL.resolvingSymlinksInPath().path
                let nested = resolved + "/conversations"
                var isDir = ObjCBool(false)
                if FileManager.default.fileExists(atPath: nested, isDirectory: &isDir), isDir.boolValue {
                    return nested
                }
                return resolved
            }
        }
        var seen: Set<String> = []
        return paths.map { URL(fileURLWithPath: expand($0)).standardizedFileURL.resolvingSymlinksInPath().path }
            .filter { seen.insert($0).inserted }
    }

    private func normalizeCustomRoot(_ path: String, for provider: Provider) -> String {
        let clean = URL(fileURLWithPath: path).standardizedFileURL.path
        switch provider {
        case .claude:
            return clean.hasSuffix("/projects") ? clean : "\(clean)/projects"
        case .codex:
            return clean.hasSuffix("/sessions") ? clean : "\(clean)/sessions"
        case .antigravity, .opencode:
            return clean
        }
    }

    private func stringList(_ raw: Any?) -> [String] {
        if let single = raw as? String {
            let value = trimmed(single)
            return value.isEmpty ? [] : [value]
        }
        if let array = raw as? [Any] {
            return array.compactMap { $0 as? String }.map(trimmed).filter { !$0.isEmpty }
        }
        return []
    }

    private func expand(_ path: String) -> String {
        Self.expandPath(path, home: home)
    }

    private static func expandPath(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") || path.hasPrefix("~\\") { return home.appending(path: String(path.dropFirst(2))).path }
        return path
    }

    private func split(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",").map { trimmed(String($0)) }.filter { !$0.isEmpty }
    }
}

enum LocalTierHistory {
    static func resolve(_ files: inout [UsageFile], path: String, since: Int64) {
        let turns = Set(files.flatMap { file in
            file.records.compactMap { $0.timestampMs >= since ? $0.unresolvedTurnId : nil }
        })
        guard !turns.isEmpty, let database = try? ReadDatabase(path),
              let encoded = try? JSONEncoder().encode(Array(turns)) else { return }
        struct Selection {
            let session: String
            let model: String
            let speed: UsageSpeed?
        }
        var selections: [String: Selection] = [:]
        var seen: Set<String> = []
        do {
            try database.rows("""
                SELECT json_extract(attempt.payload_json, '$.nativeThreadId'),
                  json_extract(turn.payload_json, '$.nativeTurnRef.nativeId'),
                  (SELECT json_extract(event.payload_json, '$.modelSelection')
                   FROM orchestration_events AS event
                   WHERE event.aggregate_kind = 'thread' AND event.application_event_version = 2
                     AND event.stream_id = attempt.thread_id AND event.event_type = 'run.updated'
                     AND json_extract(event.payload_json, '$.id') = attempt.run_id
                     AND json_extract(event.payload_json, '$.activeAttemptId') = attempt.attempt_id
                     AND json_extract(event.payload_json, '$.status') = 'running'
                   ORDER BY event.sequence LIMIT 1)
                FROM orchestration_v2_projection_provider_turns AS turn
                LEFT JOIN orchestration_v2_projection_run_attempts AS attempt
                  ON attempt.attempt_id = turn.run_attempt_id AND attempt.thread_id = turn.thread_id
                  AND attempt.provider_thread_id = turn.provider_thread_id
                WHERE json_extract(turn.payload_json, '$.nativeTurnRef.driver') = 'codex'
                  AND json_extract(turn.payload_json, '$.nativeTurnRef.nativeId') IN (SELECT value FROM json_each(?))
                """, binds: [String(decoding: encoded, as: UTF8.self)]) { row in
                let turn = ReadDatabase.string(row, 1)
                guard seen.insert(turn).inserted else { selections[turn] = nil; return }
                guard let value = json(Data(ReadDatabase.string(row, 2).utf8)) else { return }
                let option = (value["options"] as? [JSONObject] ?? []).first { text($0["id"]) == "serviceTier" }
                if let option, !(option["value"] is String) { return }
                let tier = text(option?["value"])
                guard ["", "default", "standard", "fast", "priority", "ultrafast"].contains(tier) else { return }
                selections[turn] = Selection(session: ReadDatabase.string(row, 0), model: text(value["model"]),
                                             speed: CodexState.tier(tier))
            }
        } catch { return }
        for fileIndex in files.indices {
            for index in files[fileIndex].records.indices {
                let record = files[fileIndex].records[index]
                guard let turn = record.unresolvedTurnId, let selection = selections[turn],
                      selection.session == record.sessionId, selection.model == record.model,
                      let speed = selection.speed else { continue }
                files[fileIndex].records[index].speed = speed
            }
        }
    }
}
