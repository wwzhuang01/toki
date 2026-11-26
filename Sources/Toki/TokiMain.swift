import AppKit
import Foundation
import TokiCore

@main
struct TokiMain {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--dump-json") {
            let days: Int
            switch arguments {
            case ["--dump-json"]: days = 1
            case ["--dump-json", "--days", "1"]: days = 1
            case ["--dump-json", "--days", "7"]: days = 7
            case ["--dump-json", "--days", "30"]: days = 30
            default:
                FileHandle.standardError.write(Data("Usage: Toki --dump-json [--days 1|7|30]\n".utf8))
                exit(64)
            }
            let diagnosticHome = ProcessInfo.processInfo.environment["TOKI_DATA_HOME"]
            let engine = diagnosticHome.map { UsageEngine(home: URL(fileURLWithPath: $0)) } ?? UsageEngine()
            guard let summary = await engine.refresh(days: [days]).first else { exit(1) }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            do {
                let data = try encoder.encode(summary)
                FileHandle.standardOutput.write(data + Data([0x0A]))
            } catch {
                FileHandle.standardError.write(Data("Could not encode usage: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        runApp()
    }

    @MainActor
    private static func runApp() {
        let application = NSApplication.shared
        let delegate = TokiDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}
