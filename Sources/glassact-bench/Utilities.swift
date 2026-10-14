// Shared helpers: seeded RNG, formatting, trace opening.
import Foundation
import GlassActCore

struct BenchRNG {
    var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: Range<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
    return sorted[idx]
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func formatBytes(_ n: Int) -> String {
    n >= 1_048_576 ? String(format: "%.2f MB", Double(n) / 1_048_576)
        : n >= 1024 ? String(format: "%.1f KB", Double(n) / 1024)
        : "\(n) B"
}

/// Opens a `.scap` trace, turning a missing path or a bad header into a
/// readable error instead of a bare `ScapError`.
func openTrace(_ path: String) throws -> ScapReader {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
        throw BenchError("no such trace file: \(path)")
    }
    guard !isDirectory.boolValue else { throw BenchError("\(path) is a directory, not a .scap trace") }
    do {
        return try ScapReader(url: URL(fileURLWithPath: path))
    } catch let error as ScapError {
        throw BenchError("cannot read trace \(path): \(describe(error))")
    }
}

func describe(_ error: ScapError) -> String {
    switch error {
    case .ioError: "I/O error"
    case .badMagic: "not a .scap trace (bad magic)"
    case .badHeader: "unsupported or corrupt .scap header"
    case .truncated: "trace is truncated"
    case .badFrame: "corrupt frame"
    }
}
