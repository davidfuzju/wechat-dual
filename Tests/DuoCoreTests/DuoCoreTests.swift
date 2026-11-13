import CoreGraphics
@testable import DuoCore
import XCTest

final class DuoCoreTests: XCTestCase {
    func testHexParsing() {
        XCTAssertEqual(RGB(hex: "#262626"), RGB(r: 0x26, g: 0x26, b: 0x26))
        XCTAssertEqual(RGB(hex: "1296DB")?.hex, "#1296db")
        XCTAssertNil(RGB(hex: "#12345"))
        XCTAssertNil(RGB(hex: "zzzzzz"))
    }

    func testHSVRoundTrip() {
        for (r, g, b) in [(7, 193, 96), (18, 150, 219), (38, 38, 38), (255, 255, 255)] as [(UInt8, UInt8, UInt8)] {
            let hsv = IconRecolor.rgbToHSV(r, g, b)
            let back = IconRecolor.hsvToRGB(hsv.h, hsv.s, hsv.v)
            XCTAssertLessThanOrEqual(abs(Int(back.0) - Int(r)), 4)
            XCTAssertLessThanOrEqual(abs(Int(back.1) - Int(g)), 4)
            XCTAssertLessThanOrEqual(abs(Int(back.2) - Int(b)), 4)
        }
    }

    /// 2×1 image, green then white: only the green pixel changes; a black target yields grey.
    func testRecolorTouchesOnlyGreen() {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let px = ctx.data!.bindMemory(to: UInt8.self, capacity: 8)
        (px[0], px[1], px[2], px[3]) = (7, 193, 96, 255)
        (px[4], px[5], px[6], px[7]) = (255, 255, 255, 255)
        let (out, selected) = IconRecolor.recolor(ctx.makeImage()!, to: RGB(hex: "#262626")!)
        XCTAssertEqual(selected, 1)
        let data = out.dataProvider!.data! as Data
        XCTAssertEqual(data[0], data[1]); XCTAssertEqual(data[1], data[2])   // grey
        XCTAssertLessThan(Int(data[0]), 60)
        XCTAssertEqual(Array(data[4..<8]), [255, 255, 255, 255])              // white untouched
    }

    func testICNSWriteReadBack() throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0.7, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID()).icns")
        defer { try? FileManager.default.removeItem(at: url) }
        try IconRecolor.writeICNS(ctx.makeImage()!, to: url)
        XCTAssertEqual(IconRecolor.largestImage(in: url)?.width, 1024)
    }

    func testOpenStepStringsUpdate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID()).strings")
        defer { try? FileManager.default.removeItem(at: url) }
        try "CFBundleName = \"WeChat\";\nNSHumanReadableCopyright = \"x\";\n".write(to: url, atomically: true, encoding: .utf8)
        try Plist.update(url, onlyExisting: true, ["CFBundleName": "WeChat Dual", "CFBundleDisplayName": "WeChat Dual"])
        XCTAssertEqual(Plist.string(url, "CFBundleName"), "WeChat Dual")
        XCTAssertNil(Plist.string(url, "CFBundleDisplayName"))   // missing keys are not added
    }
}
