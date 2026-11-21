/// Scale Down (`GeometryMode.scale`): the host's display stays as it is and its picture is scaled to
/// the Viewer's window. When the window's size settles after a resize, the Viewer asks the host to
/// re-fit the picture if the window has outgrown it (it would be upscaled) or is clearly smaller
/// (host pixels nobody sees, and softer text than a picture made at the window's size). A small
/// difference isn't worth it: each re-fit rebuilds the host's capture, a blink.
public enum ScaleRefit {
    /// How much smaller than the picture (fitted into the window, by its smaller ratio) the window
    /// may get before the picture is re-fitted. It was 0.75 on the width alone until 2026-11-21: a
    /// tester shrank his window and the picture never changed.
    public static let shrinkBelow = 0.9
    /// How much larger (a picture the host can make bigger: never past its display's own pixels).
    public static let growAbove = 1.02

    /// Whether to ask for a picture the size of a window of `window` pixels, showing a picture of
    /// `picture` pixels (both width × height).
    public static func shouldRefit(window: (width: Double, height: Double), picture: (width: Int, height: Int)) -> Bool {
        guard picture.width > 0, picture.height > 0, window.width > 0, window.height > 0 else { return false }
        // the picture fitted into the window: the scale it's shown at
        let fit = min(window.width / Double(picture.width), window.height / Double(picture.height))
        return fit > growAbove || fit < shrinkBelow
    }
}
