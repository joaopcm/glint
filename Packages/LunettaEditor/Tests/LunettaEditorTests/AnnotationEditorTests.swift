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
}
