import AppKit
import Testing
@testable import LunettaEditor

@MainActor
struct IntensityTests {
    @Test func eachThirdOfTheSliderDoublesTheSize() {
        let sizes = [0, 1.0 / 3, 2.0 / 3, 1].map { ObscuringIntensity.size(at: $0, pixelsPerPoint: 2) }
        for (size, expected) in zip(sizes, [12, 24, 48, 96] as [CGFloat]) {
            #expect(abs(size - expected) < 0.001, "\(size) px, expected \(expected)")
        }
        for level in [0, 0.25, 1.0 / 3, 0.9, 1] {
            let size = ObscuringIntensity.size(at: level, pixelsPerPoint: 2)
            #expect(abs(ObscuringIntensity.level(of: size, pixelsPerPoint: 2) - level) < 0.0001)
        }
    }

    /// The fixed size before the slider: 4 of the canvas's 3 pt strokes.
    @Test func theStandardIntensityKeepsTheOldSize() {
        #expect(abs(ObscuringIntensity.size(at: ObscuringIntensity.standard, pixelsPerPoint: 2) - 3 * 2 * 4) < 0.001)
    }

    @Test(arguments: [
        (Annotation.Kind.blur(sigma: 2), Annotation.Kind.blur(sigma: 24)),
        (Annotation.Kind.pixelate(block: 4), Annotation.Kind.pixelate(block: 40)),
    ])
    func aHeavierIntensityReachesFurtherFromAnEdge(light: Annotation.Kind, heavy: Annotation.Kind) throws {
        let base = halfBlackImage(width: 200, height: 100)
        func obscured(_ kind: Annotation.Kind) throws -> Pixels {
            let layer = Annotation(kind: kind, start: CGPoint(x: 80, y: 0), end: CGPoint(x: 160, y: 100), lineWidth: 3)
            return try Pixels(#require(AnnotationRenderer.flatten(base, [layer])))
        }
        #expect(try obscured(light).isWhite(x: 116, y: 50), "16 px right of the black edge stays white under \(light)")
        #expect(try !obscured(heavy).isWhite(x: 116, y: 50), "16 px right of the black edge stays white under \(heavy)")
    }

    @Test func changingTheIntensityIsOneUndoStep() {
        let document = AnnotationDocument(base: stripedImage(width: 200, height: 100))
        let blur = Annotation(kind: .blur(sigma: 12), start: CGPoint(x: 20, y: 20), end: CGPoint(x: 80, y: 80), lineWidth: 3)
        document.add(blur)
        document.setObscuringSize(blur.id, 30)
        #expect(document.annotation(blur.id)?.kind == .blur(sigma: 30))
        #expect(document.undoManager.undoActionName == "Change Blur Intensity")
        document.undoManager.undo()
        #expect(document.annotation(blur.id)?.kind == .blur(sigma: 12))
    }

    @Test func theSliderFollowsTheToolWithNothingSelected() {
        let harness = CanvasHarness()
        let canvas = harness.canvas
        canvas.tool = .arrow
        #expect(canvas.intensityTarget == nil)
        canvas.tool = .blur
        #expect(canvas.intensityTarget?.tool == .blur)
        #expect(canvas.intensityTarget?.level == ObscuringIntensity.standard)
        canvas.setIntensity(0, committing: true)
        #expect(!harness.document.undoManager.canUndo, "a level for the next blur isn't an edit")
        canvas.tool = .pixelate
        #expect(canvas.intensityTarget?.level == ObscuringIntensity.standard, "each tool keeps its own level")
        canvas.tool = .blur
        #expect(canvas.intensityTarget?.level == 0)
    }

    @Test func theBlurToolDrawsAtTheChosenIntensity() throws {
        let harness = CanvasHarness()
        harness.canvas.tool = .blur
        harness.canvas.setIntensity(1, committing: true)
        harness.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 80))
        let drawn = try #require(harness.document.annotations.first)
        #expect(drawn.kind == .blur(sigma: ObscuringIntensity.size(at: 1, pixelsPerPoint: 1)))
    }

    @Test func aSliderDragShowsOnTheCanvasAndLandsAsOneUndoStep() throws {
        let harness = CanvasHarness()
        let blur = Annotation(kind: .blur(sigma: 12), start: CGPoint(x: 20, y: 20), end: CGPoint(x: 80, y: 80), lineWidth: 3)
        harness.document.add(blur)
        harness.canvas.tool = .select
        harness.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50))
        try #require(harness.canvas.selectedID == blur.id)

        harness.canvas.setIntensity(0.5, committing: false)
        harness.canvas.setIntensity(1, committing: false)
        #expect(harness.document.annotation(blur.id)?.kind == .blur(sigma: 12), "a drag in progress wrote to the document")
        harness.canvas.setIntensity(1, committing: true)
        #expect(harness.document.annotation(blur.id)?.kind == .blur(sigma: ObscuringIntensity.size(at: 1, pixelsPerPoint: 1)))
        #expect(harness.document.undoManager.undoActionName == "Change Blur Intensity")
        harness.document.undoManager.undo()
        #expect(harness.document.annotation(blur.id)?.kind == .blur(sigma: 12))
    }

    @Test func aSelectedPixelateIsLeftAloneWhileTheBlurToolIsOn() throws {
        let harness = CanvasHarness()
        let block = ObscuringIntensity.size(at: 1, pixelsPerPoint: 1)
        let pixelate = Annotation(kind: .pixelate(block: block), start: CGPoint(x: 20, y: 20), end: CGPoint(x: 80, y: 80), lineWidth: 3)
        harness.document.add(pixelate)
        harness.canvas.tool = .select
        harness.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50))
        try #require(harness.canvas.selectedID == pixelate.id)
        let selected = try #require(harness.canvas.intensityTarget)
        #expect(selected.tool == .pixelate)
        #expect(abs(selected.level - 1) < 0.0001)

        harness.canvas.tool = .blur
        harness.canvas.setIntensity(0, committing: true)
        #expect(harness.document.annotation(pixelate.id)?.kind == .pixelate(block: block))
    }

    @Test func theIntensitySliderOpensOnlyForBlurAndPixelate() {
        let editor = makeEditor(width: 200, height: 100)
        #expect(!editor.isIntensityOpen)
        #expect(editor.intensitySlider.isHidden)
        editor.canvas.tool = .blur
        #expect(editor.isIntensityOpen)
        #expect(!editor.intensitySlider.isHidden)
        #expect(editor.intensitySlider.accessibilityLabel() == "Blur intensity")
        editor.canvas.tool = .pixelate
        #expect(editor.intensitySlider.accessibilityLabel() == "Pixelate intensity")
        editor.canvas.tool = .rectangle
        #expect(!editor.isIntensityOpen)
        #expect(editor.intensitySlider.isHidden)
    }

    /// 200×100 px opens the editor at its minimum content size.
    @Test func openIntensitySliderFitsTheSmallestWindow() throws {
        let editor = makeEditor(width: 200, height: 100)
        let content = try #require(editor.window.contentView)
        editor.canvas.tool = .blur
        content.layoutSubtreeIfNeeded()
        let dock = editor.dock.convert(editor.dock.bounds, to: nil)
        let slider = editor.intensitySlider.convert(editor.intensitySlider.bounds, to: nil)
        #expect(dock.minX >= 16 && dock.maxX <= content.bounds.width - 16, "open dock \(dock) spills out of a \(content.bounds.width) pt window")
        #expect(dock.insetBy(dx: -0.5, dy: -0.5).contains(slider), "slider \(slider) sticks out of the dock \(dock)")
    }

    @Test func openingTheSliderLeavesTheButtonThatOpenedItInPlace() throws {
        let editor = makeEditor(width: 2400, height: 800)
        let content = try #require(editor.window.contentView)
        let blur = try #require(editor.toolButtons[.blur])
        content.layoutSubtreeIfNeeded()
        let closed = blur.convert(blur.bounds, to: nil)
        editor.canvas.tool = .blur
        content.layoutSubtreeIfNeeded()
        let open = blur.convert(blur.bounds, to: nil)
        #expect(abs(open.minX - closed.minX) < 1, "the Blur button moved from \(closed.minX) to \(open.minX)")
    }

    private func makeEditor(width: Int, height: Int) -> AnnotationEditor {
        AnnotationEditor(
            document: AnnotationDocument(base: solidImage(width: width, height: height)),
            title: "Test",
            pixelsPerPoint: 2,
            save: { _ in },
            onClose: {}
        )
    }
}

/// A canvas in a 400×300 window over a 200×100 image, so the image sits unscaled 100 pt in from the window's edges.
@MainActor
private final class CanvasHarness {
    let document: AnnotationDocument
    let canvas: EditorCanvas
    let window: NSWindow

    init() {
        document = AnnotationDocument(base: stripedImage(width: 200, height: 100))
        canvas = EditorCanvas(document: document, pixelsPerPoint: 1)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
    }

    func drag(from start: CGPoint, to end: CGPoint) {
        canvas.mouseDown(with: event(.leftMouseDown, at: start))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: end))
        canvas.mouseUp(with: event(.leftMouseUp, at: end))
    }

    private func event(_ type: NSEvent.EventType, at imagePoint: CGPoint) -> NSEvent {
        let rect = canvas.imageRect
        let viewPoint = CGPoint(x: rect.minX + imagePoint.x, y: rect.minY + imagePoint.y)
        return NSEvent.mouseEvent(
            with: type, location: canvas.convert(viewPoint, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }
}

private func halfBlackImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    return context.makeImage()!
}
