import AVFoundation
import CoreImage
import Metal

final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol, Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let renderer: StudioFrameRenderer
    let timeline: ProjectTimeline

    var requiredSourceTrackIDs: [NSValue]? {
        ([screenTrackID] + [cameraTrackID].compactMap { $0 }).map { NSNumber(value: $0) }
    }

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?, renderer: StudioFrameRenderer, timeline: ProjectTimeline) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.renderer = renderer
        self.timeline = timeline
    }
}

final class StudioCompositor: NSObject, AVVideoCompositing, Sendable {
    private static let pixelBufferAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    private static var bt709: CFDictionary {
        [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ] as CFDictionary
    }

    private let context: CIContext
    private let outputColorSpace = CVImageBufferCreateColorSpaceFromAttachments(StudioCompositor.bt709)!.takeRetainedValue()

    let sourcePixelBufferAttributes: [String: any Sendable]? = StudioCompositor.pixelBufferAttributes
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = StudioCompositor.pixelBufferAttributes

    /// WindowServer blends today's on-screen overlays in gamma-encoded sRGB, so a linear working space would draw their
    /// soft edges differently from the recordings people already have.
    override init() {
        let options: [CIContextOption: Any] = [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .cacheIntermediates: false]
        context = MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        do {
            request.finish(withComposedVideoFrame: try render(request))
        } catch {
            request.finish(with: error)
        }
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) throws -> CVPixelBuffer {
        let seconds = request.compositionTime.seconds
        guard let instruction = request.videoCompositionInstruction as? StudioInstruction,
              let screen = request.sourceFrame(byTrackID: instruction.screenTrackID)
        else { throw RenderError.readerFailed("no screen frame at \(seconds) s") }
        guard let output = request.renderContext.newPixelBuffer() else {
            throw RenderError.writerFailed("AVFoundation had no frame buffer to render \(seconds) s into")
        }
        let camera = instruction.cameraTrackID.flatMap { request.sourceFrame(byTrackID: $0) }
        let located = instruction.timeline.locate(seconds)
        let frame = instruction.renderer.frame(
            screen: CIImage(cvPixelBuffer: screen),
            camera: camera.map { CIImage(cvPixelBuffer: $0) },
            part: located.part,
            hostTime: located.hostTime
        )
        CVBufferSetAttachments(output, Self.bt709, .shouldPropagate)
        let destination = CIRenderDestination(pixelBuffer: output)
        destination.colorSpace = outputColorSpace
        try context.startTask(toRender: frame, to: destination).waitUntilCompleted()
        return output
    }
}
