import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import LunettaEditor

func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}

let threeLines = TextLayout(lines: [
    [r(0, 0, 40, 20), r(50, 0, 40, 20), r(100, 0, 40, 20)],
    [r(0, 30, 40, 20), r(50, 30, 40, 20)],
    [r(0, 60, 40, 20), r(50, 60, 40, 20)],
])

struct TextLayoutTests {
    typealias Position = TextLayout.Position

    private func unpadded(_ rects: [CGRect]) -> [CGRect] {
        rects.map { padded in
            let height = padded.height / (1 + 2 * TextLayout.verticalPadding)
            return padded.insetBy(dx: TextLayout.horizontalPadding * height, dy: TextLayout.verticalPadding * height)
        }
    }

    @Test func sameLineRange() {
        let rects = threeLines.highlight(from: Position(line: 0, word: 1), to: Position(line: 0, word: 2))
        #expect(unpadded(rects) == [r(50, 0, 90, 20)])
    }

    @Test func acrossLines() {
        let rects = threeLines.highlight(from: Position(line: 0, word: 1), to: Position(line: 2, word: 0))
        #expect(unpadded(rects) == [r(50, 0, 90, 20), r(0, 30, 90, 20), r(0, 60, 40, 20)])
    }

    @Test func backwardEqualsForward() {
        let a = Position(line: 0, word: 1), b = Position(line: 2, word: 0)
        #expect(threeLines.highlight(from: b, to: a) == threeLines.highlight(from: a, to: b))
    }

    @Test func singleWord() {
        let word = Position(line: 1, word: 1)
        #expect(unpadded(threeLines.highlight(from: word, to: word)) == [r(50, 30, 40, 20)])
    }

    @Test func positionHitsWordWithPad() {
        #expect(threeLines.position(at: CGPoint(x: 45, y: 10), pad: 6) == Position(line: 0, word: 0))
        #expect(threeLines.position(at: CGPoint(x: 45, y: 10), pad: 2) == nil)
    }

    @Test func endPointOffTextUsesNearestWord() {
        #expect(threeLines.nearestPosition(to: CGPoint(x: 300, y: 200)) == Position(line: 2, word: 1))
        #expect(threeLines.nearestPosition(to: CGPoint(x: 200, y: 5)) == Position(line: 0, word: 2))
    }

    @Test func emptyLayoutHasNoPositions() {
        #expect(TextLayout(lines: []).nearestPosition(to: .zero) == nil)
    }
}

func twoLinesFixture() throws -> CGImage {
    let url = try #require(Bundle.module.url(forResource: "two-lines", withExtension: "png", subdirectory: "Fixtures"))
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

struct TextLayoutRecognitionTests {
    @Test func recognizesTwoLinesOfWords() async throws {
        let image = try twoLinesFixture()
        let layout = await TextLayout.recognize(in: image)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        #expect(layout.lines.map(\.count) == [4, 5])
        #expect(layout.lines[0][0].minY < layout.lines[1][0].minY)
        #expect(layout.lines.joined().allSatisfy { bounds.contains($0) })
        #expect(layout.lines[0][0].maxX < layout.lines[0][1].minX)
    }

    @Test func blankImageHasNoLines() async {
        #expect(await TextLayout.recognize(in: solidImage(width: 200, height: 100)).lines.isEmpty)
    }
}
