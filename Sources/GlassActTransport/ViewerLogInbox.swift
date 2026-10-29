public import Foundation

/// Stores VIEWER_LOG uploads (§3.5) in the Host's `from-viewer` folder
/// (~/Library/Logs/Glass Act/from-viewer/<name>). Chunks must arrive in order
/// (the stream is reliable and ordered); a gap or overrun drops the rest of
/// that file. Names are already validated by the parser (bare, safe
/// characters). Own queue: file I/O stays off the engine's.
///
/// Bounded, since any approved viewer can send (§13):
/// - one upload open at a time (a Viewer sends its files one after another):
///   starting another closes the one before;
/// - the folder keeps at most `maxFiles` files and `maxBytes` bytes, the
///   oldest removed to make room for a new upload's announced size;
/// - a write that fails (a full disk) drops that file, and `endSession`
///   closes whatever is still open.
public final class ViewerLogInbox: @unchecked Sendable {
    public static let maxFiles = 100
    public static let maxBytes = 128 << 20

    public let directory: URL
    private let queue = DispatchQueue(label: "glassact.host.viewer-logs")
    private var open: (name: String, handle: FileHandle, written: Int)?

    public init(directory: URL) {
        self.directory = directory
    }

    public func receive(name: String, offset: Int, total: Int, data: [UInt8],
                        status: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            let url = directory.appendingPathComponent(name)
            if offset == 0 {
                closeOpen()
                guard total <= Self.maxBytes else {
                    status("viewer log \(name): \(total / 1024) KB is over the folder's limit — dropped")
                    return
                }
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                makeRoom(for: total, replacing: name)
                guard FileManager.default.createFile(atPath: url.path, contents: nil),
                      let h = try? FileHandle(forWritingTo: url) else {
                    status("viewer log \(name): can't write \(url.path)")
                    return
                }
                open = (name, h, 0)
            }
            guard let current = open, current.name == name, current.written == offset,
                  offset + data.count <= total else {
                if open?.name == name { status("viewer log \(name): out-of-order chunk at \(offset) — dropped") }
                if open?.name == name { closeOpen() }
                return
            }
            do {
                try current.handle.write(contentsOf: data)
            } catch {
                status("viewer log \(name): couldn't write (\(error.localizedDescription)) — dropped")
                closeOpen()
                return
            }
            let now = offset + data.count
            open?.written = now
            if now >= total {
                closeOpen()
                status("received viewer log \(name) (\(total / 1024) KB) → \(url.path)")
            }
        }
    }

    /// The session ended: close an upload it left unfinished.
    public func endSession() {
        queue.async { [self] in closeOpen() }
    }

    /// Waits for the queued work (tests).
    func sync() { queue.sync {} }

    /// The upload still open, if any (tests).
    var openUpload: String? { queue.sync { open?.name } }

    private func closeOpen() {
        try? open?.handle.close()
        open = nil
    }

    /// Removes the oldest files until one more of `size` bytes fits. A file
    /// of the same name is about to be replaced, so it doesn't count.
    private func makeRoom(for size: Int, replacing name: String) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var files = urls.compactMap { url -> (url: URL, date: Date, size: Int)? in
            guard url.lastPathComponent != name,
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return (url, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
        }
        files.sort { $0.date < $1.date }
        var count = files.count, bytes = files.reduce(0) { $0 + $1.size }
        for file in files where count + 1 > Self.maxFiles || bytes + size > Self.maxBytes {
            try? fm.removeItem(at: file.url)
            count -= 1
            bytes -= file.size
        }
    }
}
