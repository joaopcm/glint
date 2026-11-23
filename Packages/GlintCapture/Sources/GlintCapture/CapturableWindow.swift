import CoreGraphics

public struct CapturableWindow: Sendable, Equatable {
    public let id: UInt32
    public let frame: CGRect
    public let title: String?
    public let appName: String?

    public init(id: UInt32, frame: CGRect, title: String?, appName: String?) {
        self.id = id
        self.frame = frame
        self.title = title
        self.appName = appName
    }
}
