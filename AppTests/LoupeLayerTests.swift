import AppKit
import LunettaCore
import Testing
@testable import Lunetta

private struct RGBA: Equatable {
    let r: UInt8, g: UInt8, b: UInt8, a: UInt8
}

private let blue = RGBA(r: 0, g: 0, b: 255, a: 255)
private let red = RGBA(r: 255, g: 0, b: 0, a: 255)
private let target = LoupePixel(x: 20, y: 30)

private func screen(side: Int) throws -> CGImage {
    var bytes = [UInt8](repeating: 0, count: side * side * 4)
    for index in 0..<(side * side) {
        let isTarget = index == target.y * side + target.x
        let color = isTarget ? red : blue
        bytes.replaceSubrange(index * 4..<index * 4 + 4, with: [color.r, color.g, color.b, color.a])
    }
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    return try #require(CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ))
}

@MainActor private func renderedLoupe() throws -> (pixel: (Int, Int) -> RGBA, side: Int) {
    let loupe = LoupeLayer()
    loupe.setImage(try screen(side: 64), scale: 1)
    loupe.show(pixel: target, at: .zero)
    let side = Int(LoupeLayer.size.width)
    let context = try #require(CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    loupe.render(in: context)
    let base = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    let data = Array(UnsafeBufferPointer(start: base, count: side * side * 4))
    return ({ x, y in
        let offset = (y * side + x) * 4
        return RGBA(r: data[offset], g: data[offset + 1], b: data[offset + 2], a: data[offset + 3])
    }, side)
}

@MainActor @Test func lensCentersThePixelUnderThePointer() throws {
    let (pixel, side) = try renderedLoupe()
    let centre = pixel(side / 2, side / 2)
    #expect(centre.r > 200 && centre.b < 60, "the centre of the lens should show the red pixel under the pointer, got \(centre)")
    let neighbour = pixel(side / 2 + Int(LoupeLayer.pointsPerPixel) + 2, side / 2)
    #expect(neighbour.b > 200 && neighbour.r < 40, "the cell beside the centre should show the blue around the pointer, got \(neighbour)")
}

@MainActor @Test func lensIsRound() throws {
    let (pixel, side) = try renderedLoupe()
    for (x, y) in [(1, 1), (side - 2, 1), (1, side - 2), (side - 2, side - 2)] {
        #expect(pixel(x, y).a < 40, "corner (\(x), \(y)) of the loupe's square bounds is painted: \(pixel(x, y))")
    }
}
