/// A capture reduced to a palette and one palette entry per pixel, ready for an indexed PNG.
public struct PalettedImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Straight (not premultiplied) RGBA packed as 0xRRGGBBAA.
    public let palette: [UInt32]
    public let indices: [UInt8]
}

public enum PaletteQuantizer {
    /// An indexed PNG's palette holds at most 256 entries (PNG spec, 11.2.3 PLTE).
    public static let maxColors = 256

    /// `rgba` is straight RGBA, 4 bytes per pixel, row after row. A capture of `maxColors` colors or fewer keeps every
    /// pixel exactly. Past that, median cut groups the colors, always splitting the group that strays furthest from its
    /// mean, and each group's pixel-weighted mean becomes its palette entry.
    public static func quantize(rgba: [UInt8], width: Int, height: Int) -> PalettedImage {
        precondition(rgba.count == width * height * 4, "\(width) × \(height) RGBA needs \(width * height * 4) bytes, got \(rgba.count)")
        let pixels = packed(rgba)
        let groups = group(histogram(of: pixels))
        var palette: [UInt32] = []
        var entry: [UInt32: UInt8] = [:]
        for (index, members) in groups.enumerated() {
            palette.append(mean(of: members))
            for member in members { entry[member.color] = UInt8(index) }
        }
        var indices = [UInt8](repeating: 0, count: pixels.count)
        var previous: (color: UInt32, index: UInt8)?
        for (position, color) in pixels.enumerated() {
            if let previous, previous.color == color {
                indices[position] = previous.index
                continue
            }
            let index = entry[color]!
            indices[position] = index
            previous = (color, index)
        }
        return PalettedImage(width: width, height: height, palette: palette, indices: indices)
    }

    struct ColorCount {
        let color: UInt32
        let count: Int
    }

    /// Fully transparent pixels collapse into one entry: the color under alpha 0 never shows.
    private static func packed(_ rgba: [UInt8]) -> [UInt32] {
        (0..<rgba.count / 4).map { pixel in
            let offset = pixel * 4
            guard rgba[offset + 3] > 0 else { return 0 }
            return UInt32(rgba[offset]) << 24 | UInt32(rgba[offset + 1]) << 16 | UInt32(rgba[offset + 2]) << 8 | UInt32(rgba[offset + 3])
        }
    }

    /// Captures repeat a color across long runs (backgrounds, panels), so each run costs one dictionary update.
    private static func histogram(of pixels: [UInt32]) -> [ColorCount] {
        var counts: [UInt32: Int] = [:]
        var start = 0
        while start < pixels.count {
            let color = pixels[start]
            var end = start + 1
            while end < pixels.count, pixels[end] == color { end += 1 }
            counts[color, default: 0] += end - start
            start = end
        }
        return counts.map { ColorCount(color: $0.key, count: $0.value) }.sorted { $0.color < $1.color }
    }

    private static func group(_ colors: [ColorCount]) -> [ArraySlice<ColorCount>] {
        guard colors.count > maxColors else { return colors.indices.map { colors[$0...$0] } }
        var colors = colors
        var boxes = [Box(colors[...])]
        while boxes.count < maxColors {
            let widest = boxes.indices.max { boxes[$0].error < boxes[$1].error }!
            guard boxes[widest].error > 0 else { break }
            let box = boxes[widest]
            colors[box.range].sort { channel(box.axis, of: $0.color) < channel(box.axis, of: $1.color) }
            let split = leastErrorSplit(colors[box.range])
            boxes[widest] = Box(colors[box.range.lowerBound..<split])
            boxes.append(Box(colors[split..<box.range.upperBound]))
        }
        return boxes.map { colors[$0.range] }
    }

    /// Where to cut colors sorted along one channel so the two halves stray least from their own means. A cut at the
    /// weighted median instead left a 16-level gradient patch in one group, 14 levels off at its edge.
    private static func leastErrorSplit(_ sorted: ArraySlice<ColorCount>) -> Int {
        let total = Moments(sorted)
        var left = Moments()
        var best = (index: sorted.startIndex + 1, error: Double.infinity)
        for index in sorted.indices.dropLast() {
            left.add(sorted[index])
            let error = left.error + total.subtracting(left).error
            if error < best.error { best = (index + 1, error) }
        }
        return best.index
    }

    /// Pixel-weighted sums per channel, enough to get a group's squared distance from its mean in one pass.
    private struct Moments {
        var weight = 0.0
        var sums = SIMD4<Double>()
        var squares = SIMD4<Double>()

        init() {}

        init(_ colors: ArraySlice<ColorCount>) {
            for member in colors { add(member) }
        }

        mutating func add(_ member: ColorCount) {
            let count = Double(member.count)
            let color = member.color
            let value = SIMD4(Double(color >> 24), Double(color >> 16 & 0xFF), Double(color >> 8 & 0xFF), Double(color & 0xFF))
            weight += count
            sums += count * value
            squares += count * value * value
        }

        func subtracting(_ other: Moments) -> Moments {
            var rest = Moments()
            rest.weight = weight - other.weight
            rest.sums = sums - other.sums
            rest.squares = squares - other.squares
            return rest
        }

        var spread: SIMD4<Double> {
            weight > 0 ? squares - sums * sums / weight : SIMD4()
        }

        var error: Double { spread.sum() }
    }

    private struct Box {
        let range: Range<Int>
        /// Pixel-weighted squared distance of the box's colors from their mean, over all four channels.
        let error: Double
        /// The channel the colors spread furthest along: where the next split cuts.
        let axis: Int

        init(_ colors: ArraySlice<ColorCount>) {
            range = colors.indices
            let moments = Moments(colors)
            let spread = moments.spread
            error = colors.count > 1 ? moments.error : 0
            axis = (0..<4).max { spread[$0] < spread[$1] }!
        }
    }

    private static func mean(of members: ArraySlice<ColorCount>) -> UInt32 {
        let weight = Double(members.reduce(0) { $0 + $1.count })
        return (0..<4).reduce(UInt32(0)) { packed, axis in
            let sum = members.reduce(0.0) { $0 + Double($1.count) * Double(channel(axis, of: $1.color)) }
            return packed | UInt32((sum / weight).rounded()) << UInt32(24 - axis * 8)
        }
    }

    /// 0 red, 1 green, 2 blue, 3 alpha.
    static func channel(_ axis: Int, of color: UInt32) -> UInt8 {
        UInt8(truncatingIfNeeded: color >> UInt32(24 - axis * 8))
    }
}
