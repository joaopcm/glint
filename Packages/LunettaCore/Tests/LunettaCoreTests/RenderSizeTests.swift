import Testing
@testable import LunettaCore

struct RenderSizeTests {
    @Test(arguments: [
        (PixelSize(width: 6016, height: 3384), true, PixelSize(width: 3840, height: 2160)),
        (PixelSize(width: 1994, height: 1216), true, PixelSize(width: 1994, height: 1216)),
        (PixelSize(width: 5120, height: 1440), true, PixelSize(width: 3840, height: 1080)),
        (PixelSize(width: 7680, height: 4320), true, PixelSize(width: 3840, height: 2160)),
        (PixelSize(width: 4001, height: 2251), true, PixelSize(width: 3838, height: 2160)),
        (PixelSize(width: 6016, height: 3384), false, PixelSize(width: 6016, height: 3384)),
    ])
    func outputFitsTheCap(source: PixelSize, capsToUHD: Bool, expected: PixelSize) {
        #expect(RenderSize.output(for: source, capsToUHD: capsToUHD) == expected)
    }
}
