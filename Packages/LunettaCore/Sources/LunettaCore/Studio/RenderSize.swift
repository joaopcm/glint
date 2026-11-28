public struct PixelSize: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum RenderSize {
    public static let uhd = PixelSize(width: 3840, height: 2160)

    public static func output(for source: PixelSize, capsToUHD: Bool) -> PixelSize {
        guard capsToUHD, source.width > uhd.width || source.height > uhd.height else { return source }
        if source.width * uhd.height >= source.height * uhd.width {
            return PixelSize(width: uhd.width, height: roundedDownToEven(source.height * uhd.width / source.width))
        }
        return PixelSize(width: roundedDownToEven(source.width * uhd.height / source.height), height: uhd.height)
    }

    private static func roundedDownToEven(_ value: Int) -> Int {
        value & ~1
    }
}
