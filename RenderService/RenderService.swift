import Foundation
import LunettaCore
import LunettaStudio
import Synchronization

final class RenderServiceListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: RenderServiceProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: RenderProgressReceiving.self)
        let renderer = ProjectRenderer(receiver: connection.remoteObjectProxyWithErrorHandler { _ in } as? RenderProgressReceiving)
        connection.exportedObject = renderer
        connection.invalidationHandler = { renderer.cancel() }
        connection.resume()
        return true
    }
}

/// NSXPC proxies take messages from any thread, so the receiver is safe to share.
final class ProjectRenderer: NSObject, RenderServiceProtocol, @unchecked Sendable {
    private static let errorDomain = "com.joaopcm.lunetta.render"
    private static let scratchFileName = "render.partial.mp4"

    private let receiver: RenderProgressReceiving?
    private let lastPercentSent = Mutex(-1)
    private let work = Mutex<(task: Task<Void, Never>?, cancelled: Bool)>((nil, false))

    init(receiver: RenderProgressReceiving?) {
        self.receiver = receiver
    }

    func render(projectFolder: URL, reply: @escaping @Sendable (NSError?) -> Void) {
        let task = Task {
            do {
                try await Self.render(projectFolder) { self.send($0) }
                reply(nil)
            } catch {
                reply(NSError(domain: Self.errorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]))
            }
        }
        work.withLock { work in
            work.task = task
            if work.cancelled { task.cancel() }
        }
    }

    func cancel() {
        work.withLock { work in
            work.cancelled = true
            work.task?.cancel()
        }
    }

    private func send(_ fraction: Double) {
        let percent = Int((fraction * 100).rounded(.down))
        let changed = lastPercentSent.withLock { last in
            defer { last = percent }
            return percent != last
        }
        if changed { receiver?.progress(Double(percent) / 100) }
    }

    private static func render(_ folder: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let id = UUID(uuidString: folder.lastPathComponent) else {
            throw ProjectError.unreadable(file: folder.path, reason: "the folder isn't named after a project ID")
        }
        let project = try ProjectStore(root: folder.deletingLastPathComponent()).load(id)
        let composition = try await ProjectComposition.make(project: project, folder: folder)
        try await ProjectExporter.export(
            composition,
            codec: project.output.codec,
            frameRate: project.output.frameRate,
            to: project.output.file,
            scratch: folder.appending(path: scratchFileName),
            budget: .render,
            progress: progress
        )
    }
}
