import Accelerate
import CZlib
import Foundation
import ImageIO

/// Makes a PNG smaller and keeps it a PNG, transparency included. Everything here is written for
/// this app (no pngquant or other GPL code):
///  - Light: lossless. The smallest exact form of the same pixels (a palette when there are 256
///    colours or fewer, grey, or no alpha channel when nothing is transparent), the best filter for
///    each row, deflate at the maximum level, and no metadata.
///  - Medium / Strong: the colours reduced to a 256 / 128-colour palette (median cut, refined),
///    alpha included, then written the same way.
/// The colour profile and the pixel density are kept: they change how the picture looks and how
/// big it shows, so they aren't the kind of metadata to strip.
enum PNGCompressor {
    static func compress(_ source: URL, to output: URL, level: CompressLevel) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ConversionFailure("This PNG couldn't be read.")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? Double, props?[kCGImagePropertyDPIHeight] as? Double)

        // Pixels in an RGB space we can describe in the file: the image's own when it's RGB,
        // otherwise sRGB.
        let ownSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        let space = ownSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var png = PNGWriter.Image(width: image.width, height: image.height)
        png.colorProfile = Self.profile(for: space)
        if let x = dpi.0, let y = dpi.1, x > 0, y > 0, abs(x - 72) > 0.5 || abs(y - 72) > 0.5 {
            png.pixelsPerMetre = (UInt32((x / 0.0254).rounded()), UInt32((y / 0.0254).rounded()))
        }

        if level == .light, image.bitsPerComponent > 8 {
            // 16 bits per channel stay 16 bits: anything else would lose detail.
            let pixels = try Self.pixels16(image, space: space)
            PNGWriter.setTrueColor16(&png, pixels: pixels)
        } else {
            let pixels = try Self.pixels8(image, space: space)
            let maxColors = [CompressLevel.light: 256, .medium: 256, .strong: 128][level]!
            if let exact = ColorQuantizer.exactPalette(pixels, limit: 256), level == .light || exact.palette.count <= maxColors {
                // Few enough colours already: a palette is lossless.
                png.palette = exact.palette
                png.data = exact.indices
                png.colorType = .palette
            } else if level == .light {
                PNGWriter.setTrueColor8(&png, pixels: pixels)
            } else {
                let reduced = ColorQuantizer.quantize(pixels, maxColors: maxColors)
                png.palette = reduced.palette
                png.data = reduced.indices
                png.colorType = .palette
            }
        }
        try Task.checkCancellation()
        try PNGWriter.encode(png).write(to: output)
    }

    /// RGBA, 8 bits per channel, straight (not premultiplied) alpha, so semi-transparent edges
    /// keep their exact colour.
    private static func pixels8(_ image: CGImage, space: CGColorSpace) throws -> [UInt8] {
        try convert(image, space: space, bitsPerComponent: 8, bitmapInfo: CGImageAlphaInfo.last.rawValue)
    }

    /// RGBA, 16 bits per channel, big-endian (as PNG stores them), straight alpha.
    private static func pixels16(_ image: CGImage, space: CGColorSpace) throws -> [UInt8] {
        try convert(image, space: space, bitsPerComponent: 16,
                    bitmapInfo: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder16Big.rawValue)
    }

    private static func convert(_ image: CGImage, space: CGColorSpace, bitsPerComponent: UInt32, bitmapInfo: UInt32) throws -> [UInt8] {
        var format = vImage_CGImageFormat(bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerComponent * 4,
                                          colorSpace: Unmanaged.passUnretained(space), bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                          version: 0, decode: nil, renderingIntent: .defaultIntent)
        var buffer = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            throw ConversionFailure("This PNG couldn't be read.")
        }
        defer { free(buffer.data) }
        let rowBytes = image.width * Int(bitsPerComponent / 2)
        var pixels = [UInt8](repeating: 0, count: rowBytes * image.height)
        pixels.withUnsafeMutableBytes { out in
            for y in 0..<image.height {
                memcpy(out.baseAddress! + y * rowBytes, buffer.data + y * buffer.rowBytes, rowBytes)
            }
        }
        return pixels
    }

    /// sRGB is marked with the small sRGB chunk; any other profile goes in whole.
    private static func profile(for space: CGColorSpace) -> PNGWriter.ColorProfile {
        if space.name == CGColorSpace.sRGB { return .sRGB }
        if let icc = space.copyICCData() as Data? { return .icc(icc) }
        return .sRGB
    }
}

// MARK: - Colours

/// Reducing an RGBA picture to a palette. Median cut over a histogram of the colours (alpha is a
/// channel like the others), refined with a couple of k-means passes; fully transparent pixels
/// get an entry of their own, so transparent areas stay exactly transparent.
enum ColorQuantizer {
    typealias Result = (palette: [SIMD4<UInt8>], indices: [UInt8])

    /// The picture's own colours as a palette, if there are no more than `limit` of them.
    static func exactPalette(_ pixels: [UInt8], limit: Int) -> Result? {
        var lookup: [UInt32: UInt8] = [:]
        var palette: [SIMD4<UInt8>] = []
        var indices = [UInt8](repeating: 0, count: pixels.count / 4)
        var last: UInt32 = .max, lastIndex: UInt8 = 0
        for p in 0..<indices.count {
            let key = Self.key(pixels, p)
            if key == last { indices[p] = lastIndex; continue }
            if let found = lookup[key] {
                indices[p] = found
            } else {
                guard palette.count < limit else { return nil }
                let index = UInt8(palette.count)
                lookup[key] = index
                palette.append(Self.color(key))
                indices[p] = index
            }
            last = key
            lastIndex = indices[p]
        }
        return (palette, indices)
    }

    /// Colours with the same RGBA (every fully transparent colour counts as one).
    private static func key(_ pixels: [UInt8], _ p: Int) -> UInt32 {
        let a = pixels[p * 4 + 3]
        if a == 0 { return 0 }
        return UInt32(pixels[p * 4]) << 24 | UInt32(pixels[p * 4 + 1]) << 16 | UInt32(pixels[p * 4 + 2]) << 8 | UInt32(a)
    }

    private static func color(_ key: UInt32) -> SIMD4<UInt8> {
        SIMD4(UInt8(key >> 24), UInt8(key >> 16 & 255), UInt8(key >> 8 & 255), UInt8(key & 255))
    }

    /// A group of similar colours: 6 bits per channel, with the exact sums, so averages are exact.
    private struct Bucket {
        var count = 0
        var sum = SIMD4<Double>(repeating: 0)
        var mean: SIMD4<Double> { sum / Double(count) }
    }

    static func quantize(_ pixels: [UInt8], maxColors: Int) -> Result {
        let pixelCount = pixels.count / 4
        // Histogram of 6-bit buckets; fully transparent pixels kept apart.
        var bucketOf: [UInt32: Int] = [:]
        var buckets: [Bucket] = []
        var pixelBucket = [Int32](repeating: -1, count: pixelCount)
        var hasTransparent = false
        for p in 0..<pixelCount {
            let a = pixels[p * 4 + 3]
            if a == 0 { hasTransparent = true; continue }
            let r = pixels[p * 4], g = pixels[p * 4 + 1], b = pixels[p * 4 + 2]
            let key = UInt32(r >> 2) << 18 | UInt32(g >> 2) << 12 | UInt32(b >> 2) << 6 | UInt32(a >> 2)
            let index: Int
            if let found = bucketOf[key] {
                index = found
            } else {
                index = buckets.count
                bucketOf[key] = index
                buckets.append(Bucket())
            }
            buckets[index].count += 1
            buckets[index].sum += SIMD4(Double(r), Double(g), Double(b), Double(a))
            pixelBucket[p] = Int32(index)
        }

        let colorBudget = maxColors - (hasTransparent ? 1 : 0)
        var palette = Self.medianCut(buckets, colors: max(1, colorBudget))
        // Refine: each bucket to its nearest colour, each colour to the average of its buckets.
        var assignment = [Int](repeating: 0, count: buckets.count)
        for pass in 0..<3 {
            for i in buckets.indices { assignment[i] = Self.nearest(buckets[i].mean, in: palette) }
            guard pass < 2 else { break }
            var sums = [SIMD4<Double>](repeating: .zero, count: palette.count)
            var counts = [Int](repeating: 0, count: palette.count)
            for i in buckets.indices {
                sums[assignment[i]] += buckets[i].sum
                counts[assignment[i]] += buckets[i].count
            }
            for c in palette.indices where counts[c] > 0 { palette[c] = sums[c] / Double(counts[c]) }
        }

        // Entries: the transparent one first (if any), then the reduced colours.
        var entries: [SIMD4<UInt8>] = hasTransparent ? [SIMD4(0, 0, 0, 0)] : []
        let offset = entries.count
        entries += palette.map { c in SIMD4(UInt8(c.x.rounded().clamped(0, 255)), UInt8(c.y.rounded().clamped(0, 255)),
                                             UInt8(c.z.rounded().clamped(0, 255)), UInt8(c.w.rounded().clamped(1, 255))) }
        var indices = [UInt8](repeating: 0, count: pixelCount)
        for p in 0..<pixelCount {
            let b = pixelBucket[p]
            indices[p] = b < 0 ? 0 : UInt8(assignment[Int(b)] + offset)
        }
        return (entries, indices)
    }

    /// Splits the colour space into boxes, the busiest and widest first, until there are `colors`.
    private static func medianCut(_ buckets: [Bucket], colors: Int) -> [SIMD4<Double>] {
        guard !buckets.isEmpty else { return [SIMD4(0, 0, 0, 255)] }
        struct Box {
            var members: [Int]
            var count: Int
            var low: SIMD4<Double>
            var high: SIMD4<Double>
            var score: Double { (high - low).max() * Double(count).squareRoot() }
        }
        func box(_ members: [Int]) -> Box {
            var low = SIMD4<Double>(repeating: 255), high = SIMD4<Double>(repeating: 0), count = 0
            for m in members {
                let c = buckets[m].mean
                low = pointwiseMin(low, c)
                high = pointwiseMax(high, c)
                count += buckets[m].count
            }
            return Box(members: members, count: count, low: low, high: high)
        }
        var boxes = [box(Array(buckets.indices))]
        while boxes.count < colors {
            guard let target = boxes.indices.filter({ boxes[$0].members.count > 1 }).max(by: { boxes[$0].score < boxes[$1].score }) else { break }
            let current = boxes[target]
            let span = current.high - current.low
            let channel = (0..<4).max { span[$0] < span[$1] }!
            let sorted = current.members.sorted { buckets[$0].mean[channel] < buckets[$1].mean[channel] }
            // Split where half the pixels (not half the colours) fall on each side.
            var running = 0, cut = 1
            for (i, m) in sorted.enumerated() {
                running += buckets[m].count
                if running * 2 >= current.count { cut = max(1, min(i + 1, sorted.count - 1)); break }
            }
            boxes[target] = box(Array(sorted[..<cut]))
            boxes.append(box(Array(sorted[cut...])))
        }
        return boxes.map { b in
            var sum = SIMD4<Double>(repeating: 0)
            for m in b.members { sum += buckets[m].sum }
            return sum / Double(max(b.count, 1))
        }
    }

    /// Closest colour, weighing green most (as the eye does) and alpha strongly (edges show it).
    private static func nearest(_ color: SIMD4<Double>, in palette: [SIMD4<Double>]) -> Int {
        let weights = SIMD4<Double>(2, 4, 1.5, 3)
        var best = 0, bestDistance = Double.infinity
        for (i, c) in palette.enumerated() {
            let d = color - c
            let distance = (d * d * weights).sum()
            if distance < bestDistance { bestDistance = distance; best = i }
        }
        return best
    }
}

private extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(Swift.max(self, low), high) }
}

// MARK: - PNG file

/// A minimal PNG writer: the chunks a picture needs (IHDR, colour profile, density, PLTE, tRNS,
/// IDAT, IEND) and nothing else.
enum PNGWriter {
    enum ColorType: UInt8 { case gray = 0, rgb = 2, palette = 3, grayAlpha = 4, rgba = 6 }
    enum ColorProfile { case sRGB, icc(Data) }

    struct Image {
        let width: Int
        let height: Int
        var bitDepth: UInt8 = 8
        var colorType: ColorType = .rgba
        /// Rows one after another, no filter bytes.
        var data: [UInt8] = []
        var palette: [SIMD4<UInt8>] = []
        var colorProfile: ColorProfile = .sRGB
        var pixelsPerMetre: (UInt32, UInt32)?

        var bytesPerPixel: Int {
            let channels = [ColorType.gray: 1, .rgb: 3, .palette: 1, .grayAlpha: 2, .rgba: 4][colorType]!
            return channels * Int(bitDepth) / 8
        }
    }

    /// 8-bit RGBA, stored as the smallest exact colour type: grey when every pixel is grey, and
    /// without the alpha channel when nothing is transparent.
    static func setTrueColor8(_ image: inout Image, pixels: [UInt8]) {
        var opaque = true, gray = true
        for p in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[p + 3] != 255 { opaque = false }
            if pixels[p] != pixels[p + 1] || pixels[p + 1] != pixels[p + 2] { gray = false }
            if !opaque && !gray { break }
        }
        let keep: [Int] = switch (gray, opaque) {
        case (true, true): [0]
        case (true, false): [0, 3]
        case (false, true): [0, 1, 2]
        case (false, false): [0, 1, 2, 3]
        }
        image.colorType = gray ? (opaque ? .gray : .grayAlpha) : (opaque ? .rgb : .rgba)
        image.bitDepth = 8
        if keep.count == 4 {
            image.data = pixels
        } else {
            var out = [UInt8](); out.reserveCapacity(pixels.count / 4 * keep.count)
            for p in stride(from: 0, to: pixels.count, by: 4) { for k in keep { out.append(pixels[p + k]) } }
            image.data = out
        }
    }

    /// 16-bit big-endian RGBA, without the alpha channel when nothing is transparent.
    static func setTrueColor16(_ image: inout Image, pixels: [UInt8]) {
        var opaque = true
        for p in stride(from: 6, to: pixels.count, by: 8) where pixels[p] != 255 || pixels[p + 1] != 255 { opaque = false; break }
        image.bitDepth = 16
        image.colorType = opaque ? .rgb : .rgba
        if opaque {
            var out = [UInt8](); out.reserveCapacity(pixels.count / 8 * 6)
            for p in stride(from: 0, to: pixels.count, by: 8) { out.append(contentsOf: pixels[p..<(p + 6)]) }
            image.data = out
        } else {
            image.data = pixels
        }
    }

    static func encode(_ image: Image) throws -> Data {
        var file = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var header = Data()
        header.append(be32(UInt32(image.width)))
        header.append(be32(UInt32(image.height)))
        header.append(contentsOf: [image.bitDepth, image.colorType.rawValue, 0, 0, 0])
        file.append(chunk("IHDR", header))

        switch image.colorProfile {
        case .sRGB:
            file.append(chunk("sRGB", Data([0])))
        case .icc(let profile):
            guard let packed = deflate([UInt8](profile), strategy: Z_DEFAULT_STRATEGY) else { break }
            file.append(chunk("iCCP", Data("ICC Profile".utf8) + Data([0, 0]) + packed))
        }
        if let (x, y) = image.pixelsPerMetre {
            file.append(chunk("pHYs", be32(x) + be32(y) + Data([1])))
        }

        var palette = image.palette
        var indices = image.data
        if image.colorType == .palette {
            // Translucent entries first, so the transparency chunk can stop at the last of them.
            let order = palette.indices.sorted { (palette[$0].w == 255 ? 1 : 0, $0) < (palette[$1].w == 255 ? 1 : 0, $1) }
            var newIndex = [UInt8](repeating: 0, count: palette.count)
            for (new, old) in order.enumerated() { newIndex[old] = UInt8(new) }
            palette = order.map { palette[$0] }
            for i in indices.indices { indices[i] = newIndex[Int(indices[i])] }
            file.append(chunk("PLTE", Data(palette.flatMap { [$0.x, $0.y, $0.z] })))
            if let lastTranslucent = palette.lastIndex(where: { $0.w != 255 }) {
                file.append(chunk("tRNS", Data(palette[...lastTranslucent].map(\.w))))
            }
        }

        // The smallest of a few encodings: no filtering (usually best for palettes) and the best
        // filter per row, each deflated at the maximum level with two strategies.
        let bpp = max(1, image.bytesPerPixel)
        let rowBytes = image.width * bpp
        var candidates: [[UInt8]] = [filtered(indices, rowBytes: rowBytes, height: image.height, bpp: bpp, adaptive: true)]
        if image.colorType == .palette { candidates.append(filtered(indices, rowBytes: rowBytes, height: image.height, bpp: bpp, adaptive: false)) }
        var best: Data?
        for raw in candidates {
            for strategy in [Z_DEFAULT_STRATEGY, Z_FILTERED] {
                try Task.checkCancellation()
                if let packed = deflate(raw, strategy: strategy), best.map({ packed.count < $0.count }) ?? true { best = packed }
            }
        }
        guard let idat = best else { throw ConversionFailure("The PNG couldn't be written.") }
        file.append(chunk("IDAT", idat))
        file.append(chunk("IEND", Data()))
        return file
    }

    /// Each row prefixed with its filter: none, or (adaptive) whichever of PNG's five filters
    /// leaves the smallest values for that row.
    private static func filtered(_ data: [UInt8], rowBytes: Int, height: Int, bpp: Int, adaptive: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: (rowBytes + 1) * height)
        var candidate = [[UInt8]](repeating: [UInt8](repeating: 0, count: rowBytes), count: 5)
        data.withUnsafeBufferPointer { src in
            for y in 0..<height {
                let row = y * rowBytes
                let outRow = y * (rowBytes + 1)
                guard adaptive else {
                    out[outRow] = 0
                    for x in 0..<rowBytes { out[outRow + 1 + x] = src[row + x] }
                    continue
                }
                var bestFilter = 0, bestScore = Int.max
                for f in 0..<5 {
                    var score = 0
                    for x in 0..<rowBytes {
                        let raw = src[row + x]
                        let left = x >= bpp ? src[row + x - bpp] : 0
                        let up = y > 0 ? src[row - rowBytes + x] : 0
                        let upLeft = (y > 0 && x >= bpp) ? src[row - rowBytes + x - bpp] : 0
                        let value: UInt8
                        switch f {
                        case 1: value = raw &- left
                        case 2: value = raw &- up
                        case 3: value = raw &- UInt8((Int(left) + Int(up)) / 2)
                        case 4: value = raw &- paeth(left, up, upLeft)
                        default: value = raw
                        }
                        candidate[f][x] = value
                        score += value < 128 ? Int(value) : 256 - Int(value)
                    }
                    if score < bestScore { bestScore = score; bestFilter = f }
                }
                out[outRow] = UInt8(bestFilter)
                for x in 0..<rowBytes { out[outRow + 1 + x] = candidate[bestFilter][x] }
            }
        }
        return out
    }

    private static func paeth(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        let p = Int(a) + Int(b) - Int(c)
        let pa = abs(p - Int(a)), pb = abs(p - Int(b)), pc = abs(p - Int(c))
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c
    }

    /// zlib at level 9, the largest window and memory.
    private static func deflate(_ input: [UInt8], strategy: Int32) -> Data? {
        var stream = z_stream()
        guard deflateInit2_(&stream, 9, Z_DEFLATED, MAX_WBITS, 9, strategy, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(input.count))))
        let status: Int32 = input.withUnsafeBufferPointer { inBuffer in
            output.withUnsafeMutableBufferPointer { outBuffer in
                stream.next_in = UnsafeMutablePointer(mutating: inBuffer.baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = outBuffer.baseAddress
                stream.avail_out = uInt(outBuffer.count)
                return CZlib.deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { return nil }
        return Data(output[0..<Int(stream.total_out)])
    }

    private static func chunk(_ type: String, _ body: Data) -> Data {
        let typeBytes = Data(type.utf8)
        var crc = crc32(0, nil, 0)
        crc = (typeBytes + body).withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        return be32(UInt32(body.count)) + typeBytes + body + be32(UInt32(crc))
    }

    private static func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8(value >> 16 & 255), UInt8(value >> 8 & 255), UInt8(value & 255)])
    }
}
