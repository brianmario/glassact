// glassact-bench — trace replay, stats, golden divergence, loss sim (§7).
//
// Thin dispatcher. Each subcommand lives in its own file and declares the
// flags it accepts (CLI.swift validates them before the command runs); every
// error — bad command line, unreadable trace, failed golden check — surfaces
// here, once, as `glassact-bench: error: …`.
import Foundation
import GlassActCore

func printError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

func errorMessage(_ error: any Error) -> String {
    switch error {
    case let e as BenchError: e.description
    case let e as ScapError: "trace error: \(describe(e))"
    case let e as CocoaError: e.localizedDescription
    default: String(describing: error)
    }
}

func runBench(_ argv: [String]) throws {
    guard let name = argv.first else {
        throw UsageError(message: "missing command", command: nil)
    }
    if ["help", "--help", "-h"].contains(name) {
        let topic = argv.dropFirst().first.flatMap { topic in allCommands.first { $0.name == topic } }
        print(topic?.usage ?? globalUsage(), terminator: "")
        return
    }
    guard let command = allCommands.first(where: { $0.name == name }) else {
        throw UsageError(message: "unknown command '\(name)'", command: nil)
    }
    let args = Array(argv.dropFirst())
    if args.contains("--help") {
        print(command.usage, terminator: "")
        return
    }
    try command.run(try Options(args, for: command))
}

do {
    try runBench(Array(CommandLine.arguments.dropFirst()))
} catch let error as UsageError {
    printError("glassact-bench: error: \(error.message)\n\n" + (error.command?.usage ?? globalUsage()))
    exit(2)
} catch {
    printError("glassact-bench: error: \(errorMessage(error))\n")
    exit(1)
}
