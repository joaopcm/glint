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
        guard capsToUHD else { return source }
        let scale = min(1, Double(uhd.width) / Double(source.width), Double(uhd.height) / Double(source.height))
        if scale == 1 { return source }
        return PixelSize(
            width: roundedDownToEven(Double(source.width) * scale),
            height: roundedDownToEven(Double(source.height) * scale)
        )
    }

    private static func roundedDownToEven(_ value: Double) -> Int {
        Int(value.rounded(.down)) & ~1
    }
}
