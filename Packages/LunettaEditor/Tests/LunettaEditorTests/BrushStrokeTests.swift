import CoreGraphics
import Testing
@testable import LunettaEditor

struct BrushStrokeTests {
    let line = r(100, 50, 300, 40)

    @Test func sameSeedDrawsTheSameStroke() {
        #expect(BrushStroke.path(in: line, seed: 7) == BrushStroke.path(in: line, seed: 7))
    }

    @Test func differentSeedsDrawDifferentStrokes() {
        #expect(BrushStroke.path(in: line, seed: 7) != BrushStroke.path(in: line, seed: 8))
    }

    @Test func strokeCoversTheLineMiddle() {
        for seed: UInt64 in 0..<50 {
            let path = BrushStroke.path(in: line, seed: seed)
            #expect(path.contains(CGPoint(x: line.midX, y: line.midY)))
            #expect(path.contains(CGPoint(x: line.minX + line.height, y: line.midY)))
            #expect(path.contains(CGPoint(x: line.maxX - line.height, y: line.midY)))
        }
    }

    @Test func strokeStaysNearTheLine() {
        let reach = line.insetBy(dx: -line.height * 0.3, dy: -line.height * 0.1)
        for seed: UInt64 in 0..<50 {
            #expect(reach.contains(BrushStroke.path(in: line, seed: seed).boundingBoxOfPath))
        }
    }

    @Test func strokeHasRaggedEnds() {
        let topLeft = CGPoint(x: line.minX + 1, y: line.minY + 1)
        let bottomRight = CGPoint(x: line.maxX - 1, y: line.maxY - 1)
        let squareCorners = (0..<50).filter { seed in
            let path = BrushStroke.path(in: line, seed: UInt64(seed))
            return path.contains(topLeft) && path.contains(bottomRight)
        }
        #expect(squareCorners.count < 10)
    }

    @Test func strokeIsSolidInside() {
        let inside = line.insetBy(dx: line.height * 0.2, dy: line.height * 0.15)
        for seed: UInt64 in 0..<50 {
            let path = BrushStroke.path(in: line, seed: seed)
            for x in stride(from: inside.minX, through: inside.maxX, by: 4) {
                for y in stride(from: inside.minY, through: inside.maxY, by: 2) {
                    #expect(path.contains(CGPoint(x: x, y: y)), "seed \(seed) left a gap at (\(x), \(y))")
                }
            }
        }
    }
}
