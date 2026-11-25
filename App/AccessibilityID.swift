enum AccessibilityID {
    static let selectionOverlay = "lunetta.selectionOverlay"
    static let toast = "lunetta.toast"
    static let loupe = "lunetta.loupe"
    static let testConnection = "lunetta.testConnection"
    static let makeLinksPublic = "lunetta.makeLinksPublic"
    static let editorCanvas = "lunetta.editorCanvas"
    static let uploadHistoryLink = "lunetta.uploadHistoryLink"
    static let uploadHistoryError = "lunetta.uploadHistoryError"
    static let deleteUpload = "lunetta.deleteUpload"
    static let uploadProgress = "lunetta.uploadProgress"
    static let stopRecording = "lunetta.stopRecording"
    static let recordingCountdown = "lunetta.recordingCountdown"
    static let recordingTime = "lunetta.recordingTime"
    static let pauseRecording = "lunetta.pauseRecording"
    static let stopRecordingControl = "lunetta.stopRecordingControl"
    static let discardRecording = "lunetta.discardRecording"
    static let cardActionLabel = "lunetta.cardActionLabel"
    static let restoreDefaultShortcuts = "lunetta.restoreDefaultShortcuts"

    static func connectionStep(_ step: String) -> String { "lunetta.connectionStep.\(step)" }
}
