import Foundation
import Testing
@testable import GlassActTransport

/// VIEWER_LOG uploads (§3.5, §13): written in order, bounded on disk, and
/// never left open.
@Suite struct ViewerLogInboxTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)")
    }

    private func send(_ inbox: ViewerLogInbox, _ name: String, bytes: Int, chunk: Int = 64 << 10) {
        var offset = 0
        repeat {
            let n = min(chunk, bytes - offset)
            inbox.receive(name: name, offset: offset, total: bytes, data: [UInt8](repeating: 0x41, count: n)) { _ in }
            offset += n
        } while offset < bytes
    }

    private func files(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    @Test func writesAFileInOrder() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = ViewerLogInbox(directory: dir)
        send(inbox, "viewer-1.log", bytes: 200_000)
        inbox.sync()
        #expect(try Data(contentsOf: dir.appendingPathComponent("viewer-1.log")).count == 200_000)
    }

    /// A chunk past the announced size, or out of order, drops the rest.
    @Test func anOverrunIsDropped() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = ViewerLogInbox(directory: dir)
        inbox.receive(name: "a.log", offset: 0, total: 10, data: Array(repeating: 1, count: 8)) { _ in }
        inbox.receive(name: "a.log", offset: 8, total: 10, data: Array(repeating: 1, count: 8)) { _ in }
        inbox.receive(name: "a.log", offset: 16, total: 10, data: Array(repeating: 1, count: 8)) { _ in }
        inbox.sync()
        #expect(try Data(contentsOf: dir.appendingPathComponent("a.log")).count == 8)
    }

    /// The folder keeps the newest `maxFiles`: an endless stream of names
    /// can't fill the disk or the folder.
    @Test func theFolderKeepsAtMostMaxFiles() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = ViewerLogInbox(directory: dir)
        for i in 0..<(ViewerLogInbox.maxFiles + 20) { send(inbox, "f\(i).log", bytes: 10) }
        inbox.sync()
        let names = files(dir)
        #expect(names.count == ViewerLogInbox.maxFiles)
        #expect(names.contains("f\(ViewerLogInbox.maxFiles + 19).log"), "the newest stays")
    }

    @Test func theFolderKeepsAtMostMaxBytes() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = ViewerLogInbox(directory: dir)
        let size = 16 << 20
        for i in 0..<10 { send(inbox, "big\(i).log", bytes: size, chunk: 1 << 20) }
        inbox.sync()
        let total = try files(dir).reduce(0) { sum, name in
            sum + (try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? Int ?? 0)
        }
        #expect(total <= ViewerLogInbox.maxBytes)
        #expect(files(dir).contains("big9.log"))
    }

    /// Starting a second upload closes the first: only one file is open at
    /// a time, however many a viewer starts and abandons.
    @Test func oneUploadIsOpenAtATime() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = ViewerLogInbox(directory: dir)
        for i in 0..<50 {
            inbox.receive(name: "half\(i).log", offset: 0, total: 1000, data: [1, 2, 3]) { _ in }
        }
        #expect(inbox.openUpload == "half49.log")
        // A chunk for an abandoned upload goes nowhere.
        inbox.receive(name: "half0.log", offset: 3, total: 1000, data: [4]) { _ in }
        inbox.sync()
        #expect(try Data(contentsOf: dir.appendingPathComponent("half0.log")).count == 3)
        #expect(inbox.openUpload == "half49.log")
        inbox.endSession()
        #expect(inbox.openUpload == nil)
    }
}
