enum AccessibilityID {
    static let selectionOverlay = "glint.selectionOverlay"
    static let toast = "glint.toast"
    static let loupe = "glint.loupe"
    static let testConnection = "glint.testConnection"
    static let makeLinksPublic = "glint.makeLinksPublic"
    static let editorCanvas = "glint.editorCanvas"
    static let uploadHistoryLink = "glint.uploadHistoryLink"
    static let uploadHistoryError = "glint.uploadHistoryError"
    static let deleteUpload = "glint.deleteUpload"
    static let uploadProgress = "glint.uploadProgress"
    static let stopRecording = "glint.stopRecording"
    static let cardActionLabel = "glint.cardActionLabel"
    static let restoreDefaultShortcuts = "glint.restoreDefaultShortcuts"

    static func connectionStep(_ step: String) -> String { "glint.connectionStep.\(step)" }
}
