public enum OverlayStyle {
    // emil-design-eng: enter and exit under 300 ms, exit faster than enter, and its strong ease-out curve (#92).
    public static let enterDuration: Double = 0.25
    public static let exitDuration: Double = 0.2
    public static let easeOutControlPoints: (Double, Double, Double, Double) = (0.23, 1, 0.32, 1)

    public static let clickDiameter: Double = 36
    public static let clickFillAlpha: Double = 0.2
    public static var clickPulseDuration: Double { enterDuration + exitDuration }
    public static let clickStartScale: Double = 0.3

    /// 1.5 s after the last press: six times the 0.25 s one word takes at 238 wpm (Brysbaert 2019,
    /// doi:10.1016/j.jml.2019.104047), so someone watching the action, not the label, still catches it.
    public static let keysLinger: Double = 1.5
    public static let keysHeight: Double = 52
    public static let keysBottomInset: Double = 24
    public static let keysFontSize: Double = 22
    public static let keysCornerRadius: Double = 12
    public static let keysBackgroundAlpha: Double = 0.72
    public static let keysHorizontalPadding: Double = 28

    /// Keeps the circle's edge from melting into a dark recording.
    public static let bubbleBorderAlpha: Double = 0.25
    public static let bubbleBorderWidth: Double = 1
    /// Mirrored like FaceTime's own view, so pointing left on camera points left on screen.
    public static let cameraMirrored: Bool = true
}
