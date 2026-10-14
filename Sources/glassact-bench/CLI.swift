// Command-line layer: per-command flag declarations, a validating parser,
// generated usage text, and the error types main.swift's single top-level
// catch reports. Every command declares exactly the flags it reads; anything
// else on its command line — an unknown flag, another command's flag, a
// missing or unparseable value — is a usage error before any trace is opened.
import Foundation

/// Every subcommand, in usage order.
let allCommands: [Command] = [
    synthCommand,
    replayCommand,
    codecsCommand,
    keyframeCommand,
    dragScanCommand,
    dumpPNGCommand,
    dumpTilesCommand,
    y4mCommand,
    videoQualityCommand,
]

// MARK: - Errors

/// A runtime failure (unreadable trace, I/O, a failed golden check).
/// Reported as `glassact-bench: error: <message>`, exit 1.
struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

/// A bad command line. Reported with the command's usage, exit 2.
struct UsageError: Error {
    let message: String
    let command: Command?
}

// MARK: - Flag and command declarations

struct Flag: Sendable {
    enum Kind: Sendable {
        case bool
        case string(placeholder: String)
        case int(placeholder: String, range: ClosedRange<Int>)
        case choice([String])
        /// Comma-separated integers; `count` 0 = one or more.
        case ints(placeholder: String, count: Int)
        /// `lo-hi`, 0 ≤ lo ≤ hi.
        case span(placeholder: String)
    }

    let name: String
    let kind: Kind
    let required: Bool
    let help: String

    static func bool(_ name: String, _ help: String) -> Flag {
        Flag(name: name, kind: .bool, required: false, help: help)
    }

    static func string(_ name: String, _ placeholder: String, required: Bool = false, _ help: String) -> Flag {
        Flag(name: name, kind: .string(placeholder: placeholder), required: required, help: help)
    }

    static func int(_ name: String, _ placeholder: String, _ range: ClosedRange<Int>, _ help: String) -> Flag {
        Flag(name: name, kind: .int(placeholder: placeholder, range: range), required: false, help: help)
    }

    static func choice(_ name: String, _ choices: [String], _ help: String) -> Flag {
        Flag(name: name, kind: .choice(choices), required: false, help: help)
    }

    static func ints(_ name: String, _ placeholder: String, count: Int, required: Bool = false, _ help: String) -> Flag {
        Flag(name: name, kind: .ints(placeholder: placeholder, count: count), required: required, help: help)
    }

    static func span(_ name: String, _ placeholder: String, _ help: String) -> Flag {
        Flag(name: name, kind: .span(placeholder: placeholder), required: false, help: help)
    }

    /// `--trace <file.scap>`, required — shared by every trace-reading command.
    static let trace = Flag.string("trace", "<file.scap>", required: true, "trace to read")

    var placeholder: String? {
        switch kind {
        case .bool: nil
        case let .string(p), let .int(p, _), let .ints(p, _), let .span(p): p
        case let .choice(choices): choices.joined(separator: "|")
        }
    }

    var synopsis: String {
        let text = "--\(name)" + (placeholder.map { " \($0)" } ?? "")
        return required ? text : "[\(text)]"
    }
}

struct Command: Sendable {
    let name: String
    let summary: String
    let flags: [Flag]
    /// Extra usage text (modes, caveats), printed after the flag table.
    var notes: String = ""
    /// Cross-flag checks run after parsing (e.g. flags valid in one mode only).
    var validate: (@Sendable (Options) throws -> Void)?
    let run: @Sendable (Options) throws -> Void

    func flag(named name: String) -> Flag? { flags.first { $0.name == name } }

    var usage: String {
        // Synopsis, wrapped at ~96 columns with a hanging indent.
        let lead = "usage: glassact-bench \(name)"
        var text = lead
        var column = lead.count
        for flag in flags {
            let word = flag.synopsis
            if column + 1 + word.count > 96 {
                text += "\n" + String(repeating: " ", count: lead.count)
                column = lead.count
            }
            text += " " + word
            column += 1 + word.count
        }
        text += "\n\n  \(summary)\n"
        if !flags.isEmpty {
            text += "\n"
            let labels = flags.map { "--\($0.name)" + ($0.placeholder.map { " \($0)" } ?? "") }
            let width = min(28, labels.map(\.count).max() ?? 0)
            for (label, flag) in zip(labels, flags) {
                let help = flag.required ? "\(flag.help) (required)" : flag.help
                if label.count > width {
                    text += "  \(label)\n  \(pad("", width))  \(help)\n"
                } else {
                    text += "  \(pad(label, width))  \(help)\n"
                }
            }
        }
        if !notes.isEmpty { text += "\n" + notes + "\n" }
        return text
    }
}

// MARK: - Parsed options

struct Options {
    enum Value {
        case bool
        case string(String)
        case int(Int)
        case ints([Int])
        case span(Int, Int)
    }

    let command: Command
    private var values: [String: Value] = [:]

    init(_ args: [String], for command: Command) throws {
        self.command = command
        var i = 0
        while i < args.count {
            let arg = args[i]
            guard arg.hasPrefix("--"), arg.count > 2 else {
                throw UsageError(message: "unexpected argument '\(arg)'", command: command)
            }
            let name = String(arg.dropFirst(2))
            guard let flag = command.flag(named: name) else {
                throw UsageError(message: Self.unknownFlagMessage(name, command), command: command)
            }
            guard values[name] == nil else {
                throw UsageError(message: "--\(name) given more than once", command: command)
            }
            if case .bool = flag.kind {
                values[name] = .bool
                i += 1
                continue
            }
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                throw UsageError(message: "--\(name) requires a value (\(flag.placeholder ?? "value"))",
                                 command: command)
            }
            values[name] = try Self.parse(args[i + 1], as: flag, command: command)
            i += 2
        }
        for flag in command.flags where flag.required && values[flag.name] == nil {
            throw UsageError(message: "missing required flag --\(flag.name) \(flag.placeholder ?? "")",
                             command: command)
        }
        try command.validate?(self)
    }

    private static func unknownFlagMessage(_ name: String, _ command: Command) -> String {
        if allCommands.contains(where: { $0.flag(named: name) != nil }) {
            return "--\(name) is not a flag of '\(command.name)'"
        }
        var message = "unknown flag --\(name)"
        let close = command.flags.map { ($0.name, editDistance($0.name, name)) }
            .filter { $0.1 <= 2 }
            .min { $0.1 < $1.1 }
        if let (suggestion, _) = close { message += " (did you mean --\(suggestion)?)" }
        return message
    }

    private static func parse(_ raw: String, as flag: Flag, command: Command) throws -> Value {
        func bad(_ expected: String) -> UsageError {
            UsageError(message: "--\(flag.name) expects \(expected), got '\(raw)'", command: command)
        }
        switch flag.kind {
        case .bool:
            preconditionFailure("bool flags take no value")
        case .string:
            return .string(raw)
        case let .int(_, range):
            guard let v = Int(raw) else { throw bad("an integer") }
            guard range.contains(v) else {
                throw bad(range.upperBound == Int.max
                    ? "an integer ≥ \(range.lowerBound)"
                    : "an integer in \(range.lowerBound)...\(range.upperBound)")
            }
            return .int(v)
        case let .choice(choices):
            guard choices.contains(raw) else { throw bad("one of " + choices.joined(separator: "|")) }
            return .string(raw)
        case let .ints(placeholder, count):
            let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
            let ints = parts.compactMap { Int($0) }
            guard ints.count == parts.count, !ints.isEmpty, count == 0 || ints.count == count else {
                throw bad(placeholder)
            }
            return .ints(ints)
        case let .span(placeholder):
            let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts[1]), lo >= 0, lo <= hi else {
                throw bad(placeholder)
            }
            return .span(lo, hi)
        }
    }

    // MARK: Accessors
    //
    // Reading a flag the command did not declare is a programming error in
    // glassact-bench itself (the declaration is the command's contract), so it
    // traps rather than silently reading nothing.

    private func declared(_ name: String) -> Flag {
        guard let flag = command.flag(named: name) else {
            preconditionFailure("glassact-bench bug: '\(command.name)' reads undeclared flag --\(name)")
        }
        return flag
    }

    func has(_ name: String) -> Bool {
        _ = declared(name)
        return values[name] != nil
    }

    func string(_ name: String) -> String? {
        _ = declared(name)
        guard case let .string(v)? = values[name] else { return nil }
        return v
    }

    /// A flag declared `required`; presence was checked at parse time.
    func required(_ name: String) -> String {
        precondition(declared(name).required, "glassact-bench bug: --\(name) is not declared required")
        guard let v = string(name) else { preconditionFailure("required --\(name) missing after parse") }
        return v
    }

    func int(_ name: String, _ fallback: Int) -> Int {
        _ = declared(name)
        guard case let .int(v)? = values[name] else { return fallback }
        return v
    }

    func ints(_ name: String) -> [Int]? {
        _ = declared(name)
        guard case let .ints(v)? = values[name] else { return nil }
        return v
    }

    func span(_ name: String) -> (lo: Int, hi: Int)? {
        _ = declared(name)
        guard case let .span(lo, hi)? = values[name] else { return nil }
        return (lo, hi)
    }
}

// MARK: - Usage

func globalUsage() -> String {
    let width = allCommands.map(\.name.count).max() ?? 0
    var text = "usage: glassact-bench <command> [flags]\n\ncommands:\n"
    for command in allCommands {
        text += "  \(pad(command.name, width))  \(command.summary)\n"
    }
    text += "\nRun 'glassact-bench <command> --help' for a command's flags.\n"
    return text
}

/// Levenshtein distance, for "did you mean" on misspelled flags.
func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    guard !a.isEmpty else { return b.count }
    guard !b.isEmpty else { return a.count }
    var prev = Array(0...b.count)
    var cur = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        cur[0] = i
        for j in 1...b.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        swap(&prev, &cur)
    }
    return prev[b.count]
}
