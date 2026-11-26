import AppKit
import LunettaCore

final class LoupeLayer: CALayer {
    static let gridPixels = 17
    static let pointsPerPixel: CGFloat = 8
    static let rimWidth: CGFloat = 5
    static let pointerGap: CGFloat = 4
    static let diameter = CGFloat(gridPixels) * pointsPerPixel
    static let size = CGSize(width: diameter, height: diameter)

    private let lens = CALayer()
    private let grid = CALayer()
    private let vignette = CAGradientLayer()
    private let sheen = CAGradientLayer()
    private let reticleShadow = CAShapeLayer()
    private let reticle = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let rimGlint = CAShapeLayer()
    private let outerEdge = CAShapeLayer()
    private let innerEdge = CAShapeLayer()
    private var imagePixelSize = CGSize.zero
    private var lastPixel: LoupePixel?

    override init() {
        super.init()
        let bounds = CGRect(origin: .zero, size: Self.size)
        self.bounds = bounds
        anchorPoint = .zero
        isHidden = true

        shadowPath = CGPath(ellipseIn: bounds, transform: nil)
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.3
        shadowRadius = 8
        shadowOffset = CGSize(width: 0, height: -3)

        lens.frame = bounds
        lens.cornerRadius = Self.diameter / 2
        lens.masksToBounds = true
        lens.backgroundColor = NSColor.black.cgColor
        addSublayer(lens)

        grid.frame = bounds
        grid.magnificationFilter = .nearest
        grid.contentsGravity = .resize
        lens.addSublayer(grid)

        vignette.frame = bounds
        vignette.type = .radial
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1, y: 1)
        vignette.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.22).cgColor]
        vignette.locations = [0, 0.72, 1]
        lens.addSublayer(vignette)

        let sheenHeight = Self.diameter * 0.34
        sheen.frame = CGRect(x: Self.diameter * 0.18, y: Self.diameter * 0.6, width: Self.diameter * 0.64, height: sheenHeight)
        sheen.cornerRadius = sheenHeight / 2
        sheen.colors = [NSColor.white.withAlphaComponent(0.3).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        sheen.startPoint = CGPoint(x: 0.5, y: 1)
        sheen.endPoint = CGPoint(x: 0.5, y: 0)
        lens.addSublayer(sheen)

        let center = CGFloat(Self.gridPixels / 2) * Self.pointsPerPixel
        let cell = CGRect(x: center, y: center, width: Self.pointsPerPixel, height: Self.pointsPerPixel)
        stroke(reticleShadow, CGPath(rect: cell.insetBy(dx: -1.5, dy: -1.5), transform: nil), NSColor.black.withAlphaComponent(0.55), width: 1)
        stroke(reticle, CGPath(rect: cell.insetBy(dx: -0.5, dy: -0.5), transform: nil), .white, width: 1)

        stroke(rim, circle(insetBy: Self.rimWidth / 2), NSColor.white.withAlphaComponent(0.45), width: Self.rimWidth)
        stroke(innerEdge, circle(insetBy: Self.rimWidth), NSColor.black.withAlphaComponent(0.25), width: 1)
        stroke(outerEdge, circle(insetBy: 0.5), NSColor.black.withAlphaComponent(0.35), width: 1)

        let glint = CGMutablePath()
        glint.addArc(
            center: CGPoint(x: bounds.midX, y: bounds.midY), radius: Self.diameter / 2 - 1.5,
            startAngle: .pi * 0.55, endAngle: .pi * 1.05, clockwise: false
        )
        stroke(rimGlint, glint, NSColor.white.withAlphaComponent(0.85), width: 1.5)
        rimGlint.lineCap = .round
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func circle(insetBy inset: CGFloat) -> CGPath {
        CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
    }

    private func stroke(_ shape: CAShapeLayer, _ path: CGPath, _ color: NSColor, width: CGFloat) {
        shape.frame = bounds
        shape.path = path
        shape.fillColor = nil
        shape.strokeColor = color.cgColor
        shape.lineWidth = width
        addSublayer(shape)
    }

    func setImage(_ image: CGImage, scale: CGFloat) {
        for layer in [self, lens, vignette, sheen, reticleShadow, reticle, rim, rimGlint, outerEdge, innerEdge] {
            layer.contentsScale = scale
        }
        grid.contents = image
        imagePixelSize = CGSize(width: image.width, height: image.height)
        lastPixel = nil
    }

    var hasImage: Bool { grid.contents != nil }

    func show(pixel: LoupePixel, at origin: CGPoint) {
        guard hasImage else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if pixel != lastPixel {
            lastPixel = pixel
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
        }
        if position != origin {
            position = origin
        }
        if isHidden {
            isHidden = false
        }
        CATransaction.commit()
    }

    func hide() {
        guard !isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = true
        CATransaction.commit()
    }
}
