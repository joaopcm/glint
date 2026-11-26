import AppKit
import Testing
@testable import LunettaEditor

@MainActor
struct AnnotationEditorTests {
    @Test func everyToolIsInTheToolbarOnce() {
        let tools = AnnotationEditor.toolGroups.flatMap { $0 }.map(\.tool)
        #expect(tools.count == EditorCanvas.Tool.allCases.count)
        #expect(Set(tools.map(\.shortcut)).count == tools.count)
    }

    /// A missing symbol crashes the editor on open: the buttons force-unwrap their images.
    @Test func everyButtonSymbolExists() {
        let symbols = AnnotationEditor.toolGroups.flatMap { $0 }.map(\.symbol) + [AnnotationEditor.undoSymbol, AnnotationEditor.redoSymbol]
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "no SF Symbol named \(symbol)")
        }
    }

    @Test func shortcutsSelectTheirTool() {
        for tool in EditorCanvas.Tool.allCases {
            #expect(EditorCanvas.shortcuts[tool.shortcut] == tool)
        }
    }

    /// 3024×1964 is a 14" MacBook Pro screen at 2 px per point: the image fills the canvas right down to its inset.
    @Test(arguments: [(200, 100), (3024, 1964)])
    func captionNeverCoversTheImage(width: Int, height: Int) throws {
        let editor = AnnotationEditor(
            document: AnnotationDocument(base: solidImage(width: width, height: height)),
            title: "Test",
            pixelsPerPoint: 2,
            save: { _ in },
            onClose: {}
        )
        let content = try #require(editor.window.contentView)

        let hint = captionAndImageFrames(in: editor, content: content)
        #expect(!hint.caption.intersects(hint.image), "hint caption \(hint.caption) covers image \(hint.image)")

        let arrow = try #require(editor.toolButtons[.arrow])
        arrow.onHoverChange?(arrow, true)
        let hovered = captionAndImageFrames(in: editor, content: content)
        #expect(!hovered.caption.intersects(hovered.image), "hover caption \(hovered.caption) covers image \(hovered.image)")
    }

    private func captionAndImageFrames(in editor: AnnotationEditor, content: NSView) -> (caption: CGRect, image: CGRect) {
        content.layoutSubtreeIfNeeded()
        #expect(!editor.captionHost.isHidden)
        return (
            editor.captionHost.convert(editor.captionHost.bounds, to: nil),
            editor.canvas.convert(editor.canvas.imageRect, to: nil)
        )
    }
}
