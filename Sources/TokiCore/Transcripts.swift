import Darwin
import Foundation

struct FileStamp: Codable, Equatable {
    let size: UInt64
    let mtimeMs: Int64
    let inode: UInt64
    let device: Int32
    let changed: Int64

    init?(_ path: String) {
        var info = stat()
        guard stat(path, &info) == 0, info.st_size >= 0 else { return nil }
        size = UInt64(info.st_size)
        mtimeMs = Int64(info.st_mtimespec.tv_sec) * 1_000 + Int64(info.st_mtimespec.tv_nsec) / 1_000_000
        inode = info.st_ino
        device = info.st_dev
        changed = Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec)
    }

    var fingerprint: String { "\(device):\(inode):\(size):\(mtimeMs):\(changed)" }
}

struct TranscriptEntry: Codable {
    var provider: Provider
    var stamp: FileStamp
    var byteOffset: UInt64 = 0
    var tailState = CodexState()
    var records: [UsageRecord] = []
    var tailRecords: [UsageRecord] = []
    var tailMalformed: [Int64] = []

    var allRecords: [UsageRecord] { records + tailRecords }
    var malformed: [Int64] { tailState.malformed + tailMalformed }
}

enum Transcripts {
    private static let claudeMarkers = [Data("\"usage\"".utf8)]
    private static let codexMarkers = [
        "token_count", "token_usage_record", "turn_context", "thread_settings_applied", "session_meta"
    ].map { Data("\"\($0)\"".utf8) }

    static func read(_ path: String, provider: Provider, stamp: FileStamp, previous: TranscriptEntry?) throws -> TranscriptEntry {
        if let previous, previous.provider == provider, previous.stamp == stamp { return previous }
        let compressed = path.hasSuffix(".zst")
        let canResume = previous.map {
            !compressed && $0.provider == provider && $0.stamp.inode == stamp.inode
                && $0.stamp.device == stamp.device && $0.stamp.size < stamp.size
        } ?? false
        var entry = canResume ? previous ?? TranscriptEntry(provider: provider, stamp: stamp)
            : TranscriptEntry(provider: provider, stamp: stamp)
        entry.stamp = stamp
        entry.tailRecords = []
        entry.tailMalformed = []
        var state = entry.tailState
        let timestamps = TimestampParser()
        let markers = provider == .claude ? claudeMarkers : codexMarkers
        func parse(_ line: Data, state: inout CodexState) -> [UsageRecord] {
            guard markers.contains(where: { line.range(of: $0) != nil }), let value = json(line) else { return [] }
            return provider == .claude ? Claude.parse(value, timestamps: timestamps) : state.parse(value, timestamps: timestamps)
        }
        let native = compressed ? try ZstdReader(path) : nil
        let fallback = native == nil ? try stream(path, compressed: compressed) : nil
        let file = fallback?.0
        let process = fallback?.1
        defer { try? file?.close() }
        if !compressed { try file?.seek(toOffset: entry.byteOffset) }
        var tail = Data()
        var parsed: [UsageRecord] = []
        do {
            while let chunk = try native?.read(upToCount: 512 * 1_024) ?? file?.read(upToCount: 512 * 1_024), !chunk.isEmpty {
                var start = chunk.startIndex
                while let newline = chunk[start...].firstIndex(of: 0x0A) {
                    let length = newline - start
                    if tail.isEmpty {
                        parsed.append(contentsOf: parse(chunk[start..<newline], state: &state))
                    } else {
                        tail.append(chunk[start..<newline])
                        parsed.append(contentsOf: parse(tail, state: &state))
                    }
                    entry.byteOffset += UInt64((tail.isEmpty ? length : tail.count) + 1)
                    tail.removeAll(keepingCapacity: true)
                    start = newline + 1
                }
                tail.append(chunk[start...])
            }
            if let process {
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw ReadFailure.decompression }
            }
        } catch {
            if let process, process.isRunning { process.terminate() }
            throw error
        }
        entry.tailState = state
        if !tail.isEmpty {
            entry.tailRecords = parse(tail, state: &state)
            entry.tailMalformed = Array(state.malformed.dropFirst(entry.tailState.malformed.count))
        }
        entry.records = Aggregation.dedupeWithinFile(entry.records + parsed)
        return entry
    }

    private static func stream(_ path: String, compressed: Bool) throws -> (FileHandle, Process?) {
        guard compressed else { return (try FileHandle(forReadingFrom: URL(fileURLWithPath: path)), nil) }
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Resources/zstd").path
        let paths = [bundled, "/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/zstd" }
        guard let executable = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw ReadFailure.decompression
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-d", "-q", "-c", "--", path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (output.fileHandleForReading, process)
    }
}
