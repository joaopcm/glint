import CoreGraphics
import Foundation

public struct StitchTuning: Sendable {
    public var sampleStride: Int
    public var minMatchFraction: Double
    public var minDistinctRows: Int
    public var maxOutputHeight: Int
    public var floatingBlockSize: Int

    public init(sampleStride: Int, minMatchFraction: Double, minDistinctRows: Int, maxOutputHeight: Int, floatingBlockSize: Int) {
        self.sampleStride = sampleStride
        self.minMatchFraction = minMatchFraction
        self.minDistinctRows = minDistinctRows
        self.maxOutputHeight = maxOutputHeight
        self.floatingBlockSize = floatingBlockSize
    }
}

extension StitchTuning {
    public static let measured = StitchTuning(
        // docs/perf/2026-11-scrolling-capture.md, Task 3 "sampleStride": 1–64 all stitch both pages; 8 is 3.3–3.6x faster than 1
        sampleStride: 8,
        // same doc, "minMatchFraction": late-painted frames need >= 0.70, the worst real pair matches 0.7711
        minMatchFraction: 0.73,
        // same doc, "minDistinctRows": wrong shifts on Notion match <= 24 rows at stride 8, real pairs >= 620
        minDistinctRows: 32,
        // same doc, "maxOutputHeight": past Slack's 25,000 px inline preview; 80,000 px peaks ~2.9 GB to stitch and save
        maxOutputHeight: 40_000,
        // same doc, "floatingBlockSize": 1 can never float; 2 sees a 2-row toast (toastOneBlockTallAppearsOnce(block: 2))
        floatingBlockSize: 2
    )
}

public struct StitchUpdate: Sendable, Equatable {
    public enum State: Sendable, Equatable { case tracking, lostOverlap, heightLimitReached(limit: Int) }
    public let state: State
    public let height: Int
    public let appendedRows: Int
}

public final class Stitcher {
    private struct Bands {
        var columns: Range<Int>
        var headerRows: Int
    }

    private struct MovingRows {
        let signatures: [UInt64]
        let uniform: [Bool]

        init(_ frame: Frame, bands: Bands, stride: Int) {
            signatures = Array(frame.rowSignatures(columns: bands.columns, stride: stride)[bands.headerRows...])
            uniform = (bands.headerRows..<frame.height).map { frame.isUniformRow($0, columns: bands.columns) }
        }

        var count: Int { signatures.count }

        func index() -> VoteIndex {
            var rowsBySignature: [UInt64: [Int]] = [:]
            for row in 0..<count where !uniform[row] {
                rowsBySignature[signatures[row], default: []].append(row)
            }
            return VoteIndex(rowsBySignature: rowsBySignature)
        }
    }

    private struct VoteIndex {
        let rowsBySignature: [UInt64: [Int]]
        let uniqueRowsOnly: Bool
        let rowsThatNeverVote: Int

        init(rowsBySignature: [UInt64: [Int]]) {
            self.rowsBySignature = rowsBySignature
            uniqueRowsOnly = rowsBySignature.values.contains { $0.count == 1 }
            rowsThatNeverVote = uniqueRowsOnly ? rowsBySignature.values.reduce(0) { $1.count > 1 ? $0 + $1.count : $0 } : 0
        }

        func voters(for signature: UInt64) -> [Int] {
            guard let rows = rowsBySignature[signature], !uniqueRowsOnly || rows.count == 1 else { return [] }
            return rows
        }
    }

    private struct Reference {
        let frame: Frame
        let top: Int
        let rows: MovingRows
        let index: VoteIndex
    }

    private struct Placed {
        let frame: Frame
        let top: Int
    }

    private struct Match {
        let shift: Int
        let matchedRows: Int
    }

    private let tuning: StitchTuning
    private let first: Frame
    private var bands: Bands
    private var bandsLearned = false
    private var reference: Reference
    private var deepest: Placed
    private var committed: [UInt8] = []
    private var committedRows = 0
    private var lastShift = 0
    private var reachedHeightLimit = false
    private(set) var floatingZone = 0
    private(set) var rowComparisons = 0
    var referenceTop: Int { reference.top }
    var contentColumns: Range<Int> { bands.columns }
    var headerRows: Int { bands.headerRows }

    public init(first: Frame, tuning: StitchTuning) {
        self.tuning = tuning
        self.first = first
        bands = Bands(columns: 0..<first.width, headerRows: 0)
        let rows = MovingRows(first, bands: bands, stride: tuning.sampleStride)
        reference = Reference(frame: first, top: 0, rows: rows, index: rows.index())
        deepest = Placed(frame: first, top: 0)
    }

    public func append(_ frame: Frame) -> StitchUpdate {
        precondition(
            frame.width == first.width && frame.height == first.height,
            "Stitcher frames must all be \(first.width)x\(first.height), got \(frame.width)x\(frame.height)"
        )
        let heightBefore = height
        func update(_ state: StitchUpdate.State) -> StitchUpdate {
            StitchUpdate(state: state, height: height, appendedRows: height - heightBefore)
        }
        if reachedHeightLimit { return update(.heightLimitReached(limit: tuning.maxOutputHeight)) }

        let rows: MovingRows
        let match: Match?
        if bandsLearned {
            rows = MovingRows(frame, bands: bands, stride: tuning.sampleStride)
            match = bestShift(of: rows, against: reference.rows, index: reference.index)
        } else {
            if frame.pixels == reference.frame.pixels || isSameView(frame) { return update(.tracking) }
            let candidate = learnBands(reference.frame, frame)
            let candidateReference = MovingRows(reference.frame, bands: candidate, stride: tuning.sampleStride)
            let candidateIndex = candidateReference.index()
            rows = MovingRows(frame, bands: candidate, stride: tuning.sampleStride)
            match = bestShift(of: rows, against: candidateReference, index: candidateIndex)
            guard let match, match.shift != 0 else { return update(match == nil ? .lostOverlap : .tracking) }
            bands = candidate
            bandsLearned = true
            reference = Reference(frame: reference.frame, top: reference.top, rows: candidateReference, index: candidateIndex)
        }

        guard let match else { return update(.lostOverlap) }
        guard match.shift != 0 else { return update(.tracking) }
        accept(frame, rows: rows, shift: match.shift)
        if naturalHeight > tuning.maxOutputHeight {
            reachedHeightLimit = true
            return update(.heightLimitReached(limit: tuning.maxOutputHeight))
        }
        return update(.tracking)
    }

    public func image() -> CGImage? {
        makeImage(rows: 0..<height)
    }

    public func tail(maxRows: Int) -> CGImage? {
        let height = height
        return makeImage(rows: max(0, height - maxRows)..<height)
    }

    private var movingRowCount: Int { first.height - bands.headerRows }

    private var naturalHeight: Int {
        bands.headerRows + max(committedRows, deepest.top + movingRowCount)
    }

    private var height: Int { min(naturalHeight, tuning.maxOutputHeight) }

    private func isSameView(_ frame: Frame) -> Bool {
        let rows = MovingRows(frame, bands: bands, stride: tuning.sampleStride)
        let (matched, compared) = overlap(at: 0, of: rows, against: reference.rows)
        return qualifies(matched: matched, compared: compared)
    }

    private func learnBands(_ a: Frame, _ b: Frame) -> Bands {
        let width = a.width
        let aColumns = a.columnSignatures(stride: 1), bColumns = b.columnSignatures(stride: 1)
        var leading = 0
        while leading < width && aColumns[leading] == bColumns[leading] { leading += 1 }
        var trailing = width
        while trailing > leading && aColumns[trailing - 1] == bColumns[trailing - 1] { trailing -= 1 }
        while leading > 0 && a.isUniformColumn(leading - 1) { leading -= 1 }
        while trailing < width && a.isUniformColumn(trailing) { trailing += 1 }
        let columns = leading < trailing ? leading..<trailing : 0..<width

        let aRows = a.rowSignatures(columns: columns, stride: 1), bRows = b.rowSignatures(columns: columns, stride: 1)
        var header = 0
        while header < a.height && aRows[header] == bRows[header] { header += 1 }
        while header > 0 && a.isUniformRow(header - 1, columns: columns) { header -= 1 }
        return Bands(columns: columns, headerRows: header < a.height ? header : 0)
    }

    private func bestShift(of rows: MovingRows, against old: MovingRows, index: VoteIndex) -> Match? {
        var votes: [Int: Int] = [:]
        for row in 0..<rows.count where !rows.uniform[row] {
            for oldRow in index.voters(for: rows.signatures[row]) {
                votes[oldRow - row, default: 0] += 1
                rowComparisons += 1
            }
        }
        let candidates = votes.sorted {
            $0.value != $1.value ? $0.value > $1.value : isPreferred($0.key, over: $1.key)
        }
        var best: Match?
        for (shift, voteCount) in candidates {
            if let best, voteCount + index.rowsThatNeverVote < best.matchedRows { break }
            let (matched, compared) = overlap(at: shift, of: rows, against: old)
            guard qualifies(matched: matched, compared: compared) else { continue }
            if let current = best, matched < current.matchedRows || (matched == current.matchedRows && !isPreferred(shift, over: current.shift)) {
                continue
            }
            best = Match(shift: shift, matchedRows: matched)
        }
        return best
    }

    private func isPreferred(_ shift: Int, over other: Int) -> Bool {
        (abs(shift - lastShift), abs(shift), shift) < (abs(other - lastShift), abs(other), other)
    }

    private func overlap(at shift: Int, of rows: MovingRows, against old: MovingRows) -> (matched: Int, compared: Int) {
        var matched = 0, compared = 0
        let rowsAboveFloatingZone = rows.count - floatingZone
        let firstRow = max(0, -shift), endRow = min(rowsAboveFloatingZone, rowsAboveFloatingZone - shift)
        guard firstRow < endRow else { return (0, 0) }
        for row in firstRow..<endRow {
            let oldRow = row + shift
            if rows.uniform[row] && old.uniform[oldRow] { continue }
            compared += 1
            rowComparisons += 1
            if !rows.uniform[row] && !old.uniform[oldRow] && rows.signatures[row] == old.signatures[oldRow] { matched += 1 }
        }
        return (matched, compared)
    }

    private func qualifies(matched: Int, compared: Int) -> Bool {
        matched >= tuning.minDistinctRows && Double(matched) >= tuning.minMatchFraction * Double(compared)
    }

    private func accept(_ frame: Frame, rows: MovingRows, shift: Int) {
        let top = reference.top + shift
        updateFloatingZone(old: reference.frame, new: frame)
        // The new frame no longer shows rows above its top, so they come from the old one even under its floating
        // zone; otherwise the page would skip them.
        commit(Placed(frame: reference.frame, top: reference.top), through: max(reference.top + movingRowCount - floatingZone, top))
        reference = Reference(frame: frame, top: top, rows: rows, index: rows.index())
        lastShift = shift
        if top >= deepest.top { deepest = Placed(frame: frame, top: top) }
    }

    private func updateFloatingZone(old: Frame, new: Frame) {
        let block = tuning.floatingBlockSize
        let columns = bands.columns
        let blockColumns = stride(from: columns.lowerBound, to: columns.upperBound, by: block).map { $0..<min($0 + block, columns.upperBound) }
        var zoneTop = first.height
        var floatingColumns: [Range<Int>] = []
        while zoneTop - block >= bands.headerRows {
            let blockRows = (zoneTop - block)..<zoneTop
            let floating = blockColumns.filter { isFloatingBlock(old, new, rows: blockRows, columns: $0) }
            guard !floating.isEmpty else { break }
            floatingColumns = floating
            zoneTop -= block
        }
        guard !floatingColumns.isEmpty else { return }
        let partialBlockTop = max(bands.headerRows, zoneTop - block + 1)
        while zoneTop > partialBlockTop && floatingColumns.contains(where: { isFloatingRow(old, new, row: zoneTop - 1, columns: $0) }) {
            zoneTop -= 1
        }
        floatingZone = max(floatingZone, first.height - zoneTop)
    }

    private func isFloatingBlock(_ old: Frame, _ new: Frame, rows: Range<Int>, columns: Range<Int>) -> Bool {
        let firstRow = segment(old, row: rows.lowerBound, columns: columns)
        var hasDistinctRows = false
        for row in rows {
            let oldSegment = segment(old, row: row, columns: columns)
            guard oldSegment == segment(new, row: row, columns: columns) else { return false }
            if !hasDistinctRows && oldSegment != firstRow { hasDistinctRows = true }
        }
        return hasDistinctRows
    }

    private func isFloatingRow(_ old: Frame, _ new: Frame, row: Int, columns: Range<Int>) -> Bool {
        !old.isUniformRow(row, columns: columns) && segment(old, row: row, columns: columns) == segment(new, row: row, columns: columns)
    }

    private func segment(_ frame: Frame, row: Int, columns: Range<Int>) -> ArraySlice<UInt8> {
        let start = row * frame.bytesPerRow
        return frame.pixels[(start + columns.lowerBound * 4)..<(start + columns.upperBound * 4)]
    }

    private func commit(_ placed: Placed, through line: Int) {
        let end = min(line, placed.top + movingRowCount, tuning.maxOutputHeight - bands.headerRows)
        guard end > committedRows else { return }
        precondition(committedRows >= placed.top, "commit would leave a gap: committed \(committedRows) rows, frame starts at \(placed.top)")
        let needed = committed.count + (end - committedRows) * bands.columns.count * 4
        if committed.capacity < needed { committed.reserveCapacity(max(needed, committed.capacity * 2)) }
        for row in committedRows..<end {
            committed.append(contentsOf: segment(placed.frame, row: bands.headerRows + row - placed.top, columns: bands.columns))
        }
        committedRows = end
    }

    private func makeImage(rows: Range<Int>) -> CGImage? {
        let rowBytes = bands.columns.count * 4
        guard !rows.isEmpty, let buffer = NSMutableData(length: rowBytes * rows.count) else { return nil }
        for (index, row) in rows.enumerated() {
            let contentRow = row - bands.headerRows
            let source = if row < bands.headerRows {
                segment(first, row: row, columns: bands.columns)
            } else if contentRow < committedRows {
                committed[(contentRow * rowBytes)..<((contentRow + 1) * rowBytes)]
            } else {
                segment(deepest.frame, row: bands.headerRows + contentRow - deepest.top, columns: bands.columns)
            }
            source.withUnsafeBytes { buffer.mutableBytes.advanced(by: index * rowBytes).copyMemory(from: $0.baseAddress!, byteCount: rowBytes) }
        }
        guard let provider = CGDataProvider(data: buffer) else { return nil }
        return CGImage(
            width: bands.columns.count, height: rows.count, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: first.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
