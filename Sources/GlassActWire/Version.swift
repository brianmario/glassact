/// Protocol version, the single source of truth for `ver` everywhere it
/// appears on the wire: the datagram header's high nibble (§3.3) and the
/// HELLO / HELLO_OK handshake fields (§3.5).
///
/// §12 — Host and Viewer of different releases work together, so the wire
/// only grows. New control or video message types (receivers skip unknown
/// ones), fields appended to a fixed-layout message (receivers ignore what
/// they don't read), new INPUT kinds and tile opcodes, and new behaviour or
/// enum values behind a caps bit (§3.8), with the old path kept for peers
/// without it. Bumping `current` drops every older release, so it's for a
/// deliberate, very rare break only.
public enum WireVersion {
    /// The wire format this build speaks. v3: video always travels as the
    /// overlay (§4.6), never written into the canvas. v4: SYNC_REQUEST
    /// (control 0x1B) — the viewer asks for a sync frame instead of
    /// reconnecting when a region can't decode. v4 is the first released
    /// protocol (26.10.0); everything since extends it additively.
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
