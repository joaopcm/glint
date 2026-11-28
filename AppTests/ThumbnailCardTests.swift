import AppKit
import CoreGraphics
import LunettaCapture
import LunettaCore
import LunettaUI
import Synchronization
import Testing
@testable import Lunetta

@MainActor @Test func closeButtonGlassIsACircleAndTheActionBarACapsule() {
    let close = Glass.toolbar([iconButton()])
    let bar = Glass.toolbar((0..<5).map { _ in iconButton() })
    close.layoutSubtreeIfNeeded()
    bar.layoutSubtreeIfNeeded()

    #expect(close.fittingSize == CGSize(width: 32, height: 32))
    #expect(bar.fittingSize.height == 32)
    #expect(bar.fittingSize.width > 32)
}

@MainActor private func iconButton() -> NSButton {
    let button = NSButton()
    button.imagePosition = .imageOnly
    return button
}

@MainActor @Test func marginIsTwentyFourPoints() {
    #expect(ThumbnailPresenter.margin == 24)
}

@Test func cropEvensOutTheMeasuredWindowShadow() {
    // 400x332 pt window on a 2x display: 46 px of shadow left and right, 32 px above, 60 px below (#91).
    let size = CGSize(width: 892, height: 756)
    let window = CGRect(x: 46, y: 32, width: 800, height: 664)

    let crop = ThumbnailCentering.evenPaddingCrop(size: size, opaque: window)

    #expect(crop == CGRect(x: 0, y: 0, width: 892, height: 728))
    #expect(window.minY - crop.minY == crop.maxY - window.maxY)
}

@Test func centeringFindsTheWindowInsideItsShadowAndLeavesOpaqueImagesAlone() throws {
    let shadowed = try image(width: 120, height: 100, opaque: CGRect(x: 10, y: 6, width: 100, height: 80))
    #expect(ThumbnailCentering.opaqueBounds(of: shadowed) == CGRect(x: 10, y: 14, width: 100, height: 80))

    let centered = ThumbnailCentering.centered(shadowed)
    #expect(centered.width == 120 && centered.height == 92)

    let screen = try image(width: 160, height: 90, opaque: CGRect(x: 0, y: 0, width: 160, height: 90))
    #expect(ThumbnailCentering.centered(screen).height == 90)
}

func image(width: Int, height: Int, opaque: CGRect) throws -> CGImage {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.4))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(opaque)
    return try #require(context.makeImage())
}

@Test func clickingARecordingOpensItAndClickingAScreenshotAnnotatesIt() {
    #expect(ThumbnailView.clickAction(isStacked: false, isVideo: true) == .open)
    #expect(ThumbnailView.clickAction(isStacked: false, isVideo: false) == .annotate)
    #expect(ThumbnailView.clickAction(isStacked: true, isVideo: true) == .expand)
    #expect(ThumbnailView.clickAction(isStacked: true, isVideo: false) == .expand)
}

@MainActor @Test func cardsLeaveThroughTheEdgeOfTheirOwnHalf() {
    let screen = CGRect(x: 0, y: 0, width: 3008, height: 1692)
    let right = ThumbnailPresenter.frame(at: 0, in: screen, corner: .bottomRight, collapsed: false, width: 240)!
    let left = ThumbnailPresenter.frame(at: 0, in: screen, corner: .bottomLeft, collapsed: false, width: 240)!

    #expect(ThumbnailPresenter.edge(of: right, on: screen) == .right)
    #expect(ThumbnailPresenter.edge(of: left, on: screen) == .left)
    #expect(ThumbnailPresenter.offscreen(right, toward: .right, of: screen) == CGRect(x: 3008, y: right.minY, width: 240, height: 160))
    #expect(ThumbnailPresenter.offscreen(left, toward: .left, of: screen) == CGRect(x: -240, y: left.minY, width: 240, height: 160))
}

@MainActor @Test func offscreenRespectsADisplayThatDoesNotStartAtZero() {
    let secondDisplay = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let card = CGRect(x: -1900, y: 24, width: 240, height: 160)

    #expect(ThumbnailPresenter.edge(of: card, on: secondDisplay) == .left)
    #expect(ThumbnailPresenter.offscreen(card, toward: .left, of: secondDisplay).maxX == -1920)
}

@MainActor @Test func swipeLeavesTheWayTheFingersMoved() {
    #expect(ThumbnailPresenter.swipeEdge(scrollDelta: 80, naturalScrolling: true) == .right)
    #expect(ThumbnailPresenter.swipeEdge(scrollDelta: -80, naturalScrolling: true) == .left)
    #expect(ThumbnailPresenter.swipeEdge(scrollDelta: 80, naturalScrolling: false) == .left)
    #expect(ThumbnailPresenter.swipeEdge(scrollDelta: -80, naturalScrolling: false) == .right)
}

private struct DiskFull: LocalizedError {
    var errorDescription: String? { "The disk is full." }
}

private final class FailureBox: Sendable {
    let value = Mutex<(any Error)?>(nil)
}

/// Renders that run until a test lets them end, so a card can be looked at mid-render.
@MainActor final class RenderingCardFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "LunettaCardRender-\(UUID().uuidString)")
    let settings = LunettaSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
    let store: ProjectStore
    let pasteboard = NSPasteboard.withUniqueName()
    var progress = 0.0
    var failure: (any Error)?
    private let compressionError = FailureBox()
    var compressionFailure: (any Error)? {
        get { compressionError.value.withLock { $0 } }
        set { compressionError.value.withLock { $0 = newValue } }
    }
    var renders = 0
    var problems: [String] = []
    private let renderGate = AsyncStream<Void>.makeStream()
    private let compressionGate = AsyncStream<Void>.makeStream()
    private var queue: RenderQueue!

    init() {
        store = ProjectStore(root: root.appending(path: "Projects"))
        let renderGate = renderGate, compressionGate = compressionGate, compressionError = compressionError
        queue = RenderQueue(
            store: store,
            settings: settings,
            render: { [weak self] _, report in
                guard let self else { return }
                renders += 1
                report(progress)
                for await _ in renderGate.stream { break }
                if let failure {
                    self.failure = nil
                    throw failure
                }
            },
            compress: { _ in
                for await _ in compressionGate.stream { break }
                if let failure = compressionError.value.withLock({ $0 }) { throw failure }
                return CompressionResult(originalBytes: 1000, compressedBytes: 380)
            }
        )
    }

    var file: URL { root.appending(path: "saved/Recording.mp4") }

    func presenter(autoDismissDelay: Duration = .seconds(6)) -> ThumbnailPresenter {
        ThumbnailPresenter(
            settings: settings,
            upload: noUpload,
            onUploaded: { _ in },
            autoDismissDelay: autoDismissDelay,
            pointerLocation: { offScreen },
            pasteboard: pasteboard,
            reportProblem: { [weak self] title, message in self?.problems.append("\(title): \(message)") }
        )
    }

    func presenter(upload: @escaping @MainActor (URL, UploadedCapture?) async throws -> UploadedCapture) -> ThumbnailPresenter {
        ThumbnailPresenter(settings: settings, upload: upload, onUploaded: { _ in }, pointerLocation: { offScreen }, pasteboard: pasteboard)
    }

    func record() throws -> RenderJob {
        let project = RecordingProject(
            id: UUID(),
            createdAt: Date(),
            mode: .area,
            region: CGRect(x: 0, y: 0, width: 64, height: 48),
            windowID: nil,
            parts: [ProjectPart(screen: "part-1.screen.mp4", camera: nil, events: "part-1.events.jsonl", screenStartHostTime: 1000, cameraStartHostTime: nil)],
            overlays: ProjectOverlays(clicks: false, keys: false, camera: false, clickColorHex: "#FF0000", cameraMirrored: false),
            output: ProjectOutput(file: file, codec: .h264, frameRate: .thirty, capsToUHD: true)
        )
        try store.create(project)
        return queue.enqueue(project)
    }

    func closeCard(of presenter: ThumbnailPresenter) async throws {
        presenter.perform(.close, onCardAt: 0)
        try await Task.sleep(for: .seconds(ThumbnailPresenter.exitDuration) + .milliseconds(300))
    }

    func finishRender() { renderGate.continuation.yield() }
    func finishCompression() { compressionGate.continuation.yield() }

    func firstFrame() throws -> CGImage {
        try image(width: 48, height: 32, opaque: CGRect(x: 0, y: 0, width: 48, height: 32))
    }

    func remove() {
        for _ in 0..<2 {
            renderGate.continuation.yield()
            compressionGate.continuation.yield()
        }
        renderGate.continuation.finish()
        compressionGate.continuation.finish()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor @Test func aRenderingCardSaysSoWithItsProgress() async throws {
    let fixture = RenderingCardFixture()
    defer { fixture.remove() }
    fixture.progress = 0.42
    let presenter = fixture.presenter()

    presenter.show(fixture.file, precomputedThumbnail: try fixture.firstFrame(), render: try fixture.record())
    try await Task.sleep(for: .milliseconds(200))

    #expect(presenter.count == 1)
    #expect(presenter.statusTexts == ["Rendering 42%"])
}

@MainActor @Test func copyWaitsForTheRenderThenRuns() async throws {
    let fixture = RenderingCardFixture()
    defer { fixture.remove() }
    let presenter = fixture.presenter()
    let job = try fixture.record()
    presenter.show(fixture.file, precomputedThumbnail: try fixture.firstFrame(), render: job)

    presenter.perform(.copy, onCardAt: 0)
    try await Task.sleep(for: .milliseconds(100))
    #expect(presenter.count == 1)
    #expect(fixture.pasteboard.pasteboardItems?.isEmpty ?? true)

    try FileManager.default.createDirectory(at: fixture.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: fixture.file)
    fixture.finishRender()
    await job.finished()
    try await Task.sleep(for: .milliseconds(100))

    #expect(presenter.count == 0)
    let copied = fixture.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
    #expect(copied == [fixture.file])
}

@MainActor @Test func closingARenderingCardLeavesTheRenderRunning() async throws {
    let fixture = RenderingCardFixture()
    defer { fixture.remove() }
    let presenter = fixture.presenter()
    let job = try fixture.record()
    presenter.show(fixture.file, precomputedThumbnail: try fixture.firstFrame(), render: job)

    presenter.perform(.close, onCardAt: 0)
    #expect(presenter.count == 0)
    fixture.finishRender()
    await job.finished()

    #expect(job.phase == .done(nil))
    #expect(fixture.renders == 1)
    #expect(fixture.problems.isEmpty)
}

@MainActor @Test func aFailedRenderShowsWhyAndTryAgainRetries() async throws {
    let fixture = RenderingCardFixture()
    defer { fixture.remove() }
    fixture.failure = DiskFull()
    let presenter = fixture.presenter()
    let job = try fixture.record()
    presenter.show(fixture.file, precomputedThumbnail: try fixture.firstFrame(), render: job)

    fixture.finishRender()
    await job.finished()
    try await Task.sleep(for: .milliseconds(100))
    #expect(presenter.statusTexts == ["Couldn't render"])
    #expect(fixture.problems == ["Lunetta couldn't render the recording: The disk is full."])

    presenter.perform(.copy, onCardAt: 0)
    #expect(presenter.count == 1)
    #expect(fixture.pasteboard.pasteboardItems?.isEmpty ?? true)

    presenter.perform(.retryRender, onCardAt: 0)
    try await Task.sleep(for: .milliseconds(100))
    #expect(presenter.statusTexts == ["Rendering 0%"])
    fixture.finishRender()
    await job.finished()

    #expect(job.phase == .done(nil))
    #expect(fixture.renders == 2)
    #expect(fixture.problems.count == 1)
}

@MainActor @Test func compressionAfterTheRenderShowsCompressingThenTheSummary() async throws {
    let fixture = RenderingCardFixture()
    defer { fixture.remove() }
    fixture.settings.compressAfterCapture = true
    let presenter = fixture.presenter()
    let job = try fixture.record()
    presenter.show(fixture.file, precomputedThumbnail: try fixture.firstFrame(), render: job)

    fixture.finishRender()
    try await Task.sleep(for: .milliseconds(200))
    #expect(presenter.statusTexts == ["Compressing"])

    fixture.finishCompression()
    await job.finished()
    try await Task.sleep(for: .milliseconds(100))
    #expect(presenter.statusTexts == ["62% smaller"])
}

@MainActor @Test func aRenderingCardHoldsAutoHideUntilTheRenderFinishes() async throws {
    let fixture = RenderingCardFixture()
    defer { fixture.remove() }
    fixture.settings.overlayAutoDismiss = true
    let presenter = fixture.presenter(autoDismissDelay: .milliseconds(100))
    let job = try fixture.record()
    presenter.show(fixture.file, precomputedThumbnail: try fixture.firstFrame(), render: job)

    try await Task.sleep(for: .milliseconds(400))
    #expect(presenter.count == 1)

    fixture.finishRender()
    await job.finished()
    try await Task.sleep(for: .milliseconds(400))
    #expect(presenter.count == 0)
}

@MainActor @Test func retryRenderIsNotAnActionThatReadsTheFile() {
    #expect(!ThumbnailView.Action.retryRender.readsTheFile)
}

@MainActor @Test func aRenderThatFailsAfterItsCardClosedStillSaysWhy() async throws {
    let fixture = RenderingCardFixture()
    defer { fixture.remove() }
    fixture.failure = DiskFull()
    let presenter = fixture.presenter()
    let job = try fixture.record()
    presenter.show(fixture.file, precomputedThumbnail: try fixture.firstFrame(), render: job)

    try await fixture.closeCard(of: presenter)
    fixture.finishRender()
    await job.finished()
    try await Task.sleep(for: .milliseconds(100))

    #expect(fixture.problems == ["Lunetta couldn't render the recording: The disk is full."])
}

@MainActor @Test func aCompressionFailureAfterTheRenderShowsItAndOffersNoTryAgain() async throws {
    let fixture = RenderingCardFixture()
    defer { fixture.remove() }
    fixture.settings.compressAfterCapture = true
    fixture.compressionFailure = DiskFull()
    let presenter = fixture.presenter()
    let job = try fixture.record()
    presenter.show(fixture.file, precomputedThumbnail: try fixture.firstFrame(), render: job)

    fixture.finishRender()
    try await Task.sleep(for: .milliseconds(100))
    fixture.finishCompression()
    await job.finished()
    try await Task.sleep(for: .milliseconds(400))

    #expect(job.phase == .done(nil))
    #expect(fixture.problems == ["Lunetta couldn't compress the capture: The disk is full."])
    #expect(presenter.statusTexts == [nil])
    presenter.perform(.retryRender, onCardAt: 0)
    #expect(fixture.renders == 1)
}

@MainActor @Test func tallCardShowsHeightBadge() throws {
    let thumbnail = try image(width: 300, height: 200, opaque: CGRect(x: 0, y: 0, width: 300, height: 200))
    let url = URL(fileURLWithPath: "/tmp/capture.png")

    let tall = ThumbnailView(url: url, thumbnail: thumbnail, isVideo: false, fullPixelSize: CGSize(width: 1600, height: 12480))
    let badge = try #require(heightBadge(in: tall))
    #expect(badge.stringValue == "↕ \(12_480.formatted()) px")
    #expect(!badge.isHiddenOrHasHiddenAncestor)

    let normal = ThumbnailView(url: url, thumbnail: thumbnail, isVideo: false, fullPixelSize: CGSize(width: 1600, height: 1000))
    #expect(heightBadge(in: normal).map(\.isHiddenOrHasHiddenAncestor) ?? true)
}

@MainActor private func heightBadge(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.accessibilityIdentifier() == AccessibilityID.cardHeightBadge { return field }
    return view.subviews.lazy.compactMap { heightBadge(in: $0) }.first
}

@MainActor @Test func phoneScreenshotKeepsTodaysThumbnail() throws {
    let phone = try image(width: 1179, height: 2556, opaque: CGRect(x: 0, y: 0, width: 1179, height: 2556))

    let thumbnail = ThumbnailDownsampler.downsample(phone, maxPixelSize: 960)
    #expect(thumbnail.width == Int((1179.0 * 960 / 2556).rounded()) && thumbnail.height == 960)

    let card = ThumbnailView(
        url: URL(fileURLWithPath: "/tmp/phone.png"), thumbnail: thumbnail, isVideo: false, fullPixelSize: CGSize(width: 1179, height: 2556)
    )
    #expect(heightBadge(in: card).map(\.isHiddenOrHasHiddenAncestor) ?? true)
}
