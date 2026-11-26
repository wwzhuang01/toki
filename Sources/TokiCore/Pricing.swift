import Foundation

struct Pricing {
    typealias RateTable = [String: ModelRate]

    struct TokenRates: Equatable {
        let input: Double
        let output: Double
        let read: Double
        let write: Double
        let write1h: Double

        func scaled(_ scale: Double) -> Self {
            Self(input: input * scale, output: output * scale, read: read * scale,
                 write: write * scale, write1h: write1h * scale)
        }

        func cost(_ record: UsageRecord) -> Double {
            let tokens = record.totals
            let long = min(tokens.cacheCreationTokens, record.cacheCreation1hTokens)
            return Double(tokens.uncachedInputTokens) * input + Double(tokens.outputTokens) * output
                + Double(tokens.cachedInputTokens) * read + Double(tokens.cacheCreationTokens - long) * write
                + Double(long) * write1h
        }
    }

    struct SpeedRates {
        let standard: TokenRates
        let fast: TokenRates?
        let ultrafast: TokenRates?

        func tier(_ speed: UsageSpeed) -> TokenRates? {
            switch speed {
            case .standard: standard
            case .fast: fast
            case .ultrafast: ultrafast
            }
        }

        func merging(_ other: Self) -> Self? {
            let chosenFast = fast ?? other.fast
            let chosenUltra = ultrafast ?? other.ultrafast
            guard standard == other.standard, chosenFast == (other.fast ?? chosenFast),
                  chosenUltra == (other.ultrafast ?? chosenUltra) else { return nil }
            return Self(standard: standard, fast: chosenFast, ultrafast: chosenUltra)
        }
    }

    struct ModelRate {
        let base: SpeedRates
        var tiers: [(threshold: Int64, rate: SpeedRates)] = []

        func rates(_ speed: UsageSpeed, _ prompt: Int64) -> TokenRates {
            let tier = tiers.first { prompt > $0.threshold }?.rate
            return tier?.tier(speed) ?? base.tier(speed) ?? tier?.standard ?? base.standard
        }

        func merging(_ other: Self) -> Self? {
            guard let base = base.merging(other.base) else { return nil }
            if tiers.isEmpty || other.tiers.isEmpty {
                return Self(base: base, tiers: tiers.isEmpty ? other.tiers : tiers)
            }
            guard tiers.count == other.tiers.count else { return nil }
            var merged: [(Int64, SpeedRates)] = []
            for (left, right) in zip(tiers, other.tiers) {
                guard left.threshold == right.threshold, let rate = left.rate.merging(right.rate) else { return nil }
                merged.append((left.threshold, rate))
            }
            return Self(base: base, tiers: merged)
        }
    }

    struct Result {
        let cost: Double?
        let savings: Double
    }

    var table: RateTable = [:]
    var overrides: RateTable = [:]

    static func parse(_ document: JSONObject) -> RateTable {
        let tiersPattern = #"^input_cost_per_token_above_(\d{1,7})k_tokens(?:_priority|_ultrafast)?$"#
        let expression = try? NSRegularExpression(pattern: tiersPattern)
        var table: RateTable = [:]
        for (name, raw) in document {
            let entry = object(raw)
            let key = trimmed(name).lowercased()
            guard !key.isEmpty, let standard = tokenRates(entry, suffix: "") else { continue }
            var thresholds: Set<Int64> = []
            for field in entry.keys {
                guard let match = expression?.firstMatch(in: field, range: NSRange(field.startIndex..., in: field)),
                      let range = Range(match.range(at: 1), in: field),
                      let threshold = Int64(field[range]) else { continue }
                thresholds.insert(threshold)
            }
            let tiers = thresholds.sorted(by: >).map { threshold in
                let suffix = "_above_\(threshold)k_tokens"
                let tier = tokenRates(entry, suffix: suffix, base: standard, output: standard.output) ?? standard
                return (threshold * 1_000, speedRates(entry, tier, suffix))
            }
            table[key] = ModelRate(base: speedRates(entry, standard, ""), tiers: tiers)
        }
        let firstParty: Set<String> = ["anthropic", "deepseek", "gemini", "meta", "mistral", "openai", "xai"]
        var aliases: [String: (rate: ModelRate?, first: Bool)] = [:]
        for (key, rate) in table {
            let fragments = key.split(separator: "/", omittingEmptySubsequences: false)
            let alias = fragments.count > 1 ? String(fragments.last ?? "") : key.hasPrefix("anthropic.")
                ? String(key.dropFirst("anthropic.".count)) : key
            guard !alias.isEmpty, key != alias, table[alias] == nil else { continue }
            let first = fragments.count > 1 && firstParty.contains(String(fragments[0]))
            if let previous = aliases[alias], !(first && !previous.first) {
                if previous.first == first { aliases[alias] = (previous.rate?.merging(rate), first) }
            } else {
                aliases[alias] = (rate, first)
            }
        }
        for (alias, value) in aliases { table[alias] = value.rate }
        return table
    }

    static func parseOverrides(_ document: JSONObject) -> RateTable {
        var table: RateTable = [:]
        for (model, raw) in document {
            let entry = object(raw)
            guard let input = number(entry["inputCostPerMillionTokens"]),
                  let output = number(entry["outputCostPerMillionTokens"]) else { continue }
            let write = number(entry["cacheWriteCostPerMillionTokens"]) ?? input
            let read = number(entry["cacheReadCostPerMillionTokens"]) ?? input
            let rates = TokenRates(input: input, output: output, read: read, write: write, write1h: write).scaled(0.000001)
            table[trimmed(model)] = ModelRate(base: SpeedRates(standard: rates, fast: nil, ultrafast: nil))
        }
        return table
    }

    private static func tokenRates(_ entry: JSONObject, suffix: String, base: TokenRates? = nil,
                                   output: Double? = nil) -> TokenRates? {
        guard let input = number(entry["input_cost_per_token" + suffix]),
              let output = number(entry["output_cost_per_token" + suffix]) ?? output else { return nil }
        func cache(_ key: String, _ property: KeyPath<TokenRates, Double>, _ fallback: Double) -> Double {
            if let value = number(entry[key + suffix]) { return value }
            if let base, base.input > 0 { return base[keyPath: property] / base.input * input }
            return fallback
        }
        let write = cache("cache_creation_input_token_cost", \.write, input)
        return TokenRates(input: input, output: output, read: cache("cache_read_input_token_cost", \.read, input),
                          write: write, write1h: cache("cache_creation_input_token_cost_above_1hr", \.write1h, write))
    }

    private static func speedRates(_ entry: JSONObject, _ standard: TokenRates, _ suffix: String) -> SpeedRates {
        let multiplier = number(object(entry["provider_specific_entry"])["fast"])
        let fast = multiplier.flatMap { $0 > 0 ? standard.scaled($0) : nil }
            ?? tokenRates(entry, suffix: suffix + "_priority", base: standard)
        return SpeedRates(standard: standard, fast: fast,
                          ultrafast: tokenRates(entry, suffix: suffix + "_ultrafast", base: standard))
    }

    func lookup(_ model: String) -> ModelRate? {
        let normalized = trimmed(model).lowercased()
        let key = String(normalized.prefix { $0 != "[" })
        let bare = String(key.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
        guard !["", "<synthetic>", "synthetic", "opus", "sonnet", "haiku", "fable"].contains(bare) else { return nil }
        return table[key]
    }

    func aliased(_ record: UsageRecord, to model: String) -> UsageRecord {
        var result = record
        result.rateModel = record.provider == .antigravity && lookup(model) == nil
            ? Antigravity.rateModel(model) : nil
        result.model = model
        return result
    }

    func price(_ record: UsageRecord) -> Result {
        let override = overrides[trimmed(record.model)]
        let reported = override == nil ? record.reportedCostUsd : nil
        let rate = override ?? record.rateModel.flatMap(lookup) ?? lookup(record.model)
        guard let rate else { return Result(cost: reported, savings: 0) }
        let rates = rate.rates(record.speed, record.totals.input)
        return Result(cost: reported ?? rates.cost(record),
                      savings: Double(record.totals.cachedInputTokens) * (rates.input - rates.read))
    }
}
