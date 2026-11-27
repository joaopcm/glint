import CoreGraphics

/// A marker-pen stroke over one line of text: solid ink with gently wavy edges and lightly frayed ends.
/// Every size is a fraction of the line's height, so a stroke reads the same at any zoom or font size.
/// The seed fixes the shape, so a stroke never shimmers between redraws.
enum BrushStroke {
    private static let edgeWobble: CGFloat = 0.06
    private static let edgeStep: CGFloat = 0.75
    private static let frayDepth: CGFloat = 0.12
    private static let frayReach: CGFloat = 0.08

    static func path(in rect: CGRect, seed: UInt64) -> CGPath {
        var random = SplitMix64(seed: seed)
        let height = rect.height
        let path = CGMutablePath()

        let left = frayedEnd(at: rect.minX, inward: 1, rect: rect, random: &random)
        let right = frayedEnd(at: rect.maxX, inward: -1, rect: rect, random: &random)
        let top = edge(at: rect.minY, from: left.last!.x, to: right.first!.x, lineHeight: height, random: &random)
        let bottom = edge(at: rect.maxY, from: right.last!.x, to: left.first!.x, lineHeight: height, random: &random)

        path.move(to: left[0])
        addSmooth(left.dropFirst() + top + right + bottom, to: path)
        path.closeSubpath()
        return path
    }

    /// Bristle tips and notches along one end, bottom to top on the left and top to bottom on the right.
    private static func frayedEnd(at x: CGFloat, inward: CGFloat, rect: CGRect, random: inout SplitMix64) -> [CGPoint] {
        let height = rect.height
        let bands = Int.random(in: 3...5, using: &random)
        var points: [CGPoint] = []
        for band in 0..<bands {
            let t = (CGFloat(band) + 0.5) / CGFloat(bands)
            let notch = x + inward * CGFloat.random(in: 0.02...frayDepth, using: &random) * height
            let tip = x - inward * CGFloat.random(in: -frayDepth...frayReach, using: &random) * height
            let notchY = CGFloat(band) / CGFloat(bands)
            points.append(CGPoint(x: notch, y: notchY))
            points.append(CGPoint(x: tip, y: t))
        }
        points.append(CGPoint(x: x + inward * CGFloat.random(in: 0.02...frayDepth, using: &random) * height, y: 1))
        let ordered = inward > 0 ? points.map { CGPoint(x: $0.x, y: 1 - $0.y) } : points
        return ordered.map { CGPoint(x: $0.x, y: rect.minY + $0.y * height) }
    }

    private static func edge(at y: CGFloat, from start: CGFloat, to end: CGFloat, lineHeight: CGFloat, random: inout SplitMix64) -> [CGPoint] {
        let span = end - start
        let count = max(Int(abs(span) / (edgeStep * lineHeight)), 1)
        return (1..<count).map { i in
            let x = start + span * CGFloat(i) / CGFloat(count)
            return CGPoint(x: x, y: y + CGFloat.random(in: -edgeWobble...edgeWobble, using: &random) * lineHeight)
        }
    }

    private static func addSmooth(_ points: some Collection<CGPoint>, to path: CGMutablePath) {
        var previous = path.currentPoint
        for point in points {
            path.addQuadCurve(to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), control: previous)
            previous = point
        }
        path.addLine(to: previous)
    }
}

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
