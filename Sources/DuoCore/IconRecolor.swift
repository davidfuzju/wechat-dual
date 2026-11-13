import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct RGB: Equatable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }

    /// Parses "#rrggbb" / "rrggbb".
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        r = UInt8((value >> 16) & 0xFF); g = UInt8((value >> 8) & 0xFF); b = UInt8(value & 0xFF)
    }

    public var hex: String { String(format: "#%02x%02x%02x", r, g, b) }
}

/// Recolors the green area of the WeChat icon.
///
/// Ported from the upstream recolor.py, using the same byte-based HSV as Pillow:
/// - Selection: hue 90°–175°, saturation ≥ 0.35, alpha > 4 (white bubbles and transparent edges stay untouched)
/// - Chromatic target: replace hue only, keep saturation / value so shading and antialiasing survive
/// - Neutral target (black / grey, saturation byte < 26): drop saturation, scale value by target / 235
public enum IconRecolor {
    static let hueLow = byteHue(90), hueHigh = byteHue(175)
    static let satFloor = UInt8((0.35 * 255).rounded())
    static let alphaFloor: UInt8 = 4
    /// Peak value (byte) of the stock green; neutral targets scale relative to it.
    static let stockPeakValue = 235.0

    static func byteHue(_ degrees: Double) -> Int { Int((degrees.truncatingRemainder(dividingBy: 360) * 255 / 360).rounded()) & 0xFF }

    // MARK: Pillow-compatible HSV (all channels are 0–255 bytes)

    static func rgbToHSV(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (h: Int, s: Int, v: Int) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let maxc = max(rf, gf, bf), minc = min(rf, gf, bf)
        let v = maxc
        if minc == maxc { return (0, 0, Int((v * 255).rounded())) }
        let s = (maxc - minc) / maxc
        let rc = (maxc - rf) / (maxc - minc), gc = (maxc - gf) / (maxc - minc), bc = (maxc - bf) / (maxc - minc)
        var h: Double
        if rf == maxc { h = bc - gc } else if gf == maxc { h = 2.0 + rc - bc } else { h = 4.0 + gc - rc }
        h = (h / 6.0).truncatingRemainder(dividingBy: 1.0)
        if h < 0 { h += 1 }
        return (Int(h * 255) & 0xFF, Int((s * 255).rounded()), Int((v * 255).rounded()))
    }

    static func hsvToRGB(_ h: Int, _ s: Int, _ v: Int) -> (UInt8, UInt8, UInt8) {
        let hf = Double(h) / 255, sf = Double(s) / 255, vf = Double(v) / 255
        if sf == 0 { let c = UInt8(clamping: Int((vf * 255).rounded())); return (c, c, c) }
        let i = Int(hf * 6) % 6
        let f = hf * 6 - Double(Int(hf * 6))
        let p = vf * (1 - sf), q = vf * (1 - sf * f), t = vf * (1 - sf * (1 - f))
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (vf, t, p)
        case 1: (r, g, b) = (q, vf, p)
        case 2: (r, g, b) = (p, vf, t)
        case 3: (r, g, b) = (p, q, vf)
        case 4: (r, g, b) = (t, p, vf)
        default: (r, g, b) = (vf, p, q)
        }
        func byte(_ x: Double) -> UInt8 { UInt8(clamping: Int((x * 255).rounded())) }
        return (byte(r), byte(g), byte(b))
    }

    // MARK: Image processing

    /// Returns the recolored image and the number of recolored pixels.
    public static func recolor(_ image: CGImage, to target: RGB) -> (image: CGImage, selected: Int) {
        let w = image.width, h = image.height
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)

        let t = rgbToHSV(target.r, target.g, target.b)
        let neutral = t.s < 26
        var selected = 0
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let a = px[i + 3]
            if a <= alphaFloor { continue }
            // un-premultiply
            let af = Double(a)
            let r = UInt8(min(255, (Double(px[i]) * 255 / af).rounded()))
            let g = UInt8(min(255, (Double(px[i + 1]) * 255 / af).rounded()))
            let b = UInt8(min(255, (Double(px[i + 2]) * 255 / af).rounded()))
            let hsv = rgbToHSV(r, g, b)
            guard hsv.h >= hueLow, hsv.h <= hueHigh, hsv.s >= Int(satFloor) else { continue }
            selected += 1
            let out: (UInt8, UInt8, UInt8)
            if neutral {
                let v = min(255, Int((Double(hsv.v) * Double(t.v) / stockPeakValue).rounded()))
                out = (UInt8(v), UInt8(v), UInt8(v))
            } else {
                out = hsvToRGB(t.h, hsv.s, hsv.v)
            }
            px[i] = UInt8((Double(out.0) * af / 255).rounded())
            px[i + 1] = UInt8((Double(out.1) * af / 255).rounded())
            px[i + 2] = UInt8((Double(out.2) * af / 255).rounded())
        }
        return (ctx.makeImage()!, selected)
    }

    /// The largest rendition inside an .icns.
    public static func largestImage(in icns: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(icns as CFURL, nil) else { return nil }
        var best: CGImage?
        for i in 0..<CGImageSourceGetCount(src) {
            if let img = CGImageSourceCreateImageAtIndex(src, i, nil), img.width > (best?.width ?? 0) { best = img }
        }
        return best
    }

    public static func resized(_ image: CGImage, to size: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
    }

    /// Writes an .icns natively with ImageIO (no iconutil).
    public static func writeICNS(_ image: CGImage, to url: URL) throws {
        // Like an iconset: a 1x (72 dpi) and a 2x (144 dpi) image per size, otherwise 1024 px gets dropped
        let bases = [16, 32, 128, 256, 512]
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, bases.count * 2, nil) else {
            throw DuoError("Cannot create icns: \(url.path)")
        }
        for s in bases {
            for scale in [1, 2] {
                let dpi = 72 * scale
                let props = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
                CGImageDestinationAddImage(dest, resized(image, to: s * scale), props)
            }
        }
        guard CGImageDestinationFinalize(dest) else { throw DuoError("Failed to write icns: \(url.path)") }
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw DuoError("Cannot create png: \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw DuoError("Failed to write png") }
    }
}
