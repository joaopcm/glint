import AppKit
import CoreGraphics
import Testing
@testable import LunettaEditor

@MainActor
struct AnnotationColorTests {
    let base = solidImage(width: 200, height: 100)

    @Test func tenDistinctPresetsRoundTripThroughHex() {
        #expect(AnnotationColor.presets.count == 10)
        #expect(Set(AnnotationColor.presets.map(\.color)).count == 10)
        #expect(Set(AnnotationColor.presets.map(\.name)).count == 10)
        for preset in AnnotationColor.presets {
            #expect(AnnotationColor(hex: preset.color.hexString) == preset.color)
            #expect(AnnotationColor(hex: preset.color.hexString.lowercased()) == preset.color)
            #expect(preset.color.accessibilityName == preset.name)
        }
    }

    @Test func invalidHexReturnsNil() {
        for invalid in ["", "#12345", "#1234567", "#GGGGGG", "not-a-color"] {
            #expect(AnnotationColor(hex: invalid) == nil)
        }
        let withoutHash = AnnotationColor(hex: "30D158")
        #expect(withoutHash == .green)
    }

    @Test func arrowRectangleAndTextRenderInTheirChosenColor() throws {
        let greenArrow = Annotation(
            kind: .arrow,
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 190, y: 20),
            lineWidth: 6,
            color: .green
        )
        let blueBox = Annotation(
            kind: .rectangle,
            start: CGPoint(x: 20, y: 40),
            end: CGPoint(x: 90, y: 85),
            lineWidth: 6,
            color: .blue
        )
        let purpleText = Annotation.text("HI", at: CGPoint(x: 110, y: 40), lineHeight: 36, color: .purple)
        let pixels = try Pixels(#require(AnnotationRenderer.flatten(base, [greenArrow, blueBox, purpleText])))

        let arrowPixel = pixels.rgb(x: 80, y: 20)
        #expect(arrowPixel.g > 180 && arrowPixel.r < 100 && arrowPixel.b < 120)

        let boxPixel = pixels.rgb(x: 20, y: 60)
        #expect(boxPixel.b > 200 && boxPixel.r < 50 && boxPixel.g < 150)

        var purpleGlyphPixels = 0
        for y in 40..<80 {
            for x in 110..<195 {
                let p = pixels.rgb(x: x, y: y)
                if p.b > 180 && p.r > 80 && p.g < 120 { purpleGlyphPixels += 1 }
            }
        }
        #expect(purpleGlyphPixels > 50)
    }

    @Test func recoloringAndEditingTextKeepsItsColor() throws {
        let document = AnnotationDocument(base: base)
        let label = Annotation.text("hello", at: CGPoint(x: 10, y: 10), lineHeight: 24, color: .red)
        document.add(label)

        document.setColor(label.id, .teal)
        #expect(document.annotation(label.id)?.color == .teal)

        document.setText(label.id, "updated")
        #expect(document.annotation(label.id)?.color == .teal)

        document.undoManager.undo()
        document.undoManager.undo()
        #expect(document.annotation(label.id)?.color == .red)
    }

    @Test func recoloringSelectedAnnotationSupportsUndoRedoAndCoalescesDrags() throws {
        let document = AnnotationDocument(base: base)
        let box = Annotation(kind: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 80, y: 60), lineWidth: 4, color: .red)
        document.add(box)

        document.setColor(box.id, .green)
        #expect(document.annotation(box.id)?.color == .green)
        #expect(document.undoManager.undoActionName == "Change Color")

        document.undoManager.undo()
        #expect(document.annotation(box.id)?.color == .red)
        document.undoManager.redo()
        #expect(document.annotation(box.id)?.color == .green)

        document.setColor(box.id, .orange, coalescing: false)
        document.setColor(box.id, .purple, coalescing: true)
        document.setColor(box.id, .blue, coalescing: true)
        #expect(document.annotation(box.id)?.color == .blue)

        document.undoManager.undo()
        #expect(document.annotation(box.id)?.color == .green, "all coalesced drag samples undo in one step")
        document.undoManager.redo()
        #expect(document.annotation(box.id)?.color == .blue)
    }

    @Test func nonColoredAnnotationsIgnoreSetColorWithoutAddingUndoStep() {
        let document = AnnotationDocument(base: base)
        let blur = Annotation(kind: .blur(sigma: 12), start: CGPoint(x: 10, y: 10), end: CGPoint(x: 50, y: 50), lineWidth: 4)
        document.add(blur)

        document.setColor(blur.id, .green)
        #expect(document.undoManager.undoActionName == "Add Blur")
        document.undoManager.undo()
        #expect(document.annotations.isEmpty)
    }

    @Test func paletteHighlightsPresetOrCustomAndRecolorsSelection() throws {
        let custom = try #require(AnnotationColor(hex: "#12AB34"))
        var remembered: [AnnotationColor] = []
        let document = AnnotationDocument(base: base)
        let editor = AnnotationEditor(
            document: document,
            title: "Test",
            pixelsPerPoint: 2,
            initialColor: custom,
            onColorChange: { remembered.append($0) },
            save: { _ in },
            onClose: {}
        )
        defer { editor.window.close() }

        #expect(editor.colorButton.color == custom)
        editor.openColorPalette()
        let panel = try #require(editor.palettePanel)
        #expect(panel.customButton.state == .on)
        #expect(panel.presetButtons.values.allSatisfy { $0.state == .off })
        #expect(editor.captionHost.isHidden, "caption stays out of the way while the palette is open")

        let greenButton = try #require(panel.presetButtons[.green])
        greenButton.performClick(nil)
        #expect(editor.palettePanel == nil)
        #expect(editor.canvas.color == .green)
        #expect(remembered == [.green])

        let arrow = Annotation(kind: .arrow, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 50), lineWidth: 6, color: .red)
        document.add(arrow)
        editor.canvas.tool = .select
        let clickPoint = editor.canvas.convert(
            CGPoint(
                x: editor.canvas.imageRect.minX + 50 * (editor.canvas.imageRect.width / 200),
                y: editor.canvas.imageRect.minY + 30 * (editor.canvas.imageRect.height / 100)
            ),
            to: nil
        )
        if let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: clickPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: editor.window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: clickPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: editor.window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ) {
            editor.canvas.mouseDown(with: down)
            editor.canvas.mouseUp(with: up)
        }
        #expect(editor.canvas.selectedID == arrow.id)
        #expect(editor.colorButton.color == .red, "pill reflects the selected arrow's color")
        #expect(editor.canvas.color == .green, "selecting alone keeps the drawing color for new annotations")

        editor.applyColor(.purple)
        #expect(document.annotation(arrow.id)?.color == .purple)
        #expect(editor.canvas.color == .purple)
        #expect(remembered == [.green, .purple])
    }
}
