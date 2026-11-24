public enum PickerPromptNotice {
    /// Majors seen showing "is requesting to bypass the system private window picker": 15 (run 45266766603) and 26.7.2
    /// (run 45503843075). 27.2.1 didn't show it (https://github.com/joaopcm/glint/issues/64).
    static let promptingMacOSMajors: Set<Int> = [15, 26]

    public static let message = "macOS will ask to let Glint bypass the private window picker. Click Allow so Glint can capture your screen."

    public static func shouldExplain(macOSMajor: Int, alreadyExplained: Bool) -> Bool {
        !alreadyExplained && promptingMacOSMajors.contains(macOSMajor)
    }
}
