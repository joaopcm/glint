import AVFoundation
import Foundation
import GlintCore
import ScreenCaptureKit
import Synchronization

public enum RecordingTarget: Sendable, Equatable {
    /// `selection` is in AppKit global coordinates, like the area overlay's result.
    case area(CGRect, on: DisplayInfo)
    case window(UInt32)
}

public struct RecordingOptions: Sendable, Equatable {
    public var codec: VideoCodec
    public var systemAudio: Bool
    public var microphone: Bool

    public init(codec: VideoCodec, systemAudio: Bool, microphone: Bool) {
        self.codec = codec
        self.systemAudio = systemAudio
        self.microphone = microphone
    }
}

/// A running SCStream writing straight to an MP4 through SCRecordingOutput.
public actor ScreenRecording {
    private let stream: SCStream
    private let events: RecordingEvents
    private let url: URL

    fileprivate init(stream: SCStream, events: RecordingEvents, url: URL) {
        self.stream = stream
        self.events = events
        self.url = url
    }

    /// Stopping before the first frame reaches the file fails the whole recording with RPRecordingErrorDomain -5822
    /// ("failure to process first sample buffer"). Waiting for `recordingOutputDidStartRecording` still failed 13 of 30
    /// instant stops; waiting for the first complete frame passed 75 of 75 (probes for #17).
    public func stop() async {
        await events.waitUntilFirstFrameOrEnd()
        // Fails with -3808 when the stream already stopped on its own; the recording's own outcome reports that.
        await withCheckedContinuation { continuation in
            stream.stopCapture { _ in continuation.resume() }
        }
    }

    /// Returns once the file is finalized; throws when it is missing or only partly recorded.
    public func finished() async throws {
        switch await events.outcome() {
        case .finished(nil):
            return
        case .finished(let streamError?):
            throw CaptureError.recordingStoppedEarly(path: url.path, reason: streamError)
        case .failed(let reason):
            throw CaptureError.recordingFailed(path: url.path, reason: reason)
        }
    }
}

extension ScreenCapturer {
    public func record(_ target: RecordingTarget, to url: URL, options: RecordingOptions) async throws -> ScreenRecording {
        try Self.requirePermission()
        let (filter, configuration) = try await Self.recordingSetup(for: target)
        Self.apply(options, to: configuration)
        let output = SCRecordingOutputConfiguration()
        output.outputURL = url
        output.outputFileType = .mp4
        output.videoCodecType = options.codec == .hevc ? .hevc : .h264
        let events = RecordingEvents()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: events)
        do {
            try stream.addStreamOutput(events, type: .screen, sampleHandlerQueue: events.queue)
            try stream.addRecordingOutput(SCRecordingOutput(configuration: output, delegate: events))
            try await stream.startCapture()
        } catch SCStreamError.userDeclined {
            throw CaptureError.permissionDenied
        } catch {
            throw CaptureError.recordingFailed(path: url.path, reason: error.localizedDescription)
        }
        return ScreenRecording(stream: stream, events: events, url: url)
    }

    static func apply(_ options: RecordingOptions, to configuration: SCStreamConfiguration) {
        configuration.showsCursor = true
        configuration.capturesAudio = options.systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = options.microphone
    }

    private static func recordingSetup(for target: RecordingTarget) async throws -> sending (SCContentFilter, SCStreamConfiguration) {
        let configuration = SCStreamConfiguration()
        switch target {
        case .area(let selection, let display):
            guard let sourceRect = DisplayGeometry.sourceRect(for: selection, on: display),
                  let region = RecordingGeometry.evenPixelRegion(of: sourceRect, scale: display.scale)
            else { throw CaptureError.emptySelection }
            configuration.sourceRect = region.sourceRect
            configuration.width = region.width
            configuration.height = region.height
            return (try await filterExcludingGlint(displayID: display.id), configuration)
        case .window(let id):
            guard let window = try await shareableContent().windows.first(where: { $0.windowID == id }) else {
                throw CaptureError.windowNotFound(id)
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            guard let region = RecordingGeometry.evenPixelRegion(of: filter.contentRect, scale: CGFloat(filter.pointPixelScale)) else {
                throw CaptureError.windowNotFound(id)
            }
            configuration.width = region.width
            configuration.height = region.height
            return (filter, configuration)
        }
    }
}

private enum RecordingOutcome: Sendable {
    /// `streamError` is why the stream stopped on its own; the file still holds everything up to then
    /// (closing the recorded window finalized a playable file in the probe for #17).
    case finished(streamError: String?)
    case failed(String)
}

private final class RecordingEvents: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, SCStreamOutput, Sendable {
    private struct State {
        var hasFirstFrame = false
        var streamError: String?
        var outcome: RecordingOutcome?
        var startWaiters: [CheckedContinuation<Void, Never>] = []
        var outcomeWaiters: [CheckedContinuation<RecordingOutcome, Never>] = []
    }

    private let state = Mutex(State())
    let queue = DispatchQueue(label: "com.joaopcm.glint.recording-frames")

    func waitUntilFirstFrameOrEnd() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                guard !state.hasFirstFrame, state.outcome == nil else { return true }
                state.startWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func outcome() async -> RecordingOutcome {
        await withCheckedContinuation { continuation in
            let outcome = state.withLock { state in
                if state.outcome == nil { state.outcomeWaiters.append(continuation) }
                return state.outcome
            }
            if let outcome { continuation.resume(returning: outcome) }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard Self.isCompleteFrame(sampleBuffer) else { return }
        let waiters = state.withLock { state in
            guard !state.hasFirstFrame else { return [CheckedContinuation<Void, Never>]() }
            state.hasFirstFrame = true
            defer { state.startWaiters = [] }
            return state.startWaiters
        }
        waiters.forEach { $0.resume() }
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int
        else { return false }
        return SCFrameStatus(rawValue: status) == .complete
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        end { .finished(streamError: $0.streamError) }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        end { _ in .failed(error.localizedDescription) }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        state.withLock { $0.streamError = error.localizedDescription }
    }

    private func end(_ outcome: (State) -> RecordingOutcome) {
        let (resolved, startWaiters, outcomeWaiters) = state.withLock { state in
            let resolved = state.outcome ?? outcome(state)
            state.outcome = resolved
            defer {
                state.startWaiters = []
                state.outcomeWaiters = []
            }
            return (resolved, state.startWaiters, state.outcomeWaiters)
        }
        startWaiters.forEach { $0.resume() }
        outcomeWaiters.forEach { $0.resume(returning: resolved) }
    }
}
