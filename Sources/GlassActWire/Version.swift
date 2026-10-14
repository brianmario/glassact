/// Protocol version, the single source of truth for `ver` everywhere it
/// appears on the wire: the datagram header's high nibble (§3.3) and the
/// HELLO / HELLO_OK handshake fields (§3.5).
///
/// §12 — pre-release, any wire format change bumps this, and no decode path
/// for an older version is kept: peers must match exactly.
public enum WireVersion {
    /// v3 (2026-10-13): video is always the overlay — the `videoOverlay`
    /// caps bit (7) is gone, and with it the canvas-writing video path. A v2
    /// peer that never advertised the bit would get overlay semantics it
    /// doesn't implement, hence the bump — exact-match handshake rejects
    /// mixes.
    public static let current: UInt8 = 3

    /// v1 policy: exact match required. Handshake behavior on mismatch: the
    /// viewer still replies HELLO_OK carrying its own version (so both sides
    /// learn the peer's version), then both sides fail the connection.
    public static func isCompatible(_ v: UInt8) -> Bool {
        v == current
    }
}

/// §3.2 pixel formats. Only BGRA8 sRGB in v1; 2 (RGB10A2) and 3 (RGBA16F)
/// are reserved.
public enum PixelFormat {
    public static let bgra8sRGB: UInt8 = 1
}
