import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import Testing
@testable import LunettaCapture

func page(width: Int, height: Int) -> Frame {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            if x == 0 {
                pixels[offset] = UInt8(truncatingIfNeeded: y)
                pixels[offset + 1] = UInt8(truncatingIfNeeded: y >> 8)
                pixels[offset + 2] = UInt8(truncatingIfNeeded: y >> 16)
            } else {
                let mixed = UInt32(truncatingIfNeeded: y) &* 2_654_435_761 ^ UInt32(truncatingIfNeeded: x) &* 40_503
                pixels[offset] = UInt8(truncatingIfNeeded: mixed)
                pixels[offset + 1] = UInt8(truncatingIfNeeded: mixed >> 8)
                pixels[offset + 2] = UInt8(truncatingIfNeeded: mixed >> 16)
            }
        }
    }
    return Frame(width: width, height: height, bytesPerRow: width * 4, pixels: pixels)
}

func viewports(
    of page: Frame, tops: [Int], height: Int, header: Int = 0, footer: Int = 0, sidebar: Int = 0,
    widget: CGRect? = nil, widgetFrom: Int = 0
) -> [Frame] {
    tops.enumerated().map { index, top in
        viewport(of: page, top: top, height: height, header: header, footer: footer, sidebar: sidebar, widget: index >= widgetFrom ? widget : nil)
    }
}

func viewport(of page: Frame, top: Int, height: Int, header: Int = 0, footer: Int = 0, sidebar: Int = 0, widget: CGRect? = nil) -> Frame {
    let width = page.width
    var pixels = Array(page.pixels[(top * width * 4)..<((top + height) * width * 4)])

    func paint(rows: Range<Int>, columns: Range<Int>, seed: UInt8) {
        for y in rows {
            for x in columns {
                let offset = (y * width + x) * 4
                pixels[offset] = seed &+ UInt8(truncatingIfNeeded: x &* 3 &+ y)
                pixels[offset + 1] = seed ^ UInt8(truncatingIfNeeded: x)
                pixels[offset + 2] = seed &+ UInt8(truncatingIfNeeded: y)
                pixels[offset + 3] = 255
            }
        }
    }

    paint(rows: 0..<height, columns: 0..<sidebar, seed: 11)
    paint(rows: 0..<header, columns: 0..<width, seed: 53)
    paint(rows: (height - footer)..<height, columns: 0..<width, seed: 97)
    if let widget {
        paint(rows: Int(widget.minY)..<Int(widget.maxY), columns: Int(widget.minX)..<Int(widget.maxX), seed: 151)
    }
    return Frame(width: width, height: height, bytesPerRow: width * 4, pixels: pixels)
}

private func solid(width: Int, height: Int, value: UInt8 = 7) -> Frame {
    Frame(width: width, height: height, bytesPerRow: width * 4, pixels: [UInt8](repeating: value, count: width * height * 4))
}

private func set(_ frame: Frame, x: Int, y: Int, to value: UInt8) -> Frame {
    var pixels = frame.pixels
    let offset = y * frame.bytesPerRow + x * 4
    pixels.replaceSubrange(offset..<(offset + 4), with: [UInt8](repeating: value, count: 4))
    return Frame(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, pixels: pixels)
}

@Test func identicalRowsShareASignature() {
    let source = page(width: 64, height: 300)
    let a = viewport(of: source, top: 40, height: 100)
    let b = viewport(of: source, top: 40, height: 100)
    let signatures = a.rowSignatures(columns: 0..<64, stride: 3)
    #expect(signatures == b.rowSignatures(columns: 0..<64, stride: 3))
    #expect(Set(signatures).count == signatures.count)
}

@Test func shiftedFrameSignaturesLineUp() {
    let source = page(width: 64, height: 300)
    let a = viewport(of: source, top: 0, height: 100)
    let b = viewport(of: source, top: 10, height: 100)
    let aRows = a.rowSignatures(columns: 0..<64, stride: 1)
    let bRows = b.rowSignatures(columns: 0..<64, stride: 1)
    #expect(Array(aRows[10...]) == Array(bRows[..<90]))
}

@Test func strideStillSeesLastPixel() {
    let base = solid(width: 52, height: 2)
    let frame = set(base, x: 51, y: 1, to: 200)
    let rows = frame.rowSignatures(columns: 0..<52, stride: 7)
    #expect(rows[0] != rows[1])
}

@Test func strideSkipsPixelsBetweenSamples() {
    let base = solid(width: 52, height: 2)
    let frame = set(base, x: 3, y: 1, to: 200)
    let rows = frame.rowSignatures(columns: 0..<52, stride: 7)
    #expect(rows[0] == rows[1])
}

@Test func columnSignaturesLineUpAcrossColumnShift() {
    let source = page(width: 64, height: 100)
    let whole = source.columnSignatures(stride: 1)
    let shifted = source.cropped(columns: 5..<64, rows: 0..<100).columnSignatures(stride: 1)
    #expect(Array(whole[5...]) == shifted)
    #expect(Set(whole).count == whole.count)
}

@Test func columnStrideStillSeesLastRow() {
    let base = solid(width: 2, height: 52)
    let frame = set(base, x: 1, y: 51, to: 200)
    let columns = frame.columnSignatures(stride: 7)
    #expect(columns[0] != columns[1])
}

@Test func uniformRowAndColumnNeedEveryPixelIdentical() {
    let frame = set(solid(width: 8, height: 6), x: 2, y: 4, to: 200)
    #expect(frame.isUniformRow(3, columns: 0..<8))
    #expect(!frame.isUniformRow(4, columns: 0..<8))
    #expect(frame.isUniformRow(4, columns: 3..<8))
    #expect(frame.isUniformColumn(1))
    #expect(!frame.isUniformColumn(2))
}

@Test func croppedKeepsTheRequestedPixels() {
    let source = page(width: 20, height: 30)
    let crop = source.cropped(columns: 4..<12, rows: 10..<25)
    #expect(crop.width == 8)
    #expect(crop.height == 15)
    #expect(crop.bytesPerRow == 32)
    for y in 0..<15 {
        let sourceStart = (10 + y) * source.bytesPerRow + 4 * 4
        #expect(Array(crop.pixels[(y * 32)..<(y * 32 + 32)]) == Array(source.pixels[sourceStart..<(sourceStart + 32)]))
    }
}

@Test func frameRoundTripsCGImage() throws {
    let width = 9, height = 5
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for i in 0..<(width * height) {
        rgba[i * 4] = UInt8(i * 5)
        rgba[i * 4 + 1] = UInt8(i * 3)
        rgba[i * 4 + 2] = UInt8(i)
    }
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    let image = try #require(CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: sRGB,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ))

    var expected = [UInt8](repeating: 0, count: width * height * 4)
    expected.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    let frame = try #require(Frame(image))
    let all = frame.cropped(columns: 0..<width, rows: 0..<height)
    #expect(all.pixels == expected)
    #expect(Array(all.pixels[0..<4]) == [rgba[2], rgba[1], rgba[0], 255])
    #expect(Array(all.pixels[4..<8]) == [rgba[6], rgba[5], rgba[4], 255])
}

@Test func frameReadsBGRAPixelBufferWithPaddedRows() throws {
    let width = 5, height = 3
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    let pixelBuffer = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    var expected: [UInt8] = []
    for y in 0..<height {
        for i in 0..<(width * 4) {
            let value = UInt8(y * 40 + i)
            base[y * stride + i] = value
            expected.append(value)
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    let frame = try #require(Frame(pixelBuffer))
    #expect(frame.width == width)
    #expect(frame.height == height)
    #expect(frame.pixels == expected)
}

@Test func frameRejectsNonBGRAPixelBuffer() throws {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32ARGB, nil, &buffer)
    #expect(Frame(try #require(buffer)) == nil)
}

private let tuning = StitchTuning(sampleStride: 1, minMatchFraction: 0.9, minDistinctRows: 8, maxOutputHeight: 100_000, floatingBlockSize: 16)

private func stitch(_ frames: [Frame], tuning: StitchTuning = tuning) -> (Stitcher, [StitchUpdate]) {
    let stitcher = Stitcher(first: frames[0], tuning: tuning)
    return (stitcher, frames.dropFirst().map { stitcher.append($0) })
}

private func bytes(_ image: CGImage?) throws -> [UInt8] {
    let image = try #require(image)
    #expect(image.bytesPerRow == image.width * 4)
    return Array(try #require(image.dataProvider?.data) as Data)
}

private func rows(_ frame: Frame, _ rows: Range<Int>, columns: Range<Int>? = nil) -> [UInt8] {
    frame.cropped(columns: columns ?? 0..<frame.width, rows: rows).pixels
}

private func repainted(_ frame: Frame, _ paint: (_ x: Int, _ y: Int) -> [UInt8]?) -> Frame {
    var pixels = frame.pixels
    for y in 0..<frame.height {
        for x in 0..<frame.width {
            if let value = paint(x, y) {
                pixels.replaceSubrange((y * frame.bytesPerRow + x * 4)..<(y * frame.bytesPerRow + x * 4 + 4), with: value)
            }
        }
    }
    return Frame(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, pixels: pixels, colorSpace: frame.colorSpace)
}

private let white: [UInt8] = [255, 255, 255, 255]

@Test func noScrollGivesTheFirstFrame() throws {
    let first = viewport(of: page(width: 64, height: 300), top: 40, height: 100)
    let stitcher = Stitcher(first: first, tuning: tuning)
    #expect(try bytes(stitcher.image()) == first.pixels)
    #expect(stitcher.append(first) == StitchUpdate(state: .tracking, height: 100, appendedRows: 0))
    #expect(try bytes(stitcher.image()) == first.pixels)
}

@Test func plainScrollRebuildsThePage() throws {
    let source = page(width: 64, height: 400)
    let (stitcher, updates) = stitch(viewports(of: source, tops: [0, 40, 95, 150], height: 100))
    #expect(updates.map(\.state) == [.tracking, .tracking, .tracking])
    #expect(updates.map(\.appendedRows) == [40, 55, 55])
    #expect(try bytes(stitcher.image()) == rows(source, 0..<250))
}

@Test func stickyHeaderAppearsOnce() throws {
    let source = page(width: 64, height: 400)
    let frames = viewports(of: source, tops: [0, 40, 95, 150], height: 100, header: 30)
    let (stitcher, updates) = stitch(frames)
    #expect(updates.last?.height == 30 + 150 + (100 - 30))
    #expect(try bytes(stitcher.image()) == rows(frames[0], 0..<30) + rows(source, 30..<250))
}

@Test func stickyHeaderAndFooterAppearOnce() throws {
    let source = page(width: 64, height: 700)
    let frames = viewports(of: source, tops: [0, 40, 95, 150], height: 400, header: 30, footer: 20)
    let (stitcher, updates) = stitch(frames)
    #expect(updates.last?.height == 550)
    #expect(try bytes(stitcher.image()) == rows(frames[0], 0..<30) + rows(source, 30..<530) + rows(frames[3], 380..<400))
}

@Test func lateFooterAppearsOnce() throws {
    let source = page(width: 64, height: 700)
    let frames = viewports(of: source, tops: [0, 40, 95, 150], height: 400, widget: CGRect(x: 0, y: 380, width: 64, height: 20), widgetFrom: 2)
    let (stitcher, _) = stitch(frames)
    #expect(try bytes(stitcher.image()) == rows(source, 0..<530) + rows(frames[3], 380..<400))
}

@Test func floatingWidgetAppearsOnce() throws {
    let source = page(width: 64, height: 1000)
    let frames = viewports(of: source, tops: [0, 100, 200, 300], height: 600, widget: CGRect(x: 24, y: 560, width: 40, height: 40))
    let (stitcher, updates) = stitch(frames)
    #expect(updates.map(\.state) == [.tracking, .tracking, .tracking])
    #expect(try bytes(stitcher.image()) == rows(source, 0..<860) + rows(frames[3], 560..<600))
}

@Test func floatingZoneNeverShrinks() throws {
    let source = page(width: 64, height: 1100)
    let widget = CGRect(x: 24, y: 560, width: 40, height: 40)
    let frames = [0, 100, 200, 300, 400].enumerated().map { index, top in
        viewport(of: source, top: top, height: 600, widget: index < 3 ? widget : nil)
    }
    let (stitcher, _) = stitch(frames)
    #expect(stitcher.floatingZone == 40)
    #expect(try bytes(stitcher.image()) == rows(source, 0..<1000))
}

@Test func verticalRulesDontMakeAFloatingZone() throws {
    let ruled = repainted(page(width: 64, height: 400)) { x, _ in
        switch x {
        case 0: nil
        case 30, 31: [0, 0, 0, 255]
        default: white
        }
    }
    let (stitcher, _) = stitch(viewports(of: ruled, tops: [0, 40, 95, 150], height: 100))
    #expect(stitcher.floatingZone == 0)
    #expect(try bytes(stitcher.image()) == rows(ruled, 0..<250))
}

@Test func scrollingBackUpKeepsTheDeepestTail() throws {
    let source = page(width: 64, height: 1000)
    let frames = viewports(of: source, tops: [0, 200, 100], height: 700, widget: CGRect(x: 24, y: 660, width: 40, height: 40))
    let (stitcher, updates) = stitch(frames)
    #expect(updates.map(\.state) == [.tracking, .tracking])
    #expect(try bytes(stitcher.image()) == rows(source, 0..<860) + rows(frames[1], 660..<700))
}

@Test func stillSidebarIsDropped() throws {
    let source = page(width: 140, height: 400)
    let (stitcher, _) = stitch(viewports(of: source, tops: [0, 40, 95, 150], height: 100, sidebar: 60))
    #expect(stitcher.image()?.width == 80)
    #expect(try bytes(stitcher.image()) == rows(source, 0..<250, columns: 60..<140))
}

@Test func stillSidebarAndHeader() throws {
    let source = page(width: 140, height: 400)
    let frames = viewports(of: source, tops: [0, 40, 95, 150], height: 100, header: 30, sidebar: 60)
    let (stitcher, _) = stitch(frames)
    #expect(stitcher.image()?.width == 80)
    #expect(try bytes(stitcher.image()) == rows(frames[0], 0..<30, columns: 60..<140) + rows(source, 30..<250, columns: 60..<140))
}

@Test func stillSidebarIsFoundWhenContentColumnsDifferOnlyBetweenSamples() throws {
    let divided = repainted(page(width: 140, height: 400)) { x, y in
        guard (60..<100).contains(x) else { return nil }
        return y == 50 ? [0, 0, 0, 255] : white
    }
    var strided = tuning
    strided.sampleStride = 6
    let (stitcher, _) = stitch(viewports(of: divided, tops: [0, 40, 95, 150], height: 100, sidebar: 60), tuning: strided)
    #expect(stitcher.image()?.width == 80)
    #expect(try bytes(stitcher.image()) == rows(divided, 0..<250, columns: 60..<140))
}

@Test func whiteMarginsAreKept() throws {
    let margined = repainted(page(width: 144, height: 400)) { x, _ in x < 40 || x >= 104 ? white : nil }
    let (stitcher, _) = stitch(viewports(of: margined, tops: [0, 40, 95, 150], height: 100))
    #expect(stitcher.image()?.width == 144)
    #expect(try bytes(stitcher.image()) == rows(margined, 0..<250))
}

@Test func scrollingBackUpAppendsNothing() {
    let (_, updates) = stitch(viewports(of: page(width: 64, height: 500), tops: [0, 100, 50, 100], height: 200))
    #expect(updates.map(\.height) == [300, 300, 300])
    #expect(updates.map(\.appendedRows) == [100, 0, 0])
}

@Test func scrollingAboveTheStartAppendsNothing() {
    let (_, updates) = stitch(viewports(of: page(width: 64, height: 400), tops: [200, 150], height: 100))
    #expect(updates == [StitchUpdate(state: .tracking, height: 100, appendedRows: 0)])
}

@Test func gapRaisesLostOverlapAndRecovers() {
    let (_, updates) = stitch(viewports(of: page(width: 64, height: 400), tops: [0, 150, 60], height: 100))
    #expect(updates == [
        StitchUpdate(state: .lostOverlap, height: 100, appendedRows: 0),
        StitchUpdate(state: .tracking, height: 160, appendedRows: 60),
    ])
}

@Test func repeatingContentPicksNearestShift() throws {
    let period = page(width: 64, height: 20)
    let repeating = Frame(width: 64, height: 400, bytesPerRow: 256, pixels: (0..<20).flatMap { _ in period.pixels })
    let (stitcher, updates) = stitch(viewports(of: repeating, tops: [0, 8, 16, 24, 32], height: 100))
    #expect(updates.map(\.appendedRows) == [8, 8, 8, 8])
    #expect(try bytes(stitcher.image()) == rows(repeating, 0..<132))
}

@Test func equallyGoodShiftsKeepThePreviousDirection() throws {
    let period = page(width: 64, height: 20)
    let repeating = Frame(width: 64, height: 400, bytesPerRow: 256, pixels: (0..<20).flatMap { _ in period.pixels })
    let (stitcher, updates) = stitch(viewports(of: repeating, tops: [0, 8, 18, 28, 38], height: 100))
    #expect(updates.map(\.appendedRows) == [8, 10, 10, 10])
    #expect(try bytes(stitcher.image()) == rows(repeating, 0..<138))
}

@Test func exactlyTiedShiftsPickTheLowerShiftEveryTime() {
    let period = page(width: 64, height: 20)
    let repeating = Frame(width: 64, height: 400, bytesPerRow: 256, pixels: (0..<20).flatMap { _ in period.pixels })
    let frames = viewports(of: repeating, tops: [0, 10], height: 100)
    let updates = (0..<50).map { _ in Stitcher(first: frames[0], tuning: tuning).append(frames[1]) }
    #expect(updates.allSatisfy { $0 == StitchUpdate(state: .tracking, height: 100, appendedRows: 0) })
}

@Test func tallFooterStillMatchesALongScroll() throws {
    let source = page(width: 64, height: 700)
    let frames = viewports(of: source, tops: [0, 40, 190], height: 400, footer: 30)
    let (stitcher, updates) = stitch(frames)
    #expect(updates.map(\.state) == [.tracking, .tracking])
    #expect(try bytes(stitcher.image()) == rows(source, 0..<560) + rows(frames[2], 370..<400))
}

@Test func smallChangeStillMatches() {
    let source = page(width: 64, height: 400)
    let altered = repainted(viewport(of: source, top: 40, height: 100)) { x, y in x == 10 && y == 50 ? [0, 0, 0, 255] : nil }
    let (_, updates) = stitch([viewport(of: source, top: 0, height: 100), altered])
    #expect(updates == [StitchUpdate(state: .tracking, height: 140, appendedRows: 40)])
}

@Test func caretBlinkBeforeScrollingIsNotAScroll() throws {
    let source = page(width: 140, height: 400)
    let first = viewport(of: source, top: 0, height: 100, sidebar: 60)
    let caret = repainted(first) { x, y in x == 100 && (40..<44).contains(y) ? [0, 0, 0, 255] : nil }
    let (stitcher, updates) = stitch([first, caret, viewport(of: source, top: 40, height: 100, sidebar: 60)])
    #expect(updates.map(\.state) == [.tracking, .tracking])
    #expect(updates.map(\.appendedRows) == [0, 40])
    #expect(stitcher.image()?.width == 80)
}

@Test func sidebarHoverIsNotAScroll() {
    let source = page(width: 140, height: 400)
    let scrolled = viewport(of: source, top: 40, height: 100, sidebar: 60)
    let hovered = repainted(scrolled) { x, y in x == 5 && y == 50 ? white : nil }
    let (_, updates) = stitch([viewport(of: source, top: 0, height: 100, sidebar: 60), scrolled, hovered])
    #expect(updates.last == StitchUpdate(state: .tracking, height: 140, appendedRows: 0))
}

@Test func heightLimitStopsAndSays() {
    var limited = tuning
    limited.maxOutputHeight = 250
    let (stitcher, updates) = stitch(viewports(of: page(width: 64, height: 500), tops: [0, 100, 200], height: 200), tuning: limited)
    #expect(updates.map(\.state) == [.heightLimitReached(limit: 250), .heightLimitReached(limit: 250)])
    #expect(updates.map(\.height) == [250, 250])
    #expect(stitcher.image()?.height == 250)
}

@Test func appendStaysLinear() {
    func comparisons(height: Int) -> Int {
        let source = page(width: 64, height: height * 2)
        let stitcher = Stitcher(first: viewport(of: source, top: 0, height: height), tuning: tuning)
        _ = stitcher.append(viewport(of: source, top: height / 10, height: height))
        return stitcher.rowComparisons
    }
    let short = comparisons(height: 200)
    #expect(short > 0)
    #expect(comparisons(height: 400) <= 2 * short)
}

@Test func appendStaysLinearOnRepeatedRows() {
    func comparisons(height: Int) -> Int {
        let ruled = repainted(page(width: 64, height: height * 2)) { x, y in
            guard y % 5 != 0 else { return nil }
            return x == 30 ? [0, 0, 0, 255] : white
        }
        let stitcher = Stitcher(first: viewport(of: ruled, top: 0, height: height), tuning: tuning)
        _ = stitcher.append(viewport(of: ruled, top: height / 10, height: height))
        return stitcher.rowComparisons
    }
    let short = comparisons(height: 200)
    #expect(short > 0)
    #expect(comparisons(height: 400) <= 2 * short)
}

@Test func tailReturnsLastRows() throws {
    let (stitcher, _) = stitch(viewports(of: page(width: 64, height: 400), tops: [0, 40, 95, 150], height: 100))
    let tail = try #require(stitcher.tail(maxRows: 10))
    #expect(tail.height == 10)
    #expect(try bytes(tail) == Array(try bytes(stitcher.image()).suffix(10 * 64 * 4)))
}

@Test func outputKeepsTheFirstFramesColorSpace() throws {
    let provider = CGDataProvider(data: Data(white) as CFData)!
    let image = try #require(CGImage(
        width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ))
    #expect(try #require(Frame(image)).colorSpace.name == CGColorSpace.sRGB)

    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    let source = page(width: 64, height: 400)
    let frames = viewports(of: source, tops: [0, 40], height: 100).map {
        Frame(width: $0.width, height: $0.height, bytesPerRow: $0.bytesPerRow, pixels: $0.pixels, colorSpace: p3)
    }
    let (stitcher, _) = stitch(frames)
    #expect(stitcher.image()?.colorSpace?.name == CGColorSpace.displayP3)
    #expect(stitcher.tail(maxRows: 10)?.colorSpace?.name == CGColorSpace.displayP3)
}

func fixtureFrames(_ page: String) throws -> [Frame] {
    let directory = try #require(Bundle.module.url(forResource: "Fixtures/scrolling/\(page)", withExtension: nil))
    let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("frame-") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    return try urls.map { url in
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try #require(Frame(image))
    }
}

@Test(arguments: ["github-pr", "notion"])
func realPageStitches(_ page: String) throws {
    let frames = try fixtureFrames(page)
    let stitcher = Stitcher(first: frames[0], tuning: .measured)
    var tops = [stitcher.referenceTop]
    var height = frames[0].height
    for frame in frames.dropFirst() {
        let update = stitcher.append(frame)
        #expect(update.state == .tracking)
        #expect(update.height >= height)
        height = update.height
        tops.append(stitcher.referenceTop)
    }
    #expect(stitcher.floatingZone == 0)

    let image = try bytes(stitcher.image())
    let columns = stitcher.contentColumns, header = stitcher.headerRows
    let rowBytes = columns.count * 4
    for (frame, top) in zip(frames, tops) {
        let moving = rows(frame, header..<frame.height, columns: columns)
        var matched = 0, compared = 0
        for row in max(0, -top)..<(frame.height - header) where !frame.isUniformRow(header + row, columns: columns) {
            let imageRow = (header + top + row) * rowBytes
            compared += 1
            if moving[(row * rowBytes)..<((row + 1) * rowBytes)] == image[imageRow..<(imageRow + rowBytes)] { matched += 1 }
        }
        #expect(Double(matched) >= StitchTuning.measured.minMatchFraction * Double(compared))
    }
}

@Test func latePaintedFrameIsRefusedAndTheNextOneRecovers() throws {
    let frames = Array(try fixtureFrames("github-pr")[6...])
    let clean = Stitcher(first: frames[0], tuning: .measured)
    var cleanTops = [clean.referenceTop]
    for frame in frames.dropFirst() {
        _ = clean.append(frame)
        cleanTops.append(clean.referenceTop)
    }

    let stitcher = Stitcher(first: frames[0], tuning: .measured)
    for frame in frames[1..<2] { _ = stitcher.append(frame) }
    let columns = stitcher.contentColumns
    let overlap = frames[2].height - stitcher.headerRows - (cleanTops[2] - cleanTops[1])
    let blankFrom = stitcher.headerRows + overlap / 2
    var pixels = frames[2].pixels
    for y in blankFrom..<frames[2].height {
        let start = y * frames[2].bytesPerRow
        pixels.replaceSubrange((start + columns.lowerBound * 4)..<(start + columns.upperBound * 4), with: repeatElement(255, count: columns.count * 4))
    }
    let latePainted = Frame(width: frames[2].width, height: frames[2].height, bytesPerRow: frames[2].bytesPerRow, pixels: pixels, colorSpace: frames[2].colorSpace)
    #expect(stitcher.append(latePainted).state == .lostOverlap)
    for frame in frames[2...] { #expect(stitcher.append(frame).state == .tracking) }
    #expect(try bytes(stitcher.image()) == bytes(clean.image()))
}

@Test(arguments: [2, 16])
func toastOneBlockTallAppearsOnce(block: Int) throws {
    var blocks = tuning
    blocks.floatingBlockSize = block
    let source = page(width: 64, height: 1000)
    let frames = viewports(of: source, tops: [0, 100, 200, 300], height: 600, widget: CGRect(x: 24, y: 600 - block, width: 40, height: block))
    let (stitcher, _) = stitch(frames, tuning: blocks)
    #expect(try bytes(stitcher.image()) == rows(source, 0..<(900 - block)) + rows(frames[3], (600 - block)..<600))
}

@Test func sparseTopRowsAreNotAHeader() {
    let sparseTop = repainted(page(width: 64, height: 400)) { x, y in
        guard y % 40 < 4 else { return nil }
        return x == 1 + y % 7 ? [0, 0, 0, 255] : white
    }
    var strided = tuning
    strided.sampleStride = 8
    let (stitcher, updates) = stitch(viewports(of: sparseTop, tops: [0, 40, 95, 150], height: 100), tuning: strided)
    #expect(updates.map(\.state) == [.tracking, .tracking, .tracking])
    #expect(stitcher.headerRows == 0)
}
