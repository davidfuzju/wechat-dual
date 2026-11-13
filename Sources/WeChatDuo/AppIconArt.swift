import AppKit

/// This app's icon: rounded square with two chat bubbles (SF Symbol), generated at build time.
enum AppIconArt {
    static func render(size: Int = 1024) -> CGImage {
        let s = CGFloat(size)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let inset = s * 0.1
        let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let path = CGPath(roundedRect: rect, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil)
        ctx.addPath(path)
        ctx.clip()
        let grad = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0.20, green: 0.22, blue: 0.26, alpha: 1),
            CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
            .applying(.init(paletteColors: [NSColor(red: 0.03, green: 0.76, blue: 0.38, alpha: 1), .white]))
        if let sym = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let sz = sym.size
            sym.draw(in: CGRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
}
