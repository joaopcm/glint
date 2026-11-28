import Foundation
import LunettaCapture
import LunettaCore
import Observation
import Synchronization

enum RenderPhase: Equatable {
    case queued
    case rendering(Double)
    case compressing
    case done(CompressionResult?)
    case failed(String)

    var isFinished: Bool {
        switch self {
        case .done, .failed: true
        case .queued, .rendering, .compressing: false
        }
    }
}

@MainActor @Observable
final class RenderJob {
    let project: RecordingProject
    private(set) var phase: RenderPhase = .queued
    @ObservationIgnored private weak var queue: RenderQueue?
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    fileprivate init(project: RecordingProject, queue: RenderQueue) {
        self.project = project
        self.queue = queue
    }

    func retry() {
        guard case .failed = phase else { return }
        queue?.schedule(self)
    }

    func finished() async {
        guard !phase.isFinished else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    fileprivate func move(to phase: RenderPhase) {
        self.phase = phase
        guard phase.isFinished else { return }
        let ready = waiters
        waiters = []
        for waiter in ready { waiter.resume() }
    }

    /// Progress arrives in tasks that can land out of order, or after the render moved on.
    fileprivate func advance(to fraction: Double) {
        guard case let .rendering(shown) = phase, fraction > shown else { return }
        phase = .rendering(fraction)
    }
}

@MainActor
final class RenderQueue {
    nonisolated static let serviceName = "com.joaopcm.lunetta.render"

    private let store: ProjectStore
    private let settings: LunettaSettings
    private let render: (URL, @escaping @Sendable (Double) -> Void) async throws -> Void
    private let compress: @Sendable (URL) async throws -> CompressionResult?
    private var waiting: [RenderJob] = []
    private var draining = false

    init(
        store: ProjectStore,
        settings: LunettaSettings,
        render: @escaping (URL, @escaping @Sendable (Double) -> Void) async throws -> Void = RenderQueue.renderInService,
        compress: @escaping @Sendable (URL) async throws -> CompressionResult? = CaptureCompressor.compress
    ) {
        self.store = store
        self.settings = settings
        self.render = render
        self.compress = compress
    }

    func enqueue(_ project: RecordingProject) -> RenderJob {
        let job = RenderJob(project: project, queue: self)
        schedule(job)
        return job
    }

    func resumePending() -> [RenderJob] {
        store.pendingRenders().map(enqueue)
    }

    fileprivate func schedule(_ job: RenderJob) {
        job.move(to: .queued)
        waiting.append(job)
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        while !waiting.isEmpty {
            await run(waiting.removeFirst())
        }
        draining = false
    }

    private func run(_ job: RenderJob) async {
        job.move(to: .rendering(0))
        do {
            try await render(store.folder(for: job.project.id)) { fraction in
                Task { @MainActor in job.advance(to: fraction) }
            }
        } catch is CancellationError {
            job.move(to: .queued)
            return
        } catch {
            job.move(to: .failed(error.localizedDescription))
            return
        }

        let file = job.project.output.file
        var rendered = job.project
        rendered.renderedAt = Date()
        do {
            try store.save(rendered)
        } catch {
            job.move(to: .failed(
                "Rendered \(file.lastPathComponent), but couldn't mark its project as rendered, so it renders again at next launch: \(error.localizedDescription)"
            ))
            return
        }

        guard settings.compressAfterCapture else {
            job.move(to: .done(nil))
            return
        }
        job.move(to: .compressing)
        do {
            job.move(to: .done(try await compress(file)))
        } catch {
            job.move(to: .failed(error.localizedDescription))
        }
    }

    nonisolated static func renderInService(_ projectFolder: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let outcome = ServiceOutcome()
        try await withTaskCancellationHandler {
            try await render(projectFolder, inServiceUntil: outcome, progress: progress)
        } onCancel: {
            outcome.finish(CancellationError())
        }
    }

    private nonisolated static func render(
        _ projectFolder: URL,
        inServiceUntil outcome: ServiceOutcome,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: RenderServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: RenderProgressReceiving.self)
        connection.exportedObject = ProgressForwarder(progress)
        connection.interruptionHandler = { outcome.finish(RenderServiceError.serviceQuit) }
        connection.invalidationHandler = { outcome.finish(RenderServiceError.connectionClosed) }
        defer { connection.invalidate() }
        try await withCheckedThrowingContinuation { continuation in
            outcome.wait(continuation)
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in outcome.finish(RenderServiceError(xpcError: error)) }
            guard let service = proxy as? RenderServiceProtocol else {
                outcome.finish(RenderServiceError.unreachable("its connection gave a \(type(of: proxy)), not a RenderServiceProtocol"))
                return
            }
            service.render(projectFolder: projectFolder) { error in outcome.finish(error) }
        }
    }
}

enum RenderServiceError: LocalizedError, Equatable {
    case serviceQuit
    case connectionClosed
    case unreachable(String)

    init(xpcError error: any Error) {
        switch (error as NSError).code {
        case NSXPCConnectionInterrupted: self = .serviceQuit
        case NSXPCConnectionInvalid: self = .connectionClosed
        default: self = .unreachable(error.localizedDescription)
        }
    }

    var errorDescription: String? {
        switch self {
        case .serviceQuit:
            "Lunetta's render service quit before the video was done. It may have crashed or run out of memory."
        case .connectionClosed:
            "Lunetta lost its connection to the render service before the video was done."
        case let .unreachable(reason):
            "Lunetta couldn't reach its render service: \(reason)"
        }
    }
}

private final class ProgressForwarder: NSObject, RenderProgressReceiving {
    private let forward: @Sendable (Double) -> Void

    init(_ forward: @escaping @Sendable (Double) -> Void) {
        self.forward = forward
    }

    func progress(_ fraction: Double) {
        forward(fraction)
    }
}

/// The reply, the proxy's error handler, the connection's handlers and cancellation all race to end one render;
/// the first one decides it and the rest are ignored.
private final class ServiceOutcome: Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<Void, any Error>)
        case decided((any Error)?)
        case delivered
    }

    private let state = Mutex(State.pending)

    func wait(_ continuation: CheckedContinuation<Void, any Error>) {
        let decided: (any Error)?? = state.withLock { state in
            guard case let .decided(error) = state else {
                state = .waiting(continuation)
                return .none
            }
            state = .delivered
            return .some(error)
        }
        if case let .some(error) = decided { Self.resume(continuation, with: error) }
    }

    func finish(_ error: (any Error)?) {
        let waiting: CheckedContinuation<Void, any Error>? = state.withLock { state in
            switch state {
            case .pending:
                state = .decided(error)
                return nil
            case let .waiting(continuation):
                state = .delivered
                return continuation
            case .decided, .delivered:
                return nil
            }
        }
        if let waiting { Self.resume(waiting, with: error) }
    }

    private static func resume(_ continuation: CheckedContinuation<Void, any Error>, with error: (any Error)?) {
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
