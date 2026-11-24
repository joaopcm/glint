import AppKit
import GlintCore

final class LoupeLayer: CALayer {
    static let gridPixels = 15
    static let pointsPerPixel: CGFloat = 8
    static let labelHeight: CGFloat = 20
    static let pointerGap: CGFloat = 16
    static let gridSide = CGFloat(gridPixels) * pointsPerPixel
    static let size = CGSize(width: gridSide, height: gridSide + labelHeight)

    private let grid = CALayer()
    private let crosshair = CAShapeLayer()
    private let label = CATextLayer()
    private var imagePixelSize = CGSize.zero

    override init() {
        super.init()
        bounds = CGRect(origin: .zero, size: Self.size)
        anchorPoint = .zero
        cornerRadius = 8
        masksToBounds = true
        borderWidth = 1
        borderColor = NSColor.white.cgColor
        backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        isHidden = true

        grid.frame = CGRect(x: 0, y: Self.labelHeight, width: Self.gridSide, height: Self.gridSide)
        grid.magnificationFilter = .nearest
        grid.contentsGravity = .resize
        addSublayer(grid)

        let center = CGFloat(Self.gridPixels / 2) * Self.pointsPerPixel
        let cell = CGRect(x: center, y: Self.labelHeight + center, width: Self.pointsPerPixel, height: Self.pointsPerPixel)
        crosshair.path = CGPath(rect: cell.insetBy(dx: -0.5, dy: -0.5), transform: nil)
        crosshair.fillColor = nil
        crosshair.strokeColor = NSColor.systemRed.cgColor
        crosshair.lineWidth = 1
        addSublayer(crosshair)

        label.frame = CGRect(x: 0, y: 3, width: Self.gridSide, height: Self.labelHeight - 6)
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.fontSize = 11
        label.alignmentMode = .center
        label.foregroundColor = NSColor.white.cgColor
        addSublayer(label)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setImage(_ image: CGImage, scale: CGFloat) {
        contentsScale = scale
        label.contentsScale = scale
        crosshair.contentsScale = scale
        grid.contents = image
        imagePixelSize = CGSize(width: image.width, height: image.height)
    }

    var hasImage: Bool { grid.contents != nil }

    func show(pixel: LoupePixel, at origin: CGPoint) {
        guard hasImage else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let half = Self.gridPixels / 2
        let side = CGFloat(Self.gridPixels)
        let width = side / imagePixelSize.width
        let height = side / imagePixelSize.height
        // contentsRect is unit space with a bottom-left origin; the pixel index counts from the top.
        grid.contentsRect = CGRect(
            x: CGFloat(pixel.x - half) / imagePixelSize.width,
            y: 1 - CGFloat(pixel.y - half) / imagePixelSize.height - height,
            width: width,
            height: height
        )
        label.string = "\(pixel.x), \(pixel.y)"
        position = origin
        isHidden = false
        CATransaction.commit()
    }

    func hide() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = true
        CATransaction.commit()
    }
}
