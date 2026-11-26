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
            #expect(path.contains(CGPoint(x: line.midX, y: line.midY), using: .evenOdd))
            #expect(path.contains(CGPoint(x: line.minX + line.height, y: line.midY), using: .evenOdd))
            #expect(path.contains(CGPoint(x: line.maxX - line.height, y: line.midY), using: .evenOdd))
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
            return path.contains(topLeft, using: .evenOdd) && path.contains(bottomRight, using: .evenOdd)
        }
        #expect(squareCorners.count < 10)
    }
}
