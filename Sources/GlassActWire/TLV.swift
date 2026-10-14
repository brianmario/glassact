import Foundation

/// A message family carried over a reliable, ordered stream with
/// `{type u8, len varint, body}` framing (§3.5). Conformers provide strict
/// body parsing (INV-6: checked reads, exact consumption) and declare which
/// type bytes are *known* — an unknown type with a valid declared length is
/// skipped (forward compatibility); a known type with an invalid body latches
/// the stream as malformed.
public protocol TLVMessage: Equatable, Sendable {
    static func parseBody(type: UInt8, _ buf: UnsafeRawBufferPointer) -> Self?
    static func isKnownType(_ t: UInt8) -> Bool
    /// Upper bound on a single TLV body (INV-6: no unbounded buffering).
    static var maxBodyLength: UInt32 { get }
}

/// Incremental TLV deframer. Feed arbitrary chunks with `append`, drain events
/// with `next()` until it returns nil.
///
/// A malformed stream latches `isMalformed` and drops all buffered data — the
/// carrying stream is reliable and ordered, so corruption here means a peer
/// bug, never packet damage; the connection should be torn down.
public struct TLVDeframer<M: TLVMessage> {
    public enum Event: Equatable, Sendable {
        case message(M)
        /// A reserved/unknown TLV type was skipped (its declared length was valid).
        case skippedUnknown(type: UInt8)
    }

    /// The carried family's body bound, re-exposed for callers.
    public static var maxBodyLength: UInt32 { M.maxBodyLength }

    private var buffer: [UInt8] = []
    private var readOffset = 0
    public private(set) var isMalformed = false

    public init() {}

    public mutating func append(_ data: some Sequence<UInt8>) {
        guard !isMalformed else { return }
        buffer.append(contentsOf: data)
    }

    private enum Scan {
        case needMore
        case malformed
        case event(Event, nextOffset: Int)
    }

    public mutating func next() -> Event? {
        guard !isMalformed else { return nil }
        let offset = readOffset
        let scan = buffer.withUnsafeBytes { raw -> Scan in
            guard offset < raw.count else { return .needMore }
            let type = unsafe raw[offset]
            // Varint length, distinguishing "truncated so far" from "malformed".
            var lenValue: UInt32 = 0
            var lenSize = 0
            var shift: UInt32 = 0
            while true {
                let i = offset + 1 + lenSize
                guard i < raw.count else { return .needMore }
                let b = unsafe raw[i]
                lenValue |= UInt32(b & 0x7F) &<< shift
                lenSize += 1
                if b & 0x80 == 0 { break }
                if lenSize == 4 { return .malformed }
                shift &+= 7
            }
            guard lenValue <= M.maxBodyLength else { return .malformed }
            let bodyStart = offset + 1 + lenSize
            let bodyLen = Int(lenValue)
            guard raw.count - bodyStart >= bodyLen else { return .needMore }
            let bodyEnd = bodyStart + bodyLen
            let body = unsafe UnsafeRawBufferPointer(rebasing: raw[bodyStart ..< bodyEnd])
            if let message = unsafe M.parseBody(type: type, body) {
                return .event(.message(message), nextOffset: bodyEnd)
            }
            if M.isKnownType(type) {
                return .malformed // known type with an invalid body
            }
            return .event(.skippedUnknown(type: type), nextOffset: bodyEnd)
        }
        switch scan {
        case .needMore:
            return nil
        case .malformed:
            isMalformed = true
            buffer.removeAll(keepingCapacity: false)
            readOffset = 0
            return nil
        case let .event(event, nextOffset):
            readOffset = nextOffset
            if readOffset == buffer.count {
                buffer.removeAll(keepingCapacity: true)
                readOffset = 0
            } else if readOffset > 4096 {
                buffer.removeFirst(readOffset)
                readOffset = 0
            }
            return event
        }
    }
}
