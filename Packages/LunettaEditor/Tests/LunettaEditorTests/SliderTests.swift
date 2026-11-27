import AppKit
import Testing
@testable import LunettaEditor

@MainActor
struct SliderTests {
    @Test func eachThirdOfTheSliderDoublesTheSize() {
        let sizes = [0, 1.0 / 3, 2.0 / 3, 1].map { SliderScale.obscuring.size(at: $0, pixelsPerPoint: 2) }
        for (size, expected) in zip(sizes, [12, 24, 48, 96] as [CGFloat]) {
            #expect(abs(size - expected) < 0.001, "\(size) px, expected \(expected)")
        }
        for level in [0, 0.25, 1.0 / 3, 0.9, 1] {
            let size = SliderScale.obscuring.size(at: level, pixelsPerPoint: 2)
            #expect(abs(SliderScale.obscuring.level(of: size, pixelsPerPoint: 2) - level) < 0.0001)
        }
    }

    /// The fixed size before the slider: 4 of the canvas's 3 pt strokes.
    @Test func theStandardIntensityKeepsTheOldSize() {
        #expect(abs(SliderScale.obscuring.size(at: SliderScale.obscuring.standard, pixelsPerPoint: 2) - 3 * 2 * 4) < 0.001)
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
        document.setSliderSize(blur.id, 30)
        #expect(document.annotation(blur.id)?.kind == .blur(sigma: 30))
        #expect(document.undoManager.undoActionName == "Change Blur Intensity")
        document.undoManager.undo()
        #expect(document.annotation(blur.id)?.kind == .blur(sigma: 12))
    }

    @Test func theSliderFollowsTheToolWithNothingSelected() {
        let harness = CanvasHarness()
        let canvas = harness.canvas
        canvas.tool = .rectangle
        #expect(canvas.sliderTarget == nil)
        canvas.tool = .arrow
        #expect(canvas.sliderTarget?.tool == .arrow)
        #expect(canvas.sliderTarget?.level == SliderScale.arrowThickness.standard)
        canvas.tool = .blur
        #expect(canvas.sliderTarget?.tool == .blur)
        #expect(canvas.sliderTarget?.level == SliderScale.obscuring.standard)
        canvas.setSliderLevel(0, committing: true)
        #expect(!harness.document.undoManager.canUndo, "a level for the next blur isn't an edit")
        canvas.tool = .pixelate
        #expect(canvas.sliderTarget?.level == SliderScale.obscuring.standard, "each tool keeps its own level")
        canvas.tool = .blur
        #expect(canvas.sliderTarget?.level == 0)
    }

    @Test func theBlurToolDrawsAtTheChosenIntensity() throws {
        let harness = CanvasHarness()
        harness.canvas.tool = .blur
        harness.canvas.setSliderLevel(1, committing: true)
        harness.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 80))
        let drawn = try #require(harness.document.annotations.first)
        #expect(drawn.kind == .blur(sigma: SliderScale.obscuring.size(at: 1, pixelsPerPoint: 1)))
    }

    @Test func aSliderDragShowsOnTheCanvasAndLandsAsOneUndoStep() throws {
        let harness = CanvasHarness()
        let blur = Annotation(kind: .blur(sigma: 12), start: CGPoint(x: 20, y: 20), end: CGPoint(x: 80, y: 80), lineWidth: 3)
        harness.document.add(blur)
        harness.canvas.tool = .select
        harness.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50))
        try #require(harness.canvas.selectedID == blur.id)

        harness.canvas.setSliderLevel(0.5, committing: false)
        harness.canvas.setSliderLevel(1, committing: false)
        #expect(harness.document.annotation(blur.id)?.kind == .blur(sigma: 12), "a drag in progress wrote to the document")
        harness.canvas.setSliderLevel(1, committing: true)
        #expect(harness.document.annotation(blur.id)?.kind == .blur(sigma: SliderScale.obscuring.size(at: 1, pixelsPerPoint: 1)))
        #expect(harness.document.undoManager.undoActionName == "Change Blur Intensity")
        harness.document.undoManager.undo()
        #expect(harness.document.annotation(blur.id)?.kind == .blur(sigma: 12))
    }

    @Test func aSelectedPixelateIsLeftAloneWhileTheBlurToolIsOn() throws {
        let harness = CanvasHarness()
        let block = SliderScale.obscuring.size(at: 1, pixelsPerPoint: 1)
        let pixelate = Annotation(kind: .pixelate(block: block), start: CGPoint(x: 20, y: 20), end: CGPoint(x: 80, y: 80), lineWidth: 3)
        harness.document.add(pixelate)
        harness.canvas.tool = .select
        harness.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50))
        try #require(harness.canvas.selectedID == pixelate.id)
        let selected = try #require(harness.canvas.sliderTarget)
        #expect(selected.tool == .pixelate)
        #expect(abs(selected.level - 1) < 0.0001)

        harness.canvas.tool = .blur
        harness.canvas.setSliderLevel(0, committing: true)
        #expect(harness.document.annotation(pixelate.id)?.kind == .pixelate(block: block))
    }

    @Test func eachHalfOfTheThicknessSliderTriplesTheArrow() {
        let widths = [0, 0.5, 1].map { SliderScale.arrowThickness.size(at: $0, pixelsPerPoint: 2) }
        for (width, expected) in zip(widths, [4, 12, 36] as [CGFloat]) {
            #expect(abs(width - expected) < 0.001, "\(width) px, expected \(expected)")
        }
        for level in [0, 0.25, 0.5, 0.9, 1] {
            let width = SliderScale.arrowThickness.size(at: level, pixelsPerPoint: 2)
            #expect(abs(SliderScale.arrowThickness.level(of: width, pixelsPerPoint: 2) - level) < 0.0001)
        }
    }

    @Test func aThickerArrowReachesFurtherFromItsShaft() throws {
        let base = solidImage(width: 200, height: 100)
        func drawn(_ lineWidth: CGFloat) throws -> Pixels {
            let arrow = Annotation(kind: .arrow, start: CGPoint(x: 10, y: 50), end: CGPoint(x: 190, y: 50), lineWidth: lineWidth)
            return try Pixels(#require(AnnotationRenderer.flatten(base, [arrow])))
        }
        #expect(try drawn(2).isWhite(x: 60, y: 56), "6 px off a 2 px shaft is inked")
        #expect(try drawn(18).isInk(x: 60, y: 56), "6 px off an 18 px shaft stays white")
    }

    @Test func changingTheThicknessIsOneUndoStep() {
        let document = AnnotationDocument(base: stripedImage(width: 200, height: 100))
        let arrow = Annotation(kind: .arrow, start: CGPoint(x: 20, y: 50), end: CGPoint(x: 180, y: 50), lineWidth: 6)
        document.add(arrow)
        document.setSliderSize(arrow.id, 18)
        #expect(document.annotation(arrow.id)?.lineWidth == 18)
        #expect(document.undoManager.undoActionName == "Change Arrow Thickness")
        document.undoManager.undo()
        #expect(document.annotation(arrow.id)?.lineWidth == 6)
    }

    @Test func theArrowToolDrawsAtTheChosenThickness() throws {
        let harness = CanvasHarness()
        harness.canvas.tool = .arrow
        harness.canvas.setSliderLevel(1, committing: true)
        #expect(!harness.document.undoManager.canUndo, "a thickness for the next arrow isn't an edit")
        harness.drag(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 180, y: 50))
        let drawn = try #require(harness.document.annotations.first)
        #expect(drawn.lineWidth == SliderScale.arrowThickness.size(at: 1, pixelsPerPoint: 1))
    }

    @Test func aThicknessDragShowsOnTheCanvasAndLandsAsOneUndoStep() throws {
        let harness = CanvasHarness()
        let arrow = Annotation(kind: .arrow, start: CGPoint(x: 20, y: 50), end: CGPoint(x: 180, y: 50), lineWidth: 6)
        harness.document.add(arrow)
        harness.canvas.tool = .select
        harness.drag(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 100, y: 50))
        try #require(harness.canvas.selectedID == arrow.id)
        let selected = try #require(harness.canvas.sliderTarget)
        #expect(selected.tool == .arrow)
        #expect(abs(selected.level - SliderScale.arrowThickness.level(of: 6, pixelsPerPoint: 1)) < 0.0001)

        harness.canvas.setSliderLevel(0.8, committing: false)
        #expect(harness.document.annotation(arrow.id)?.lineWidth == 6, "a drag in progress wrote to the document")
        harness.canvas.setSliderLevel(1, committing: true)
        #expect(harness.document.annotation(arrow.id)?.lineWidth == SliderScale.arrowThickness.size(at: 1, pixelsPerPoint: 1))
        #expect(harness.document.undoManager.undoActionName == "Change Arrow Thickness")
        harness.document.undoManager.undo()
        #expect(harness.document.annotation(arrow.id)?.lineWidth == 6)
    }

    @Test func aSelectedArrowIsLeftAloneWhileTheBlurToolIsOn() throws {
        let harness = CanvasHarness()
        let arrow = Annotation(kind: .arrow, start: CGPoint(x: 20, y: 50), end: CGPoint(x: 180, y: 50), lineWidth: 6)
        harness.document.add(arrow)
        harness.canvas.tool = .select
        harness.drag(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 100, y: 50))
        try #require(harness.canvas.selectedID == arrow.id)
        harness.canvas.tool = .blur
        #expect(harness.canvas.sliderTarget?.tool == .blur)
        harness.canvas.setSliderLevel(1, committing: true)
        #expect(harness.document.annotation(arrow.id)?.lineWidth == 6)
    }

    @Test func eachSliderOpensOnlyForTheToolsItAdjusts() {
        let editor = makeEditor(width: 200, height: 100)
        let thickness = editor.thicknessDrawer, intensity = editor.intensityDrawer
        #expect(editor.canvas.tool == .arrow)
        #expect(thickness.isOpen && !thickness.slider.isHidden)
        #expect(thickness.slider.accessibilityLabel() == "Arrow thickness")
        #expect(!intensity.isOpen && intensity.slider.isHidden)
        editor.canvas.tool = .blur
        #expect(!thickness.isOpen && thickness.slider.isHidden)
        #expect(intensity.isOpen && !intensity.slider.isHidden)
        #expect(intensity.slider.accessibilityLabel() == "Blur intensity")
        editor.canvas.tool = .pixelate
        #expect(intensity.slider.accessibilityLabel() == "Pixelate intensity")
        editor.canvas.tool = .rectangle
        #expect(!thickness.isOpen && thickness.slider.isHidden)
        #expect(!intensity.isOpen && intensity.slider.isHidden)
    }

    /// 200×100 px opens the editor at its minimum content size.
    @Test(arguments: [EditorCanvas.Tool.arrow, .blur])
    func anOpenSliderFitsTheSmallestWindow(tool: EditorCanvas.Tool) throws {
        let editor = makeEditor(width: 200, height: 100)
        let content = try #require(editor.window.contentView)
        let minimum = editor.window.contentMinSize.width
        editor.canvas.tool = tool
        content.layoutSubtreeIfNeeded()
        #expect(
            content.bounds.width == minimum,
            "the open dock (\(editor.dock.fittingSize.width) pt) grew a \(minimum) pt window to \(content.bounds.width) pt"
        )
        let drawer = tool == .arrow ? editor.thicknessDrawer : editor.intensityDrawer
        let dock = editor.dock.convert(editor.dock.bounds, to: nil)
        let slider = drawer.slider.convert(drawer.slider.bounds, to: nil)
        #expect(dock.minX >= 16 && dock.maxX <= content.bounds.width - 16, "open dock \(dock) spills out of a \(content.bounds.width) pt window")
        #expect(dock.insetBy(dx: -0.5, dy: -0.5).contains(slider), "slider \(slider) sticks out of the dock \(dock)")
    }

    @Test(arguments: [
        (EditorCanvas.Tool.rectangle, EditorCanvas.Tool.arrow),
        (.select, .blur),
        (.arrow, .pixelate),
        (.blur, .arrow),
    ])
    func openingASliderLeavesTheButtonThatOpenedItInPlace(from: EditorCanvas.Tool, to: EditorCanvas.Tool) throws {
        let editor = makeEditor(width: 2400, height: 800)
        let content = try #require(editor.window.contentView)
        let button = try #require(editor.toolButtons[to])
        editor.canvas.tool = from
        content.layoutSubtreeIfNeeded()
        let before = button.convert(button.bounds, to: nil)
        editor.canvas.tool = to
        content.layoutSubtreeIfNeeded()
        let after = button.convert(button.bounds, to: nil)
        #expect(abs(after.minX - before.minX) < 1, "the \(to) button moved from \(before.minX) to \(after.minX)")
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
