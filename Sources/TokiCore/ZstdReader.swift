import Darwin
import Foundation

final class ZstdReader {
    private struct Input {
        let source: UnsafeRawPointer?
        let size: Int
        var position: Int
    }

    private struct Output {
        let destination: UnsafeMutableRawPointer?
        let size: Int
        var position: Int
    }

    private typealias Create = @convention(c) () -> OpaquePointer?
    private typealias Release = @convention(c) (OpaquePointer) -> Int
    private typealias Decompress = @convention(c) (OpaquePointer, UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int
    private typealias IsError = @convention(c) (Int) -> UInt32

    private let library: UnsafeMutableRawPointer
    private let context: OpaquePointer
    private let release: Release
    private let decompress: Decompress
    private let isError: IsError
    private let file: FileHandle
    private var input = Data()
    private var offset = 0
    private var lastHint: Int?

    init?(_ path: String) throws {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Frameworks/libzstd.1.dylib").path
        let candidates = [bundled, "/opt/homebrew/lib/libzstd.1.dylib", "/usr/local/lib/libzstd.1.dylib"]
        guard let library = candidates.lazy.compactMap({ dlopen($0, RTLD_NOW | RTLD_LOCAL) }).first else { return nil }
        guard let createSymbol = dlsym(library, "ZSTD_createDCtx"),
              let releaseSymbol = dlsym(library, "ZSTD_freeDCtx"),
              let decompressSymbol = dlsym(library, "ZSTD_decompressStream"),
              let errorSymbol = dlsym(library, "ZSTD_isError"),
              let context = unsafeBitCast(createSymbol, to: Create.self)() else {
            dlclose(library)
            return nil
        }
        let release = unsafeBitCast(releaseSymbol, to: Release.self)
        do {
            file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            _ = release(context)
            dlclose(library)
            throw error
        }
        self.library = library
        self.context = context
        self.release = release
        decompress = unsafeBitCast(decompressSymbol, to: Decompress.self)
        isError = unsafeBitCast(errorSymbol, to: IsError.self)
    }

    deinit {
        try? file.close()
        _ = release(context)
        dlclose(library)
    }

    func read(upToCount count: Int) throws -> Data? {
        var output = Data(count: count)
        while true {
            if offset == input.count {
                input = try file.read(upToCount: 128 * 1_024) ?? Data()
                offset = 0
            }
            if input.isEmpty && lastHint == 0 { return nil }
            let result = input.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    var incoming = Input(source: source.baseAddress, size: source.count, position: offset)
                    var outgoing = Output(destination: destination.baseAddress, size: destination.count, position: 0)
                    let hint = decompress(context, &outgoing, &incoming)
                    return (hint, incoming.position, outgoing.position)
                }
            }
            guard isError(result.0) == 0 else { throw ReadFailure.decompression }
            lastHint = result.0
            offset = result.1
            if result.2 > 0 {
                output.count = result.2
                return output
            }
            if input.isEmpty {
                guard result.0 == 0 else { throw ReadFailure.decompression }
                return nil
            }
        }
    }
}
