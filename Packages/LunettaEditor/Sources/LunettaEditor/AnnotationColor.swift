import AppKit
import CoreGraphics

public struct AnnotationColor: Equatable, Hashable, Sendable {
    public struct Preset: Equatable, Sendable {
        public let name: String
        public let color: AnnotationColor
    }

    public let redByte: UInt8
    public let greenByte: UInt8
    public let blueByte: UInt8

    public init(redByte: UInt8, greenByte: UInt8, blueByte: UInt8) {
        self.redByte = redByte
        self.greenByte = greenByte
        self.blueByte = blueByte
    }

    public init?(hex: String) {
        let trimmed = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
        self.init(
            redByte: UInt8((value >> 16) & 0xFF),
            greenByte: UInt8((value >> 8) & 0xFF),
            blueByte: UInt8(value & 0xFF)
        )
    }

    public init(nsColor: NSColor) {
        let srgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
        func byte(_ component: CGFloat) -> UInt8 {
            UInt8((min(max(component, 0), 1) * 255).rounded())
        }
        self.init(redByte: byte(srgb.redComponent), greenByte: byte(srgb.greenComponent), blueByte: byte(srgb.blueComponent))
    }

    public var hexString: String {
        String(format: "#%02X%02X%02X", redByte, greenByte, blueByte)
    }

    public var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(redByte) / 255,
            green: CGFloat(greenByte) / 255,
            blue: CGFloat(blueByte) / 255,
            alpha: 1
        )
    }

    public var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(redByte) / 255,
            green: CGFloat(greenByte) / 255,
            blue: CGFloat(blueByte) / 255,
            alpha: 1
        )
    }

    public var presetName: String? {
        Self.presets.first { $0.color == self }?.name
    }

    public var accessibilityName: String {
        presetName ?? hexString
    }

    var relativeLuminance: CGFloat {
        (0.2126 * CGFloat(redByte) + 0.7152 * CGFloat(greenByte) + 0.0722 * CGFloat(blueByte)) / 255
    }

    public static let black = AnnotationColor(redByte: 0x00, greenByte: 0x00, blueByte: 0x00)
    public static let red = AnnotationColor(redByte: 0xFF, greenByte: 0x3B, blueByte: 0x30)
    public static let orange = AnnotationColor(redByte: 0xFF, greenByte: 0x95, blueByte: 0x00)
    public static let yellow = AnnotationColor(redByte: 0xFF, greenByte: 0xD6, blueByte: 0x0A)
    public static let green = AnnotationColor(redByte: 0x30, greenByte: 0xD1, blueByte: 0x58)
    public static let teal = AnnotationColor(redByte: 0x2A, greenByte: 0xC9, blueByte: 0xB8)
    public static let blue = AnnotationColor(redByte: 0x00, greenByte: 0x7A, blueByte: 0xFF)
    public static let purple = AnnotationColor(redByte: 0x89, greenByte: 0x44, blueByte: 0xF7)
    public static let pink = AnnotationColor(redByte: 0xFF, greenByte: 0x2D, blueByte: 0x55)
    public static let white = AnnotationColor(redByte: 0xFF, greenByte: 0xFF, blueByte: 0xFF)

    public static let presets: [Preset] = [
        Preset(name: "Black", color: .black),
        Preset(name: "Red", color: .red),
        Preset(name: "Orange", color: .orange),
        Preset(name: "Yellow", color: .yellow),
        Preset(name: "Green", color: .green),
        Preset(name: "Teal", color: .teal),
        Preset(name: "Blue", color: .blue),
        Preset(name: "Purple", color: .purple),
        Preset(name: "Pink", color: .pink),
        Preset(name: "White", color: .white),
    ]
}
