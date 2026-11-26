import Foundation

enum Claude {
    static func parse(_ value: JSONObject, timestamps: TimestampParser) -> [UsageRecord] {
        guard text(value["type"]) == "assistant",
              let timestamp = timestamps.parse(value["timestamp"]) else { return [] }
        let message = object(value["message"])
        let model = text(message["model"])
        guard !model.isEmpty, model != "<synthetic>", let usage = message["usage"] as? JSONObject else { return [] }
        let messageId = message["id"] as? String
        let requestId = value["requestId"] as? String
        let key = messageId == nil && requestId == nil ? nil : "\(messageId ?? ""):\(requestId ?? "")"
        let speed: UsageSpeed = text(usage["speed"]) == "fast" ? .fast : .standard
        let session = text(value["sessionId"])

        func record(_ usage: JSONObject, model: String, key: String?, cost: Double?) -> UsageRecord {
            UsageRecord(
                provider: .claude, timestampMs: timestamp, model: model, sessionId: session,
                totals: Tokens(
                    uncachedInputTokens: count(usage["input_tokens"]),
                    cachedInputTokens: count(usage["cache_read_input_tokens"]),
                    cacheCreationTokens: count(usage["cache_creation_input_tokens"]),
                    outputTokens: count(usage["output_tokens"])
                ),
                cacheCreation1hTokens: count(object(usage["cache_creation"])["ephemeral_1h_input_tokens"]),
                reportedCostUsd: cost, speed: speed, dedupeKey: key
            )
        }

        return [record(usage, model: model, key: key, cost: number(value["costUSD"]))]
            + (usage["iterations"] as? [Any] ?? []).enumerated().compactMap { index, iteration in
                let advisor = object(iteration)
                let advisorModel = text(advisor["model"])
                guard text(advisor["type"]) == "advisor_message", !advisorModel.isEmpty,
                      advisorModel != "<synthetic>" else { return nil }
                return record(advisor, model: advisorModel, key: key.map { "\($0):advisor:\(index)" }, cost: nil)
            }
    }
}
