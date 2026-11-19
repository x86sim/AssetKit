import Foundation
import PNG
import Testing
@testable import AssetKit

/// tvOS `.brandassets` image stacks. Bytes pinned against Apple actool
/// 27.2's compilation of the two-layer probe (a 200x120 front layer over a
/// 400x240 back layer; `tvos-brandassets-ref/probe/two.car`).
@Suite("tvOS image stacks")
struct ImageStackTests {
    /// A TVL payload of a CSI blob, by tag.
    private func tvl(_ tag: UInt32, in csi: Data) -> [UInt8]? {
        let bytes = [UInt8](csi)
        func le32(_ o: Int) -> UInt32 {
            UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        let tvlLength = Int(le32(168))
        var p = 184
        while p < 184 + tvlLength {
            let kind = le32(p), length = Int(le32(p + 4))
            if kind == tag { return Array(bytes[p + 8..<p + 8 + length]) }
            p += 8 + length
        }
        return nil
    }

    private func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    @Test("Two-layer stack CSI matches Apple's bytes")
    func twoLayerCSI() throws {
        // Apple's identifiers: Back 31317 (0x7a55), Front 23331 (0x5b23).
        let body = ImageStackBody(width: 400, height: 240, layers: [
            ImageStackLayer(x: 0, y: 0, width: 400, height: 240, identifier: 31317),
            ImageStackLayer(x: 100, y: 60, width: 200, height: 120, identifier: 23331),
        ])
        let csi = CSIWriter.imageStack(body: body)
        let bytes = [UInt8](csi)
        // Layout 1002, 'DATA', 400x240, scale 100, name "Contents.json".
        #expect(bytes[36] == 0xEA && bytes[37] == 0x03)
        #expect(Array(bytes[24..<28]) == Array("ATAD".utf8))
        #expect(Array(bytes[12..<20]) == [0x90, 0x01, 0, 0, 0xF0, 0, 0, 0])
        #expect(String(decoding: bytes[40..<53], as: UTF8.self) == "Contents.json")

        #expect(tvl(1012, in: csi) == hex(
            "020000000000000000000000000000000000000090010000f0000000000000000000803f10000000010055000200b500"
            + "1100557a0000000000000000640000003c000000c800000078000000000000000000803f10000000010055000200b500"
            + "1100235b00000000"))
        #expect(tvl(1020, in: csi) == hex("02000000000000000000000000000000010000000000000000000000000100000000"))
        #expect(tvl(1021, in: csi) == [2, 0, 0, 0] + [UInt8](repeating: 0, count: 44))
        #expect(tvl(1022, in: csi) == [2, 0, 0, 0] + [UInt8](repeating: 0, count: 28))
        #expect(tvl(1004, in: csi) == hex("000000000000803f"))
        #expect(tvl(1005, in: csi) == hex("14000000000000007075626c69632e6c617965726564696d61676500"))
        #expect(tvl(1006, in: csi) == hex("01000000"))
        // TVL order and the 12-byte DWAR body (Apple: tvl=314 body=12).
        #expect(csi.count == 184 + 314 + 12)
        #expect(Array(bytes.suffix(12)) == Array("DWAR".utf8) + [UInt8](repeating: 0, count: 8))
    }

    @Test("Flattened and radiosity images use layout 0 and an empty slice rect")
    func derivedImageCSI() throws {
        let body = BitmapBody(
            width: 2, height: 1, pixelsBGRA: [0, 0, 255, 255, 0, 0, 255, 255], colorSpaceID: 1,
            kind: .flattenedImage, renditionName: "ZZZZFlattenedImage-1.1.0-gamut0")
        let csi = CSIWriter.bitmap(name: "App Icon", body: body, scaleFactor: 100)
        let bytes = [UInt8](csi)
        #expect(bytes[36] == 0 && bytes[37] == 0)
        #expect(Array(bytes[8..<12]) == [0, 0, 0, 0])  // rendition flags
        #expect(tvl(1001, in: csi) == [1] + [UInt8](repeating: 0, count: 19))
        #expect(tvl(1003, in: csi) == nil)
        #expect(tvl(1007, in: csi) == [8, 0, 0, 0])
    }

    private func png(width: Int, height: Int, rgba: (UInt8, UInt8, UInt8, UInt8)) throws -> Data {
        let pixels = [PNG.RGBA<UInt8>](
            repeating: PNG.RGBA<UInt8>(rgba.0, rgba.1, rgba.2, rgba.3), count: width * height)
        let image = PNG.Image(
            packing: pixels, size: (x: width, y: height), layout: PNG.Layout(format: .rgba8(palette: [], fill: nil)))
        var stream = MemoryBytestreamDestination()
        try image.compress(stream: &stream)
        return Data(stream.bytes)
    }

    private func write(_ json: String, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("Contents.json"))
    }

    @Test("A brandassets compiles to Apple's rendition set and partial plist")
    func compileBrandAssets() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("brand-\(UUID().uuidString).xcassets")
        defer { try? fm.removeItem(at: root) }
        let info = #""info":{"author":"xcode","version":1}"#
        try write("{\(info)}", to: root)
        let brand = root.appendingPathComponent("Icon.brandassets")
        try write("""
        {"assets":[
          {"filename":"App Icon.imagestack","idiom":"tv","role":"primary-app-icon","size":"400x240"},
          {"filename":"Shelf.imageset","idiom":"tv","role":"top-shelf-image","size":"1920x720"}],\(info)}
        """, to: brand)
        let stack = brand.appendingPathComponent("App Icon.imagestack")
        try write(#"{"layers":[{"filename":"Front.imagestacklayer"},{"filename":"Back.imagestacklayer"}],\#(info)}"#, to: stack)
        for (layer, w, h, color) in [("Front", 200, 120, (255, 0, 0, 128)), ("Back", 400, 240, (0, 0, 255, 255))] as [(String, Int, Int, (UInt8, UInt8, UInt8, UInt8))] {
            let set = stack.appendingPathComponent("\(layer).imagestacklayer/Content.imageset")
            try write("{\(info)}", to: set.deletingLastPathComponent())
            try write(#"{"images":[{"filename":"a.png","idiom":"tv"}],\#(info)}"#, to: set)
            try png(width: w, height: h, rgba: color).write(to: set.appendingPathComponent("a.png"))
        }
        let shelf = brand.appendingPathComponent("Shelf.imageset")
        try write(#"{"images":[{"filename":"s.png","idiom":"tv","scale":"1x"}],\#(info)}"#, to: shelf)
        try png(width: 8, height: 3, rgba: (0, 255, 0, 255)).write(to: shelf.appendingPathComponent("s.png"))

        let result = try await XCAssetCompiler(deploymentTarget: "18.0", platform: "appletvos")
            .compile(catalog: root, appIconName: "Icon")
        let plist = try #require(result.appIconBundle)
        #expect(plist.primaryIconName == "Icon")
        #expect(plist.looseFiles.isEmpty)
        #expect((plist.infoPlistAdditions["CFBundleIcons"] as? [String: any Sendable])?["CFBundlePrimaryIcon"] as? String
            == "App Icon")
        #expect((plist.infoPlistAdditions["TVTopShelfImage"] as? [String: any Sendable])?["TVTopShelfPrimaryImage"] as? String
            == "Shelf")

        let car = try CARReader(result.carData)
        #expect(try Set(car.facets.keys) == ["App Icon", "App Icon/Back/Content", "App Icon/Front/Content", "Shelf"])
        #expect(try car.facets["App Icon"]?[2] == 181)
        let keys = try car.renditionKeys
        #expect(keys.count == 6)
        // Stack (universal, part 181), flattened (208) and radiosity (209)
        // at idiom tv.
        #expect(keys.filter { $0.hasPrefix("App Icon|") }.count == 3)
        #expect(keys.contains { $0.hasPrefix("App Icon|") && $0.contains("208") })
        #expect(keys.contains { $0.hasPrefix("App Icon|") && $0.contains("209") })
    }

    @Test("Radiosity blur keeps a uniform image uniform and spreads a point")
    func boxBlur() {
        var flat = [UInt8](repeating: 200, count: 6 * 4 * 4)
        BrandAssetsCompiler.boxBlur(&flat, width: 6, height: 4, radius: 2, passes: 3)
        #expect(flat.allSatisfy { $0 == 200 })

        var dot = [UInt8](repeating: 0, count: 9 * 9 * 4)
        for c in 0..<4 { dot[(4 * 9 + 4) * 4 + c] = 255 }
        BrandAssetsCompiler.boxBlur(&dot, width: 9, height: 9, radius: 1, passes: 1)
        #expect(dot[(4 * 9 + 4) * 4 + 3] == 28)  // 255 / 9, rounded
        #expect(dot[(3 * 9 + 3) * 4 + 3] == 28)
        #expect(dot[3] == 0)
    }
}
