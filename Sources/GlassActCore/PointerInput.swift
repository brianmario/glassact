/// Remote pointer input on the Host (§3.5 INPUT).
public enum PointerInput {
    /// INPUT's x and y for `kind`, kept on the shared picture (`width` × `height`, in the
    /// canvas's pixels): moves and clicks (kinds 1–3) clamped to its last pixel, so a drag
    /// past the picture's edge can't land on a neighbouring display the viewer doesn't
    /// see. Other kinds pass as sent: a key's x is its key code, and scrolls don't use
    /// them. Before a picture (a zero size), as sent.
    public static func onPicture(kind: Int, x: Int, y: Int, width: Int, height: Int) -> (x: Int, y: Int) {
        guard (1...3).contains(kind), width > 0, height > 0 else { return (x, y) }
        return (min(max(x, 0), width - 1), min(max(y, 0), height - 1))
    }
}
