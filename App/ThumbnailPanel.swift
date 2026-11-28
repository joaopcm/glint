import AppKit
import AVFoundation
import LunettaCapture
import LunettaCore
import LunettaEditor
import LunettaUI
import ImageIO
import os
import QuartzCore
import UniformTypeIdentifiers

/// Quick-access overlay.
@MainActor
final class ThumbnailPresenter {
    static func size(width: CGFloat) -> CGSize {
        CGSize(width: width, height: (width * 2 / 3).rounded())
    }
    static let margin: CGFloat = 24
    static let spacing: CGFloat = 10

    enum Edge { case left, right }
    static let enterDuration: TimeInterval = OverlayStyle.enterDuration
    static let exitDuration: TimeInterval = OverlayStyle.exitDuration
    static let easeOut = CAMediaTimingFunction(
        controlPoints: Float(OverlayStyle.easeOutControlPoints.0),
        Float(OverlayStyle.easeOutControlPoints.1),
        Float(OverlayStyle.easeOutControlPoints.2),
        Float(OverlayStyle.easeOutControlPoints.3)
    )

    /// The side of the screen a card belongs to: it comes in from that edge and leaves through it.
    static func edge(of frame: CGRect, on screen: CGRect) -> Edge {
        frame.midX < screen.midX ? .left : .right
    }

    /// The way the fingers moved: natural scrolling reports the fingers' direction, classic scrolling the opposite.
    static func swipeEdge(scrollDelta: CGFloat, naturalScrolling: Bool) -> Edge {
        (scrollDelta > 0) == naturalScrolling ? .right : .left
    }

    /// `frame` moved sideways until it is just past `screen`'s edge.
    static func offscreen(_ frame: CGRect, toward edge: Edge, of screen: CGRect) -> CGRect {
        frame.offsetBy(dx: edge == .right ? screen.maxX - frame.minX : screen.minX - frame.maxX, dy: 0)
    }

    private let settings: LunettaSettings
    private var items: [ThumbnailItem] = [] // newest first
    private var pinned: [NSPanel] = []
    private var editors: [URL: AnnotationEditor] = [:]
    private var expansion = PileExpansion<NSScreen>()
    private var collapseTasks: [NSScreen: Task<Void, Never>] = [:]
    /// One countdown for the whole overlay: each new capture restarts it, so a pile being built never
    /// starts disappearing; when it fires every thumbnail goes together.
    private var autoDismissTask: Task<Void, Never>?
    private let autoDismissDelay: Duration
    private var isDraggingOut = false
    private var isRunningModal = false
    private let pointerLocation: @MainActor () -> CGPoint
    private let uploadFile: @MainActor (URL, _ replacing: UploadedCapture?) async throws -> UploadedCapture
    private let onUploaded: @MainActor (UploadedCapture) -> Void
    private let pasteboard: NSPasteboard
    private let reportProblem: (@MainActor (_ title: String, _ message: String) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var liveWidth: CGFloat?
    private var resizeStartWidth: CGFloat?
    private var width: CGFloat { liveWidth ?? CGFloat(settings.thumbnailWidth) }

    // ponytail: fixed 6 s when auto-hide is on; make the delay a setting if someone asks.
    init(
        settings: LunettaSettings,
        upload: @escaping @MainActor (URL, _ replacing: UploadedCapture?) async throws -> UploadedCapture,
        onUploaded: @escaping @MainActor (UploadedCapture) -> Void,
        autoDismissDelay: Duration = .seconds(6),
        pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
        pasteboard: NSPasteboard = .general,
        reportProblem: (@MainActor (_ title: String, _ message: String) -> Void)? = nil
    ) {
        self.settings = settings
        self.pasteboard = pasteboard
        self.reportProblem = reportProblem
        uploadFile = upload
        self.onUploaded = onUploaded
        self.autoDismissDelay = autoDismissDelay
        self.pointerLocation = pointerLocation
        BackgroundCursor.enable()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanged() }
            },
        ]
        relayoutOnLayoutSettingsChange()
    }

    /// Corner, width and auto-hide changes in Settings apply to thumbnails already on screen.
    /// `onChange` fires once, from the setter, before the new value is stored: hop to the main actor to read it, then watch again.
    private func relayoutOnLayoutSettingsChange() {
        withObservationTracking {
            _ = settings.overlayCorner
            _ = settings.thumbnailWidth
            _ = settings.overlayAutoDismiss
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.layout()
                self?.relayoutOnLayoutSettingsChange()
            }
        }
    }

    func show(_ url: URL) {
        show(url, precomputedThumbnail: nil)
    }

    /// `isCapture` false is for files Lunetta didn't capture, like a copied image it compressed: upload after capture
    /// leaves those alone.
    func show(_ url: URL, precomputedThumbnail: CGImage?, compression: PendingCompression? = nil, isCapture: Bool = true) {
        show(url, precomputedThumbnail: precomputedThumbnail, pending: compression.map(PendingFile.compression), isCapture: isCapture)
    }

    /// The card appears now, with `render`'s progress on it; `url` is where the video lands, so a card with no
    /// precomputed thumbnail has nothing to show until the render is done.
    func show(_ url: URL, precomputedThumbnail: CGImage?, render: RenderJob) {
        show(url, precomputedThumbnail: precomputedThumbnail, pending: .render(render), isCapture: true)
    }

    private func show(_ url: URL, precomputedThumbnail: CGImage?, pending: PendingFile?, isCapture: Bool) {
        let screen = NSScreen.screens.first { $0.frame.contains(pointerLocation()) } ?? NSScreen.main
        guard let screen else { return }
        if let precomputedThumbnail {
            let scaled = ThumbnailDownsampler.downsample(precomputedThumbnail, maxPixelSize: ThumbnailItem.maxPixelSize(on: screen))
            return show(url, thumbnail: scaled, on: screen, pending: pending, isCapture: isCapture)
        }
        guard ThumbnailItem.isVideo(url) else {
            guard let thumbnail = ThumbnailItem.thumbnail(of: url, on: screen) else { return }
            return show(url, thumbnail: thumbnail, on: screen, pending: pending, isCapture: isCapture)
        }
        Task {
            do {
                if case let .render(job) = pending {
                    await job.finished()
                    if case let .failed(reason) = job.phase {
                        return showError("Lunetta couldn't render the recording", message: reason)
                    }
                }
                show(url, thumbnail: try await ThumbnailItem.videoThumbnail(of: url, on: screen), on: screen, pending: pending, isCapture: isCapture)
            } catch {
                Logger(subsystem: "com.joaopcm.lunetta", category: "thumbnail")
                    .error("no thumbnail for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func show(_ url: URL, thumbnail: CGImage, on screen: NSScreen, pending: PendingFile?, isCapture: Bool) {
        let item = ThumbnailItem(url: url, screen: screen, thumbnail: thumbnail)
        item.view.onAction = { [weak self, weak item] action in
            guard let self, let item else { return }
            self.handle(action, for: item)
        }
        item.view.onPointerChange = { [weak self] in self?.refreshHover() }
        item.view.onResize = { [weak self] change in self?.resize(change) }
        item.view.onDragOut = { [weak self] inProgress in self?.setDraggingOut(inProgress) }
        item.view.onSwipeAway = { [weak self, weak item] edge in
            guard let self, let item else { return }
            self.remove(item, leaving: edge)
            self.layout()
        }
        items.insert(item, at: 0)
        expansion.collapse(on: screen)
        cancelAutoDismiss() // still stacking: restart the countdown (layout() schedules it again)
        layout()
        switch pending {
        case let .compression(compression):
            finish(compression, for: item, isCapture: isCapture)
        case let .render(job):
            item.render = job
            follow(job, on: item)
        case nil:
            guard isCapture, settings.uploadAfterCapture else { break }
            upload(item, closingCard: false)
        }
    }

    /// The card says it's compressing until the file is final. Actions that read the file wait for it, and so does
    /// upload after capture.
    private func finish(_ compression: PendingCompression, for item: ThumbnailItem, isCapture: Bool) {
        item.status = .working("Compressing")
        refreshHover()
        Task {
            let outcome = await compression.result
            item.status = .idle
            switch outcome {
            case .success(let result):
                item.view.showCompressed(result)
            case .failure(let error):
                showError("Lunetta couldn't compress the capture", error)
            }
            releaseWaitingActions(of: item, isCapture: isCapture)
        }
    }

    /// The card follows the render until the file is final, the same way it follows compression. A failed render
    /// stops here and waits for Try Again; closing the card leaves the render running, and its end still reports.
    private func follow(_ job: RenderJob, on item: ThumbnailItem) {
        switch job.phase {
        case .queued:
            item.status = .working("Rendering")
            item.view.isFileReady = false
        case let .rendering(fraction):
            item.status = .working("Rendering \(Int((fraction * 100).rounded()))%")
            item.view.isFileReady = false
        case .compressing:
            item.sawCompression = true
            item.status = .working("Compressing")
            item.view.isFileReady = true
        case let .done(result):
            item.status = .idle
            item.view.isFileReady = true
            if let failure = job.compressionFailure {
                showError("Lunetta couldn't compress the capture", message: failure)
            } else if item.sawCompression {
                item.view.showCompressed(result)
            }
            return releaseWaitingActions(of: item, isCapture: true)
        case let .failed(reason):
            item.status = .failed("Couldn't render")
            item.view.isFileReady = false
            item.actionsWhenFileIsReady = []
            refreshHover()
            return showError("Lunetta couldn't render the recording", message: reason)
        }
        refreshHover()
        withObservationTracking {
            _ = job.phase
        } onChange: { [weak self, weak item] in
            Task { @MainActor in
                guard let self, let item else { return }
                self.follow(job, on: item)
            }
        }
    }

    private func releaseWaitingActions(of item: ThumbnailItem, isCapture: Bool) {
        if isCapture, settings.uploadAfterCapture { upload(item, closingCard: false) }
        let waiting = item.actionsWhenFileIsReady
        item.actionsWhenFileIsReady = []
        if items.contains(where: { $0 === item }) {
            waiting.forEach { handle($0, for: item) }
        }
        refreshHover()
    }

    static func columnCapacity(in visible: CGRect, width: CGFloat) -> Int {
        max(1, Int((visible.height - margin) / (size(width: width).height + spacing)))
    }

    /// Frame of the thumbnail at `index` (0 = newest). Expanded: a column growing up from the corner.
    /// Collapsed: one card in the corner with the next two peeking out above it; nil = hidden.
    static func frame(at index: Int, in visible: CGRect, corner: OverlayCorner, collapsed: Bool, width: CGFloat) -> CGRect? {
        let size = size(width: width)
        let x = corner == .bottomLeft ? visible.minX + margin : visible.maxX - margin - size.width
        let base = CGRect(origin: CGPoint(x: x, y: visible.minY + margin), size: size)
        guard collapsed else {
            return base.offsetBy(dx: 0, dy: CGFloat(index) * (size.height + spacing))
        }
        guard index < 3 else { return nil }
        let depth = CGFloat(index)
        return base.insetBy(dx: 10 * depth, dy: 0).offsetBy(dx: 0, dy: ThumbnailPile.offset * depth)
    }

    // ponytail: drops the oldest once the expanded column would overflow the screen, on every layout, so a
    // new capture, a resize, a Settings change and a smaller display all follow the same rule.
    private func layout() {
        var groups: [NSScreen: [ThumbnailItem]] = [:]
        for item in items { groups[item.screen, default: []].append(item) }
        for (screen, group) in groups {
            let capacity = Self.columnCapacity(in: screen.visibleFrame, width: width)
            if group.count > capacity {
                group.dropFirst(capacity).forEach { remove($0) }
                groups[screen] = Array(group.prefix(capacity))
            }
        }
        guard !items.isEmpty else { return }
        let corner = settings.overlayCorner

        for (screen, group) in groups where !group.isEmpty {
            let collapsed = !expansion.isExpanded(on: screen) && group.count > 1
            var needsOrderFront = liveWidth == nil
            for (index, item) in group.enumerated() {
                item.view.stackCount = collapsed && index == 0 ? group.count : nil
                item.view.isStacked = collapsed
                item.view.corner = corner
                item.targetFrame = Self.frame(at: index, in: screen.visibleFrame, corner: corner, collapsed: collapsed, width: width)
                guard let frame = item.targetFrame else {
                    item.panel.orderOut(nil)
                    continue
                }
                if !item.panel.isVisible { needsOrderFront = true }
                if !item.hasEntered {
                    item.hasEntered = true
                    if liveWidth == nil {
                        enter(item, at: frame, on: screen.frame)
                        continue
                    }
                }
                if item.panel.isVisible, liveWidth == nil {
                    item.panel.animator().setFrame(frame, display: true)
                } else {
                    item.panel.setFrame(frame, display: item.panel.isVisible) // follow resize gestures without lag
                }
            }
            if needsOrderFront {
                // Newest on top: order back to front.
                for item in group.reversed() where item.targetFrame != nil {
                    item.panel.orderFrontRegardless()
                }
            }
        }
        refreshHover()
    }

    /// Hover is derived from the pointer position, not cached from enter/exit events: panels that move,
    /// resize or hide under a still pointer never get an exit event.
    private func refreshHover() {
        let pointer = pointerLocation()
        // Newest first and ordered on top, so the first hit is the card the pointer is actually over.
        let hovered = items.first { $0.targetFrame?.contains(pointer) == true }
        for item in items { item.view.isHovered = item === hovered }
        scheduleFolding(pointerOver: hovered?.screen)

        // Hovering any thumbnail, dragging one out, a modal panel (Save As), an open editor, a running compression or upload pauses auto-hide for the whole overlay.
        if hovered != nil || isDraggingOut || isRunningModal || !editors.isEmpty || items.contains(where: { $0.isWorking || $0.hasFailed || $0.isUploading }) {
            cancelAutoDismiss()
            return
        }
        if !settings.overlayAutoDismiss || items.isEmpty {
            cancelAutoDismiss()
        } else if autoDismissTask == nil {
            let delay = autoDismissDelay
            autoDismissTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.settings.overlayAutoDismiss else { return }
                self.autoDismissTask = nil
                self.items.forEach { self.remove($0) }
            }
        }
    }

    private func scheduleFolding(pointerOver hovered: NSScreen?) {
        let folding = expansion.pilesToFold(pointerOver: hovered)
        for screen in collapseTasks.keys where !folding.contains(screen) {
            collapseTasks.removeValue(forKey: screen)?.cancel()
        }
        for screen in folding where collapseTasks[screen] == nil {
            collapseTasks[screen] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1)) // crossing the 10 pt gap between cards takes well under 1 s
                guard !Task.isCancelled, let self else { return }
                self.collapseTasks[screen] = nil
                self.expansion.collapse(on: screen)
                self.layout()
            }
        }
    }

    /// Drag a card's top or inner edge (the resize cursor shows there), or pinch any card: resizes every thumbnail; the width is saved when the gesture ends.
    private func resize(_ change: ThumbnailView.Resize) {
        let start = resizeStartWidth ?? width
        resizeStartWidth = start
        let proposed: CGFloat
        let ended: Bool
        switch change {
        case .drag(let translation, let done):
            proposed = Self.resizedWidth(start: start, translation: translation, corner: settings.overlayCorner)
            ended = done
        case .magnify(let magnification, let done):
            proposed = width * (1 + magnification)
            ended = done
        }
        liveWidth = CGFloat(LunettaSettings.clampWidth(Double(proposed)))
        layout()
        guard ended else { return }
        settings.thumbnailWidth = Double(width)
        liveWidth = nil
        resizeStartWidth = nil
    }

    /// Growing = moving away from the corner: up, and toward the middle of the screen. The axis that moved
    /// most wins, so a dragged edge stays under the pointer.
    static func resizedWidth(start: CGFloat, translation: CGSize, corner: OverlayCorner) -> CGFloat {
        let horizontal = corner == .bottomRight ? -translation.width : translation.width
        let vertical = translation.height * 1.5 // height is 2/3 of the width
        return start + (abs(horizontal) > abs(vertical) ? horizontal : vertical)
    }

    func setDraggingOut(_ inProgress: Bool) {
        isDraggingOut = inProgress
        refreshHover()
    }

    private func cancelAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
    }

    /// Thumbnails currently in the overlay (for tests).
    var count: Int { items.count }

    /// Each card's status capsule text, newest first; nil while it shows none.
    var statusTexts: [String?] { items.map(\.view.statusText) }

    func perform(_ action: ThumbnailView.Action, onCardAt index: Int) {
        handle(action, for: items[index])
    }
    var urls: [URL] { items.map(\.url) }
    var frames: [CGRect?] { items.map(\.targetFrame) }

    private func screensChanged() {
        let screens = NSScreen.screens
        guard let fallback = NSScreen.main ?? screens.first else { return }
        // AppKit may hand back new NSScreen objects after a reconfiguration; match by display ID.
        for item in items {
            item.screen = screens.first { $0.displayID == item.screen.displayID } ?? fallback
        }
        layout()
    }

    private func handle(_ action: ThumbnailView.Action, for item: ThumbnailItem) {
        if item.hasFailed, action.readsTheFile { return }
        if item.isWorking, action.readsTheFile {
            item.actionsWhenFileIsReady.append(action)
            return
        }
        switch action {
        case .copy:
            do {
                if ThumbnailItem.isVideo(item.url) {
                    try pasteboard.copyFileReference(item.url)
                } else {
                    try pasteboard.copyPNGFile(at: item.url)
                }
                remove(item)
            } catch {
                showError("Lunetta couldn't copy the screenshot", error)
            }
        case .retryRender:
            guard let job = item.render else { break }
            job.retry()
            follow(job, on: item)
        case .upload:
            upload(item, closingCard: true)
        case .saveAs:
            saveAs(item)
        case .annotate:
            annotate(item)
        case .pin:
            remove(item, animated: false) // the pinned window takes its place
            pin(item.url, on: item.screen)
        case .close:
            remove(item)
        case .dropped:
            remove(item, animated: false) // the file went with the pointer
        case .expand:
            expansion.expand(on: item.screen)
        case .open:
            open(item)
        }
        layout()
    }

    private func enter(_ item: ThumbnailItem, at frame: CGRect, on screen: CGRect) {
        let start = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? frame : Self.offscreen(frame, toward: Self.edge(of: frame, on: screen), of: screen)
        item.panel.setFrame(start, display: false)
        item.panel.alphaValue = 0
        item.panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.enterDuration
            context.timingFunction = Self.easeOut
            item.panel.animator().setFrame(frame, display: true)
            item.panel.animator().alphaValue = 1
        }
    }

    /// Slides the card out through `edge` (default: its own side of the screen) while it fades; with Reduce Motion it only fades.
    private func remove(_ item: ThumbnailItem, leaving edge: Edge? = nil, animated: Bool = true) {
        items.removeAll { $0 === item }
        guard animated, item.panel.isVisible, let frame = item.targetFrame else {
            item.panel.orderOut(nil)
            // Actions arrive from inside the panel's own event handling; free it on the next turn.
            DispatchQueue.main.async { withExtendedLifetime(item) {} }
            return
        }
        let screen = item.screen.frame
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        item.panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.exitDuration
            context.timingFunction = Self.easeOut
            if !reduceMotion {
                item.panel.animator().setFrame(Self.offscreen(frame, toward: edge ?? Self.edge(of: frame, on: screen), of: screen), display: true)
            }
            item.panel.animator().alphaValue = 0
        } completionHandler: {
            item.panel.orderOut(nil)
        }
    }

    private func upload(_ item: ThumbnailItem, closingCard: Bool) {
        guard !item.isUploading else { return }
        item.isUploading = true
        refreshHover()
        Task {
            do {
                let uploaded = try await uploadFile(item.url, item.uploaded)
                item.uploaded = uploaded
                item.isUploading = false
                if closingCard { remove(item) }
                layout()
                onUploaded(uploaded)
                if item.uploadAgainWhenDone {
                    item.uploadAgainWhenDone = false
                    upload(item, closingCard: false)
                }
            } catch {
                item.isUploading = false
                item.uploadAgainWhenDone = false
                showError("Lunetta couldn't upload the screenshot", error)
            }
            refreshHover()
        }
    }

    /// An uploaded capture's link is already out, so saving annotations puts the new bytes behind that same link.
    func annotationsSaved(to url: URL, _ image: CGImage) {
        guard let item = items.first(where: { $0.url == url }) else { return }
        item.reloadThumbnail(from: image)
        if item.isUploading {
            item.uploadAgainWhenDone = true
        } else if item.uploaded != nil {
            upload(item, closingCard: false)
        }
    }

    private func saveAs(_ item: ThumbnailItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.url.lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: item.url.pathExtension) ?? .png]
        panel.directoryURL = settings.saveFolder
        guard runActivated({ panel.runModal() }) == .OK, let destination = panel.url else { return }
        guard destination.standardizedFileURL != item.url.standardizedFileURL else { return remove(item) }
        do {
            let files = FileManager.default
            if files.fileExists(atPath: destination.path) {
                // The save panel already confirmed the replace; swap atomically so a failure keeps the old file.
                let scratch = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
                let copy = scratch.appending(path: destination.lastPathComponent)
                try files.copyItem(at: item.url, to: copy)
                _ = try files.replaceItemAt(destination, withItemAt: copy)
            } else {
                try files.copyItem(at: item.url, to: destination)
            }
            remove(item)
        } catch {
            showError("Lunetta couldn't save the screenshot", error)
        }
    }

    private func open(_ item: ThumbnailItem) {
        NSWorkspace.shared.open(item.url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.showError("Lunetta couldn't open the recording", error) }
        }
    }

    private func annotate(_ item: ThumbnailItem) {
        let url = item.url
        if let open = editors[url] { return open.show(on: item.screen) }
        do {
            // The card keeps the objects and the unflattened capture, so reopening edits them again; dismissing the card drops them (#16).
            let document = try item.annotations ?? AnnotationDocument(base: CaptureEditor.image(at: url))
            item.annotations = document
            editors[url] = CaptureEditor.open(
                document,
                savingTo: url,
                on: item.screen,
                settings: settings,
                onSaved: { [weak self] savedImage in self?.annotationsSaved(to: url, savedImage) },
                onClose: { [weak self] in
                    self?.editors[url] = nil
                    self?.refreshHover()
                }
            )
        } catch {
            showError("Lunetta couldn't open the screenshot for annotation", error)
        }
    }

    private func pin(_ url: URL, on screen: NSScreen) {
        guard let image = NSImage(contentsOf: url) else { return }
        // NSImage from a PNG reports pixels as points; divide by the display scale for real size.
        let scale = screen.backingScaleFactor
        let pixelSize = image.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
        var size = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        let visible = screen.visibleFrame
        let fit = min(visible.width * 0.6 / size.width, visible.height * 0.6 / size.height, 1)
        size = CGSize(width: size.width * fit, height: size.height * fit)
        let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)

        let window = PinnedPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = url.lastPathComponent
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.contentAspectRatio = size
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        window.contentView = imageView
        window.onClose = { [weak self, weak window] in self?.pinned.removeAll { $0 === window } }
        window.orderFrontRegardless()
        pinned.append(window)
    }

    private func showError(_ title: String, _ error: any Error) {
        showError(title, message: error.localizedDescription)
    }

    private func showError(_ title: String, message: String) {
        if let reportProblem { return reportProblem(title, message) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        runActivated { _ = alert.runModal() }
    }

    private func runActivated<T>(_ body: () -> T) -> T {
        isRunningModal = true
        refreshHover()
        defer {
            isRunningModal = false
            refreshHover()
        }
        return runWithLunettaActive(body)
    }
}

private enum PendingFile {
    case compression(PendingCompression)
    case render(RenderJob)
}

@MainActor
private final class ThumbnailItem {
    let url: URL
    var screen: NSScreen
    let panel: NSPanel
    let view: ThumbnailView
    /// Where layout() put the panel (nil = hidden). Used for hover, since animated frames lag behind.
    var targetFrame: CGRect?
    var annotations: AnnotationDocument?
    var uploaded: UploadedCapture?
    /// Annotations saved while an upload was running; that upload may have read the file before them.
    var uploadAgainWhenDone = false
    var hasEntered = false
    var isUploading = false {
        didSet { view.isUploading = isUploading }
    }
    var status = ThumbnailView.Status.idle {
        didSet { view.status = status }
    }
    var render: RenderJob?
    var sawCompression = false
    /// Pressed while the file was being rendered or compressed; they run on the final file.
    var actionsWhenFileIsReady: [ThumbnailView.Action] = []

    var isWorking: Bool {
        if case .working = status { true } else { false }
    }

    var hasFailed: Bool {
        if case .failed = status { true } else { false }
    }

    static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }

    static func videoThumbnail(of url: URL, on screen: NSScreen) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let side = maxPixelSize(on: screen)
        generator.maximumSize = CGSize(width: side, height: side)
        return try await generator.image(at: .zero).image
    }

    init(url: URL, screen: NSScreen, thumbnail: CGImage) {
        self.url = url
        self.screen = screen
        view = ThumbnailView(url: url, thumbnail: thumbnail, isVideo: Self.isVideo(url))
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: ThumbnailPresenter.size(width: LunettaSettings.defaultThumbnailWidth)), // layout() sets the real frame
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        // NSPanel hides when its app deactivates by default; Save As / Settings activate Lunetta.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = view
    }

    func reloadThumbnail(from image: CGImage? = nil) {
        if let image {
            view.show(ThumbnailDownsampler.downsample(image, maxPixelSize: Self.maxPixelSize(on: screen)))
            return
        }
        guard let thumbnail = Self.thumbnail(of: url, on: screen) else { return }
        view.show(thumbnail)
    }

    // A downsampled copy: the full capture can be tens of MB and thumbnails stay until dismissed.
    // Sized for the widest card the user can pick, so it stays sharp after resizing.
    static func thumbnail(of url: URL, on screen: NSScreen) -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize(on: screen),
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    static func maxPixelSize(on screen: NSScreen) -> CGFloat {
        LunettaSettings.thumbnailWidthRange.upperBound * screen.backingScaleFactor
    }
}

final class ThumbnailView: NSView, NSDraggingSource {
    enum Action: Int {
        case copy, upload, saveAs, annotate, pin, close, expand, open, dropped, retryRender

        var readsTheFile: Bool {
            switch self {
            case .copy, .upload, .saveAs, .annotate, .pin, .open: true
            case .close, .expand, .dropped, .retryRender: false
            }
        }
    }

    enum Status: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    /// "62% smaller" once the file shrank; "Already small" when the compressed copy wasn't smaller and the original stays.
    static func compressionSummary(_ result: CompressionResult?) -> String {
        guard let result else { return "Already small" }
        return "\(max(1, Int((result.savedFraction * 100).rounded())))% smaller"
    }

    // "62% smaller" is 2 words, 0.5 s at the 238 wpm adult silent reading rate (Brysbaert 2019, doi:10.1016/j.jml.2019.104047);
    // the other second lets the eye come back to the card after the capture.
    static let compressionSummaryVisibleFor: Duration = .seconds(1.5)

    static func clickAction(isStacked: Bool, isVideo: Bool) -> Action {
        if isStacked { return .expand }
        return isVideo ? .open : .annotate
    }
    enum Resize {
        case drag(translation: CGSize, ended: Bool)
        case magnify(CGFloat, ended: Bool)
    }

    var onAction: ((Action) -> Void)?
    var onPointerChange: (() -> Void)?
    var onResize: ((Resize) -> Void)?
    var onDragOut: ((_ inProgress: Bool) -> Void)?
    var onSwipeAway: ((ThumbnailPresenter.Edge) -> Void)?

    private let url: URL
    private let isVideo: Bool
    private var thumbnail: NSImage
    private let imageView = NSView()
    private let controls = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private lazy var badge = Glass.capsule(holding: badgeLabel, tint: .controlAccentColor)
    private var uploadButton: NSButton?
    private let uploadSpinner = NSProgressIndicator()
    private let actionLabel = NSTextField(labelWithString: "")
    private lazy var actionLabelCapsule = Glass.capsule(holding: actionLabel)
    private var actionLabelCenter: NSLayoutConstraint?
    private lazy var uploadIndicator = Glass.capsule(holding: uploadSpinner, tint: .controlAccentColor)
    private let compressionSpinner = NSProgressIndicator()
    private let compressionDone = NSImageView()
    private let compressionLabel = NSTextField(labelWithString: "Compressing")
    private let renderRetry = NSButton(title: "Try Again", target: nil, action: nil)
    private lazy var compressionContent = NSStackView(views: [compressionSpinner, compressionDone, compressionLabel, renderRetry])
    private lazy var compressionStatus = Glass.capsule(holding: compressionContent)
    private var compressionStatusHide: Task<Void, Never>?
    private var mouseDownPoint: CGPoint?
    private var mouseDownScreenPoint: CGPoint?
    private var isResizing = false
    /// The drag started on a resize edge; elsewhere a drag drops the file (single card) or does nothing (pile).
    private var isEdgeDrag = false
    var corner: OverlayCorner = .bottomRight
    /// The 5 pt glass rim plus a little of the image: wide enough to grab, narrow enough not to block drag-out.
    private static let resizeEdge: CGFloat = 8
    /// About the system drag threshold, so a click with a slight jitter stays a click.
    private static let dragThreshold: CGFloat = 4
    /// Roughly a deliberate two-finger flick; a short scroll while hovering does not dismiss.
    private static let swipeDistance: CGFloat = 60
    private var swipeProgress: CGFloat = 0

    private static let cornerRadius: CGFloat = 18
    private static let inset: CGFloat = 5

    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            updateControls()
        }
    }

    /// Part of a collapsed pile: no hover actions, a click expands the pile.
    var isStacked = false {
        didSet {
            guard isStacked != oldValue else { return }
            updateControls()
            toolTip = isStacked ? "Click to expand" : nil
        }
    }

    var isUploading = false {
        didSet {
            guard isUploading != oldValue else { return }
            uploadButton?.isEnabled = !isUploading
            uploadIndicator.isHidden = !isUploading
            if isUploading {
                uploadSpinner.startAnimation(nil)
            } else {
                uploadSpinner.stopAnimation(nil)
            }
        }
    }

    /// A working pill shows with its spinner right away: it arrives with the card, so it needs no entrance of its own.
    var status = Status.idle {
        didSet {
            guard status != oldValue else { return }
            switch status {
            case let .working(label):
                compressionStatusHide?.cancel()
                compressionSpinner.isHidden = false
                compressionDone.isHidden = true
                renderRetry.isHidden = true
                compressionLabel.stringValue = label
                compressionStatus.alphaValue = 1
                compressionStatus.isHidden = false
                compressionSpinner.startAnimation(nil)
            case let .failed(label):
                compressionStatusHide?.cancel()
                compressionSpinner.stopAnimation(nil)
                compressionSpinner.isHidden = true
                compressionDone.isHidden = true
                renderRetry.isHidden = false
                compressionLabel.stringValue = label
                compressionStatus.alphaValue = 1
                compressionStatus.isHidden = false
            case .idle:
                compressionSpinner.stopAnimation(nil)
                hideCompressionStatus(after: .zero)
            }
        }
    }

    /// False while the video is still being rendered or its render failed: there is no file to drag out yet.
    var isFileReady = true

    var statusText: String? {
        compressionStatus.isHidden ? nil : compressionLabel.stringValue
    }

    /// The spinner crossfades into a checkmark and the result while the pill eases to its new width, then the pill fades.
    func showCompressed(_ result: CompressionResult?) {
        compressionStatus.isHidden = false
        compressionStatus.alphaValue = 1
        compressionContent.wantsLayer = true
        let crossfade = CATransition()
        crossfade.type = .fade
        crossfade.duration = Self.compressionMorphDuration
        crossfade.timingFunction = ThumbnailPresenter.easeOut
        compressionContent.layer?.add(crossfade, forKey: "compressed")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.compressionMorphDuration
            context.timingFunction = ThumbnailPresenter.easeOut
            context.allowsImplicitAnimation = true
            compressionSpinner.isHidden = true
            renderRetry.isHidden = true
            compressionDone.isHidden = false
            compressionLabel.stringValue = Self.compressionSummary(result)
            layoutSubtreeIfNeeded()
        }
        hideCompressionStatus(after: Self.compressionSummaryVisibleFor)
    }

    // emil-design-eng: a state change under 300 ms on the strong ease-out curve, and the exit faster than what came before it.
    private static let compressionMorphDuration: TimeInterval = 0.2
    private static let compressionExitDuration: TimeInterval = 0.15

    /// Opacity only, so Reduce Motion needs no other path.
    private func hideCompressionStatus(after delay: Duration) {
        compressionStatusHide?.cancel()
        compressionStatusHide = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.compressionExitDuration
                context.timingFunction = ThumbnailPresenter.easeOut
                self.compressionStatus.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    guard self.status == .idle else { return }
                    self.compressionStatus.isHidden = true
                }
            }
        }
    }

    var stackCount: Int? {
        didSet {
            guard stackCount != oldValue else { return }
            badgeLabel.stringValue = stackCount.map(String.init) ?? ""
            badge.isHidden = stackCount == nil
            setAccessibilityHelp(stackCount.map { "\($0) screenshots, click to expand" })
        }
    }

    init(url: URL, thumbnail: CGImage, isVideo: Bool) {
        self.url = url
        self.isVideo = isVideo
        self.thumbnail = NSImage(cgImage: thumbnail, size: .zero)
        super.init(frame: CGRect(origin: .zero, size: ThumbnailPresenter.size(width: LunettaSettings.defaultThumbnailWidth)))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("\(isVideo ? "Recording" : "Screenshot") \(url.lastPathComponent)")

        let frame = Glass.background(cornerRadius: Self.cornerRadius)
        frame.translatesAutoresizingMaskIntoConstraints = false
        addSubview(frame)

        imageView.wantsLayer = true
        imageView.layer?.contents = ThumbnailCentering.centered(thumbnail)
        imageView.layer?.contentsGravity = .resizeAspect
        imageView.layer?.cornerRadius = Self.cornerRadius - Self.inset
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        // Scrim keeps the glass controls legible over bright captures.
        controls.wantsLayer = true
        controls.layer?.cornerRadius = Self.cornerRadius - Self.inset
        controls.layer?.cornerCurve = .continuous
        controls.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        controls.alphaValue = 0
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)

        // One capsule, not loose glass buttons: loose ones vanish over busy captures.
        let upload = button("icloud.and.arrow.up", "Upload", .upload)
        uploadButton = upload
        // The editor and a pinned panel work on still images, so a video card has no Annotate or Pin.
        let actionButtons = [
            button("doc.on.doc", "Copy", .copy),
            upload,
            button("square.and.arrow.down", "Save As…", .saveAs),
        ] + (isVideo ? [] : [
            button("pencil.tip.crop.circle", "Annotate", .annotate),
            button("pin", "Pin to Screen", .pin),
        ])
        // AppKit shows no tooltip for an inactive app's window, and Lunetta is never active while a card is up (#91).
        for actionButton in actionButtons {
            actionButton.onHoverChange = { [weak self] button, hovered in self?.showActionLabel(for: button, hovered: hovered) }
        }
        let actionBar = Glass.toolbar(actionButtons)
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(actionBar)

        let closeButton = button("xmark", "Close", .close)
        closeButton.toolTip = "Close"
        let close = Glass.toolbar([closeButton])
        close.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(close)

        actionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        actionLabel.textColor = .labelColor
        actionLabel.setAccessibilityIdentifier(AccessibilityID.cardActionLabel)
        actionLabelCapsule.isHidden = true
        actionLabelCapsule.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(actionLabelCapsule)

        badgeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        badgeLabel.textColor = .white
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)

        uploadSpinner.style = .spinning
        uploadSpinner.controlSize = .small
        uploadSpinner.isIndeterminate = true
        uploadSpinner.setAccessibilityLabel("Uploading")
        uploadSpinner.setAccessibilityIdentifier(AccessibilityID.uploadProgress)
        uploadIndicator.isHidden = true
        uploadIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(uploadIndicator)

        compressionSpinner.style = .spinning
        compressionSpinner.controlSize = .small
        compressionSpinner.isIndeterminate = true
        compressionDone.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        compressionDone.contentTintColor = .labelColor
        compressionLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        compressionLabel.textColor = .labelColor
        renderRetry.isBordered = false
        renderRetry.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        renderRetry.contentTintColor = .controlAccentColor
        renderRetry.isHidden = true
        renderRetry.setAccessibilityIdentifier(AccessibilityID.renderRetry)
        renderRetry.target = self
        renderRetry.action = #selector(retryRender)
        compressionLabel.setAccessibilityIdentifier(AccessibilityID.compressionStatus)
        compressionContent.orientation = .horizontal
        compressionContent.spacing = 5
        compressionStatus.isHidden = true
        compressionStatus.translatesAutoresizingMaskIntoConstraints = false
        addSubview(compressionStatus)

        NSLayoutConstraint.activate([
            frame.leadingAnchor.constraint(equalTo: leadingAnchor),
            frame.trailingAnchor.constraint(equalTo: trailingAnchor),
            frame.topAnchor.constraint(equalTo: topAnchor),
            frame.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
            controls.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            controls.topAnchor.constraint(equalTo: imageView.topAnchor),
            controls.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
            actionBar.centerXAnchor.constraint(equalTo: controls.centerXAnchor),
            actionBar.bottomAnchor.constraint(equalTo: controls.bottomAnchor, constant: -8),
            // Same inset from the top and the side, so the close button sits evenly in the corner.
            close.topAnchor.constraint(equalTo: controls.topAnchor, constant: 8),
            close.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 8),
            actionLabelCapsule.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -6),
            actionLabelCapsule.leadingAnchor.constraint(greaterThanOrEqualTo: controls.leadingAnchor, constant: 6),
            actionLabelCapsule.trailingAnchor.constraint(lessThanOrEqualTo: controls.trailingAnchor, constant: -6),
            actionLabelCapsule.heightAnchor.constraint(equalTo: badge.heightAnchor),
            actionLabelCapsule.widthAnchor.constraint(equalTo: actionLabel.widthAnchor, constant: 16),
            badge.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 8),
            badge.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -8),
            badge.heightAnchor.constraint(equalToConstant: 22),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            badge.widthAnchor.constraint(greaterThanOrEqualTo: badgeLabel.widthAnchor, constant: 14),
            uploadIndicator.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            uploadIndicator.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            uploadIndicator.widthAnchor.constraint(equalTo: badge.heightAnchor),
            uploadIndicator.heightAnchor.constraint(equalTo: badge.heightAnchor),
            // Top center: the close button and the pile's count take the top corners, the action bar the bottom.
            compressionStatus.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 8),
            compressionStatus.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            compressionStatus.heightAnchor.constraint(equalTo: badge.heightAnchor),
            compressionStatus.widthAnchor.constraint(equalTo: compressionContent.widthAnchor, constant: 16),
            compressionSpinner.widthAnchor.constraint(equalToConstant: 16),
            compressionSpinner.heightAnchor.constraint(equalToConstant: 16),
        ])

        // .inVisibleRect follows resizes, so one area for the view's lifetime is enough.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func retryRender() {
        onAction?(.retryRender)
    }

    func show(_ thumbnail: CGImage) {
        self.thumbnail = NSImage(cgImage: thumbnail, size: .zero)
        imageView.layer?.contents = ThumbnailCentering.centered(thumbnail)
    }

    /// Clicks anywhere but a button belong to the card (click, drag out, resize), not to the glass subviews.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is NSButton { return controls.alphaValue > 0 ? current : self }
            view = current.superview
        }
        return self
    }

    private func updateControls() {
        let visible = isHovered && !isStacked
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            controls.animator().alphaValue = visible ? 1 : 0
        }
    }

    private func button(_ symbol: String, _ label: String, _ action: Action) -> GlassButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))!
        let button = GlassButton(image: image, target: self, action: #selector(runAction(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.tag = action.rawValue
        button.setAccessibilityLabel(label)
        return button
    }

    private func showActionLabel(for button: NSButton, hovered: Bool) {
        guard hovered else {
            if actionLabel.stringValue == button.accessibilityLabel() { actionLabelCapsule.isHidden = true }
            return
        }
        actionLabel.stringValue = button.accessibilityLabel() ?? ""
        actionLabelCenter?.isActive = false
        let center = actionLabelCapsule.centerXAnchor.constraint(equalTo: button.centerXAnchor)
        center.priority = .defaultHigh // the edge constraints win, so a label never spills off the card
        center.isActive = true
        actionLabelCenter = center
        actionLabelCapsule.isHidden = false
    }

    @objc private func runAction(_ sender: NSButton) {
        guard let action = Action(rawValue: sender.tag) else { return }
        onAction?(action)
    }

    // MARK: Hover

    override func mouseEntered(with event: NSEvent) { onPointerChange?() }

    override func mouseExited(with event: NSEvent) {
        showResizeCursor(nil)
        onPointerChange?()
    }

    // MARK: Resize edges

    private func resizePosition(at windowPoint: CGPoint) -> NSCursor.FrameResizePosition? {
        let p = convert(windowPoint, from: nil)
        let top = p.y >= bounds.maxY - Self.resizeEdge
        let side = corner == .bottomRight ? p.x <= Self.resizeEdge : p.x >= bounds.maxX - Self.resizeEdge
        switch (top, side) {
        case (true, true): return corner == .bottomRight ? .topLeft : .topRight
        case (true, false): return .top
        case (false, true): return corner == .bottomRight ? .left : .right
        case (false, false): return nil
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard mouseDownPoint == nil else { return }
        showResizeCursor(resizePosition(at: event.locationInWindow))
    }

    private var showsResizeCursor = false

    /// Only touches the cursor when entering or leaving a resize edge, so the frontmost app keeps its own
    /// cursor (I-beam, etc.) everywhere else. Needs `BackgroundCursor.enable()`: Lunetta is never the active app.
    private func showResizeCursor(_ position: NSCursor.FrameResizePosition?) {
        if let position {
            NSCursor.frameResize(position: position, directions: .all).set()
            showsResizeCursor = true
        } else if showsResizeCursor {
            NSCursor.arrow.set()
            showsResizeCursor = false
        }
    }

    // MARK: Click, drag out, swipe

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        mouseDownScreenPoint = NSEvent.mouseLocation // the panel moves while resizing, so measure on screen
        isResizing = false
        isEdgeDrag = resizePosition(at: event.locationInWindow) != nil
    }

    private func dragTranslation() -> CGSize? {
        guard let start = mouseDownScreenPoint else { return nil }
        let now = NSEvent.mouseLocation
        return CGSize(width: now.x - start.x, height: now.y - start.y)
    }

    override func mouseDragged(with event: NSEvent) {
        // Resizing happens only from the edges (the cursor says so); elsewhere a pile expands on click
        // and a single card drags its file out.
        if isEdgeDrag, mouseDownPoint != nil, let translation = dragTranslation() {
            guard isResizing || hypot(translation.width, translation.height) > Self.dragThreshold else { return }
            isResizing = true
            onResize?(.drag(translation: translation, ended: false))
            return
        }
        guard let start = mouseDownPoint, !isStacked, isFileReady else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > Self.dragThreshold else { return }
        mouseDownPoint = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: thumbnail)
        onDragOut?(true)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            mouseDownScreenPoint = nil
            isResizing = false
            isEdgeDrag = false
        }
        if isResizing, let translation = dragTranslation() {
            return onResize?(.drag(translation: translation, ended: true)) ?? ()
        }
        guard mouseDownPoint != nil else { return }
        onAction?(Self.clickAction(isStacked: isStacked, isVideo: isVideo))
    }

    override func scrollWheel(with event: NSEvent) {
        // Momentum events after a swipe would otherwise dismiss the next card that slides under the pointer.
        guard event.hasPreciseScrollingDeltas, event.momentumPhase == [], !isStacked else { return }
        if event.phase == .began { swipeProgress = 0 }
        swipeProgress += event.scrollingDeltaX
        if abs(swipeProgress) > Self.swipeDistance {
            let edge = ThumbnailPresenter.swipeEdge(scrollDelta: swipeProgress, naturalScrolling: event.isDirectionInvertedFromDevice)
            swipeProgress = 0
            onSwipeAway?(edge)
        }
    }

    override func magnify(with event: NSEvent) {
        onResize?(.magnify(event.magnification, ended: event.phase == .ended || event.phase == .cancelled))
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragOut?(false)
        if operation != [] { onAction?(.dropped) }
    }
}

/// Lets Lunetta set the cursor while another app is active. Lunetta is a menu bar app whose panels never
/// activate it, and macOS otherwise ignores cursor changes from inactive apps, so the resize cursor
/// would never show. There is no public API for this.
// ponytail: private WindowServer property (widely used by menu bar utilities), looked up at runtime so a
// macOS update that drops it only loses the cursor hint; resizing and launch are unaffected.
@MainActor
enum BackgroundCursor {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private static var enabled = false

    static func enable() {
        guard !enabled else { return }
        enabled = true
        let process = dlopen(nil, RTLD_NOW)
        guard let mainSymbol = dlsym(process, "CGSMainConnectionID"),
              let setSymbol = dlsym(process, "CGSSetConnectionProperty")
        else { return }
        let connection = unsafeBitCast(mainSymbol, to: MainConnectionID.self)()
        let setProperty = unsafeBitCast(setSymbol, to: SetConnectionProperty.self)
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}

private extension NSScreen {
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private final class PinnedPanel: NSPanel {
    var onClose: (() -> Void)?

    override func close() {
        super.close()
        onClose?()
    }
}

/// Window captures keep the macOS shadow, which is heavier below than above (32 px top, 60 px bottom, 46 px each
/// side for a 400x332 pt window on a 2x display, #91), so the window sat high in the card. Trimming the extra
/// shadow on the heavier side centers the window; the saved PNG keeps all of it.
enum ThumbnailCentering {
    static func centered(_ image: CGImage) -> CGImage {
        guard hasAlpha(image), let opaque = opaqueBounds(of: image) else { return image }
        let crop = evenPaddingCrop(size: CGSize(width: image.width, height: image.height), opaque: opaque)
        return image.cropping(to: crop) ?? image
    }

    static func evenPaddingCrop(size: CGSize, opaque: CGRect) -> CGRect {
        let horizontal = min(opaque.minX, size.width - opaque.maxX)
        let vertical = min(opaque.minY, size.height - opaque.maxY)
        return opaque.insetBy(dx: -horizontal, dy: -vertical)
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    }

    /// Fully opaque span of the middle row and middle column, in pixels from the top-left. Shadow is never fully
    /// opaque, window content always is; nil when either line has no opaque pixel.
    static func opaqueBounds(of image: CGImage) -> CGRect? {
        guard let columns = opaqueSpan(of: image, line: CGRect(x: 0, y: image.height / 2, width: image.width, height: 1)),
              let rows = opaqueSpan(of: image, line: CGRect(x: image.width / 2, y: 0, width: 1, height: image.height))
        else { return nil }
        return CGRect(x: columns.lowerBound, y: rows.lowerBound, width: columns.count, height: rows.count)
    }

    private static func opaqueSpan(of image: CGImage, line: CGRect) -> Range<Int>? {
        guard let strip = image.cropping(to: line) else { return nil }
        let count = max(strip.width, strip.height)
        var pixels = [UInt8](repeating: 0, count: count * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: strip.width, height: strip.height, bitsPerComponent: 8,
                bytesPerRow: strip.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(strip, in: CGRect(x: 0, y: 0, width: strip.width, height: strip.height))
            return true
        }
        guard drawn else { return nil }
        let opaque = (0..<count).filter { pixels[$0 * 4 + 3] == 255 }
        guard let first = opaque.first, let last = opaque.last else { return nil }
        return first..<(last + 1)
    }
}

enum ThumbnailDownsampler {
    static func downsample(_ image: CGImage, maxPixelSize: CGFloat) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longest = max(width, height)
        guard longest > maxPixelSize, maxPixelSize > 0 else { return image }
        let scale = maxPixelSize / longest
        let outWidth = max(Int((width * scale).rounded()), 1)
        let outHeight = max(Int((height * scale).rounded()), 1)
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: outWidth,
            height: outHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        return context.makeImage() ?? image
    }
}
