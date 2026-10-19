/// Protocol version, the single source of truth for `ver` everywhere it
/// appears on the wire: the datagram header's high nibble (§3.3) and the
/// HELLO / HELLO_OK handshake fields (§3.5).
///
/// §12 — until 1.0 the wire protocol may change in any release: every wire
/// format change bumps `current`, and no decode path or migration code for
/// an older version is kept. Both ends must run the same build.
public enum WireVersion {
    /// The wire format this build speaks. v3: video always travels as the
    /// overlay (§4.6), never written into the canvas. v4: SYNC_REQUEST
    /// (control 0x1B) — the viewer asks for a sync frame instead of
    /// reconnecting when a region can't decode.
    public static let current: UInt8 = 4

    /// Exact match required. Handshake behavior on mismatch: the viewer
    /// still replies HELLO_OK carrying its own version (so both sides learn
    /// the peer's version), then both sides fail the connection.
    public static func isCompatible(_ v: UInt8) -> Bool {
        v == current
    }
}

/// §3.2 pixel formats. Only BGRA8 sRGB is defined; 2 (RGB10A2) and 3
/// (RGBA16F) are reserved.
public enum PixelFormat {
    public static let bgra8sRGB: UInt8 = 1
}
