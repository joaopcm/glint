import Foundation

@objc protocol RenderServiceProtocol {
    func render(projectFolder: URL, reply: @escaping @Sendable (NSError?) -> Void)
}

@objc protocol RenderProgressReceiving {
    func progress(_ fraction: Double)
}
