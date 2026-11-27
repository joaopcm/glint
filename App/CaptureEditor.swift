import AppKit
import LunettaCapture
import LunettaCore
import LunettaEditor
import ImageIO

enum CaptureEditorError: LocalizedError, Equatable {
    case unreadable(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason): "Lunetta couldn't read \(path): \(reason)."
        }
    }
}

@MainActor
enum CaptureEditor {
    static func open(
        _ document: AnnotationDocument,
        savingTo url: URL,
        on screen: NSScreen,
        settings: LunettaSettings,
        onSaved: @escaping (CGImage) -> Void,
        onClose: @escaping () -> Void
    ) -> AnnotationEditor {
        let editor = AnnotationEditor(
            document: document,
            title: url.lastPathComponent,
            pixelsPerPoint: screen.backingScaleFactor,
            initialColor: AnnotationColor(hex: settings.annotationColor) ?? .red,
            onColorChange: { color in settings.annotationColor = color.hexString },
            save: { image in
                try PNGWriter.write(image, to: url)
                onSaved(image)
            },
            onClose: onClose
        )
        editor.canvas.setAccessibilityIdentifier(AccessibilityID.editorCanvas)
        editor.show(on: screen)
        Task { await document.loadTextLayout() }
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
