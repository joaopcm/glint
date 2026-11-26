import CoreGraphics

/// Word boxes in image pixels, top-left origin: one array per line in reading order, words left to right.
public struct TextLayout: Equatable, Sendable {
    public struct Position: Comparable, Hashable, Sendable {
        let line: Int
        let word: Int

        public static func < (a: Position, b: Position) -> Bool {
            (a.line, a.word) < (b.line, b.word)
        }
    }

    public let lines: [[CGRect]]

    static let verticalPadding: CGFloat = 0.15
    static let horizontalPadding: CGFloat = 0.1

    public init(lines: [[CGRect]]) {
        self.lines = lines
    }

    func position(at point: CGPoint, pad: CGFloat) -> Position? {
        positions.first { word($0).insetBy(dx: -pad, dy: -pad).contains(point) }
    }

    /// The closest line by height wins, then the closest word on it, like extending a text selection past the text.
    func nearestPosition(to point: CGPoint) -> Position? {
        let nonEmpty = lines.indices.filter { !lines[$0].isEmpty }
        guard let line = nonEmpty.min(by: { gap(point.y, lineSpan($0)) < gap(point.y, lineSpan($1)) }) else { return nil }
        let words = lines[line]
        let word = words.indices.min { gap(point.x, words[$0].minX...words[$0].maxX) < gap(point.x, words[$1].minX...words[$1].maxX) }!
        return Position(line: line, word: word)
    }

    /// One padded rect per line, from the earlier position's word to the later one's, in reading order.
    func highlight(from a: Position, to b: Position) -> [CGRect] {
        let (first, last) = (min(a, b), max(a, b))
        return (first.line...last.line).map { line in
            let words = lines[line]
            let from = line == first.line ? first.word : 0
            let to = line == last.line ? last.word : words.count - 1
            let union = words[from...to].reduce(words[from]) { $0.union($1) }
            return union.insetBy(dx: -Self.horizontalPadding * union.height, dy: -Self.verticalPadding * union.height)
        }
    }

    private var positions: [Position] {
        lines.indices.flatMap { line in lines[line].indices.map { Position(line: line, word: $0) } }
    }

    private func word(_ position: Position) -> CGRect {
        lines[position.line][position.word]
    }

    private func lineSpan(_ line: Int) -> ClosedRange<CGFloat> {
        let union = lines[line].reduce(lines[line][0]) { $0.union($1) }
        return union.minY...union.maxY
    }

    private func gap(_ value: CGFloat, _ span: ClosedRange<CGFloat>) -> CGFloat {
        max(span.lowerBound - value, 0, value - span.upperBound)
    }
}
