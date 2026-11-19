import Foundation

/// Compiles a tvOS `.brandassets`: the layered app icon image stacks and the
/// Top Shelf images. Shapes follow Apple actool 27.2 (SmartTube catalog and
/// the two/five-layer probes):
///
/// - each layer's `Content.imageset` compiles as an ordinary image named
///   `<stack>/<layer>/Content`, at the stack's idiom;
/// - one image-stack rendition (layout 1002) per stack, all named after the
///   tv (smallest) stack: the tv stack is keyed universal, an App Store stack
///   (any larger `primary-app-icon`) at the marketing idiom;
/// - per stack and scale, a flattened image (part 208, the layers composited
///   back to front) and a radiosity image (part 209, the flattened image
///   padded by 40 pt on each side and blurred);
/// - Top Shelf imagesets compile as ordinary images under their own names.
enum BrandAssetsCompiler {
    struct Output {
        var renditions: [Rendition]
        /// The name the stacks are keyed under (CFBundlePrimaryIcon).
        var primaryIconName: String?
        var infoPlistAdditions: [String: any Sendable]
    }

    /// Radiosity padding per side, points (480x320 for a 400x240 stack).
    static let radiosityPadding = 40

    static func compile(
        _ brand: LoadedBrandAssets,
        svgRasterizer: any SVGRasterizer,
        pdfRasterizer: any PDFRasterizer,
        heicDecoder: any HEICDecoder
    ) throws -> Output {
        let loader = CatalogLoader()
        let decoder = JSONDecoder()
        func render(_ set: LoadedImageSet) throws -> [Rendition] {
            try ImageRenderer.renditions(
                for: set, svgRasterizer: svgRasterizer, pdfRasterizer: pdfRasterizer, heicDecoder: heicDecoder)
        }

        let stacks = brand.contents.assets
            .filter { $0.role == "primary-app-icon" && $0.filename.hasSuffix(".imagestack") }
            .map { asset -> (asset: BrandAssetsContents.Asset, area: Int) in
                let size = parseSize(asset.size)
                return (asset, size.map { $0.0 * $0.1 } ?? 0)
            }
            .sorted { $0.area < $1.area }
            .map(\.asset)
        // The name every stack is keyed under (CFBundlePrimaryIcon): the smallest stack
        // that has layers. Set once a stack is written, so the plist never names an
        // icon the car lacks.
        var primaryName: String?

        var renditions: [Rendition] = []
        for asset in stacks {
            let stackName = stem(asset.filename)
            let directory = brand.directory.appendingPathComponent(asset.filename)
            let contents = try loader.decode(ImageStackContents.self, at: directory, decoder: decoder)
            // The smallest stack is the home-screen icon; any larger one is
            // the App Store icon (idiom marketing), even though Xcode writes
            // "tv" for both.
            let idiom: Idiom = primaryName == nil ? .tv : .marketing

            // Layers front to back as in Contents.json.
            var layers: [(identifier: UInt16, bitmaps: [Int: DecodedLayer])] = []
            var undecodable = false
            for layer in contents.layers {
                let setDirectory = directory.appendingPathComponent(layer.filename)
                    .appendingPathComponent("Content.imageset")
                guard FileManager.default.fileExists(atPath: setDirectory.path) else { continue }
                var setContents = try loader.decode(ImageSetContents.self, at: setDirectory, decoder: decoder)
                setContents.images = setContents.images.filter { $0.filename?.isEmpty == false }.map { image in
                    var image = image
                    image.idiom = idiom
                    if image.scale == nil { image.scale = .x1 }
                    return image
                }
                guard !setContents.images.isEmpty else { continue }
                let name = "\(stackName)/\(stem(layer.filename))/Content"
                renditions.append(contentsOf: try render(
                    LoadedImageSet(name: name, directory: setDirectory, contents: setContents)))

                var bitmaps: [Int: DecodedLayer] = [:]
                for image in setContents.images {
                    guard let filename = image.filename else { continue }
                    // Only PNG layers can be decoded here (AssetKit embeds JPEG and HEIC
                    // without decoding them). The layer renditions above are written either
                    // way; a stack with an undecodable layer gets no flattened or radiosity
                    // image instead of failing the whole catalog.
                    guard SourceFormat.detect(filename: filename) == .png,
                          let decoded = try? PNGSource.decodeBGRA(
                            Data(contentsOf: setDirectory.appendingPathComponent(filename)))
                    else {
                        undecodable = true
                        continue
                    }
                    let factor = image.scale?.factor ?? 1
                    bitmaps[factor] = DecodedLayer(width: Int(decoded.width), height: Int(decoded.height), pixels: decoded.bgra8)
                }
                layers.append((UInt16(FacetKeys.nameHash(name) & 0xFFFF), bitmaps))
            }
            guard !layers.isEmpty else { continue }
            if primaryName == nil { primaryName = stackName }
            guard let primaryName else { continue }

            // Layer frames in points: each layer's lowest-scale image over
            // its scale. The stack is as large as its largest layer (Apple
            // probe: a 1280x768 stack of 400x240 layers is keyed 400x240),
            // and every layer is centered in it.
            let pointSizes = layers.map { layer -> (Int, Int) in
                // A layer without a decodable image has no pixel size; its frame is the
                // stack's (0x0 here, then centered at the stack size).
                guard let factor = layer.bitmaps.keys.min(), let bitmap = layer.bitmaps[factor] else {
                    return (0, 0)
                }
                // Rounded up: a 401x241 @2x layer needs 201x121 points, not 200x120.
                return ((bitmap.width + factor - 1) / factor, (bitmap.height + factor - 1) / factor)
            }
            // No decodable layer at all (JPEG/HEIC only): the size the catalog declares.
            let declared = parseSize(asset.size) ?? (0, 0)
            let stackWidth = max(pointSizes.map(\.0).max()!, pointSizes.allSatisfy { $0.0 == 0 } ? declared.0 : 0)
            let stackHeight = max(pointSizes.map(\.1).max()!, pointSizes.allSatisfy { $0.1 == 0 } ? declared.1 : 0)
            let frames = pointSizes.map { size -> (x: Int, y: Int, w: Int, h: Int) in
                let size = size.0 == 0 ? (stackWidth, stackHeight) : size
                return (x: (stackWidth - size.0) / 2, y: (stackHeight - size.1) / 2, w: size.0, h: size.1)
            }

            // Back to front: index 0 is the last layer of the json list.
            let stackLayers = zip(layers, frames).reversed().map { layer, frame in
                ImageStackLayer(
                    x: UInt32(frame.x), y: UInt32(frame.y), width: UInt32(frame.w), height: UInt32(frame.h),
                    identifier: layer.identifier)
            }
            renditions.append(Rendition(
                name: primaryName,
                idiom: idiom == .tv ? .universal : idiom,
                scale: .x1,
                body: .imageStack(ImageStackBody(
                    width: UInt32(stackWidth), height: UInt32(stackHeight), layers: stackLayers))))

            // The flattened and radiosity images need every layer's pixels.
            let factors = undecodable ? [] : Set(layers.flatMap { $0.bitmaps.keys }).sorted()
            for factor in factors {
                guard let scale = [Scale.x1, .x2, .x3].first(where: { $0.factor == factor }) else { continue }
                let canvasWidth = stackWidth * factor
                let canvasHeight = stackHeight * factor
                var canvas = [UInt8](repeating: 0, count: canvasWidth * canvasHeight * 4)
                for (layer, frame) in zip(layers, frames).reversed() {
                    let bitmap = layer.bitmaps[factor]
                        ?? layer.bitmaps.max(by: { $0.key < $1.key })!.value
                    composite(
                        bitmap, into: &canvas, canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                        x: frame.x * factor, y: frame.y * factor,
                        width: frame.w * factor, height: frame.h * factor)
                }
                renditions.append(Rendition(
                    name: primaryName, idiom: idiom, scale: scale,
                    body: .bitmap(BitmapBody(
                        width: UInt32(canvasWidth), height: UInt32(canvasHeight), pixelsBGRA: canvas,
                        colorSpaceID: 1, kind: .flattenedImage,
                        renditionName: "ZZZZFlattenedImage-\(factor).1.0-gamut0"))))

                let pad = radiosityPadding * factor
                let glowWidth = canvasWidth + 2 * pad
                let glowHeight = canvasHeight + 2 * pad
                var glow = [UInt8](repeating: 0, count: glowWidth * glowHeight * 4)
                for row in 0..<canvasHeight {
                    let source = row * canvasWidth * 4
                    let target = ((row + pad) * glowWidth + pad) * 4
                    glow.replaceSubrange(target..<target + canvasWidth * 4, with: canvas[source..<source + canvasWidth * 4])
                }
                boxBlur(&glow, width: glowWidth, height: glowHeight, radius: 20 * factor, passes: 3)
                renditions.append(Rendition(
                    name: primaryName, idiom: idiom, scale: scale,
                    body: .bitmap(BitmapBody(
                        width: UInt32(glowWidth), height: UInt32(glowHeight), pixelsBGRA: glow,
                        colorSpaceID: 1, kind: .radiosityImage,
                        renditionName: "ZZZZRadiosityImage-\(factor).0.0"))))
            }
        }

        var topShelf: [String: any Sendable] = [:]
        for asset in brand.contents.assets where asset.filename.hasSuffix(".imageset") {
            let key: String
            switch asset.role {
            case "top-shelf-image": key = "TVTopShelfPrimaryImage"
            case "top-shelf-image-wide": key = "TVTopShelfPrimaryImageWide"
            default: continue
            }
            let directory = brand.directory.appendingPathComponent(asset.filename)
            var contents = try loader.decode(ImageSetContents.self, at: directory, decoder: decoder)
            contents.images = contents.images.map { image in
                var image = image
                if image.scale == nil, let filename = image.filename,
                   [.png, .jpeg, .heic].contains(SourceFormat.detect(filename: filename)) {
                    image.scale = .x1
                }
                return image
            }
            let name = stem(asset.filename)
            let compiled = try render(LoadedImageSet(name: name, directory: directory, contents: contents))
            guard !compiled.isEmpty else { continue }
            renditions.append(contentsOf: compiled)
            topShelf[key] = name
        }

        var plist: [String: any Sendable] = [:]
        if let primaryName {
            // tvOS: CFBundlePrimaryIcon is the stack name as a string.
            plist["CFBundleIcons"] = ["CFBundlePrimaryIcon": primaryName] as [String: any Sendable]
        }
        if !topShelf.isEmpty {
            plist["TVTopShelfImage"] = topShelf
        }
        return Output(renditions: renditions, primaryIconName: primaryName, infoPlistAdditions: plist)
    }

    struct DecodedLayer {
        var width: Int
        var height: Int
        /// Premultiplied BGRA.
        var pixels: [UInt8]
    }

    private static func stem(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
    }

    private static func parseSize(_ size: String?) -> (Int, Int)? {
        guard let parts = size?.split(separator: "x"), parts.count == 2,
              let w = Double(parts[0]), let h = Double(parts[1]) else { return nil }
        return (Int(w), Int(h))
    }

    /// Source-over of a premultiplied layer into the canvas at a frame
    /// (nearest-neighbour resampled when the layer's size differs).
    static func composite(
        _ layer: DecodedLayer, into canvas: inout [UInt8], canvasWidth: Int, canvasHeight: Int,
        x: Int, y: Int, width: Int, height: Int
    ) {
        guard width > 0, height > 0 else { return }
        for row in 0..<height {
            let cy = y + row
            guard cy >= 0, cy < canvasHeight else { continue }
            let sy = row * layer.height / height
            for column in 0..<width {
                let cx = x + column
                guard cx >= 0, cx < canvasWidth else { continue }
                let sx = column * layer.width / width
                let s = (sy * layer.width + sx) * 4
                let d = (cy * canvasWidth + cx) * 4
                let alpha = Int(layer.pixels[s + 3])
                if alpha == 0 { continue }
                for c in 0..<4 {
                    let src = Int(layer.pixels[s + c])
                    let dst = Int(canvas[d + c])
                    canvas[d + c] = UInt8(min(255, src + (dst * (255 - alpha) + 127) / 255))
                }
            }
        }
    }

    /// Separable box blur over premultiplied BGRA; three passes approximate a
    /// Gaussian.
    static func boxBlur(_ pixels: inout [UInt8], width: Int, height: Int, radius: Int, passes: Int) {
        guard radius > 0, width > 0, height > 0 else { return }
        var buffer = pixels.map(Int32.init)
        var scratch = buffer
        let window = Int32(2 * radius + 1)
        func blur(count: Int, lines: Int, offset: (Int, Int) -> Int) {
            for line in 0..<lines {
                for c in 0..<4 {
                    var sum: Int32 = 0
                    for i in -radius...radius {
                        let j = min(max(i, 0), count - 1)
                        sum += buffer[offset(line, j) + c]
                    }
                    for i in 0..<count {
                        scratch[offset(line, i) + c] = (sum + window / 2) / window
                        let outIndex = min(max(i - radius, 0), count - 1)
                        let inIndex = min(i + radius + 1, count - 1)
                        sum += buffer[offset(line, inIndex) + c] - buffer[offset(line, outIndex) + c]
                    }
                }
            }
            swap(&buffer, &scratch)
        }
        for _ in 0..<passes {
            blur(count: width, lines: height) { line, i in (line * width + i) * 4 }
            blur(count: height, lines: width) { line, i in (i * width + line) * 4 }
        }
        pixels = buffer.map { UInt8(clamping: $0) }
    }
}
