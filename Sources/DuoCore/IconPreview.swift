import CoreGraphics
import Foundation

/// Recolor preview rendered from the stock icon; never touches the copy.
public enum IconPreview {
    private static var cache: [Int: CGImage] = [:]
    private static let lock = NSLock()

    static func stockIcon(size: Int) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[size] { return c }
        let src = Paths.stockApp.appendingPathComponent("Contents/Resources/AppIcon.icns")
        guard let big = IconRecolor.largestImage(in: src) else { return nil }
        let img = IconRecolor.resized(big, to: size)
        cache[size] = img
        return img
    }

    public static func render(color: String, size: Int = 256) -> CGImage? {
        guard let base = stockIcon(size: size) else { return nil }
        if color == "original" { return base }
        guard let rgb = RGB(hex: color) else { return nil }
        return IconRecolor.recolor(base, to: rgb).image
    }
}
