import AppKit
import GlintCapture
import GlintEditor
import ImageIO

enum CaptureEditorError: LocalizedError, Equatable {
    case unreadable(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason): "Glint couldn't read \(path): \(reason)."
        }
    }
}

@MainActor
enum CaptureEditor {
    static func open(
        _ document: AnnotationDocument,
        savingTo url: URL,
        on screen: NSScreen,
        onSaved: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) -> AnnotationEditor {
        let editor = AnnotationEditor(
            document: document,
            title: url.lastPathComponent,
            pixelsPerPoint: screen.backingScaleFactor,
            save: { image in
                try PNGWriter.write(image, to: url)
                onSaved()
            },
            onClose: onClose
        )
        editor.canvas.setAccessibilityIdentifier(AccessibilityID.editorCanvas)
        editor.show(on: screen)
        return editor
    }

    static func image(at url: URL) throws -> CGImage {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CaptureEditorError.unreadable(path: url.path, reason: "No such file or directory")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw CaptureEditorError.unreadable(path: url.path, reason: "ImageIO could not decode it as an image") }
        return image
    }
}
