import AppKit
import GlintCore
import GlintEditor
import ImageIO
import UniformTypeIdentifiers

/// Quick-access overlay. Never appears in captures: ScreenCapturer excludes Glint's own windows.
@MainActor
final class ThumbnailPresenter {
    static func size(width: CGFloat) -> CGSize {
        CGSize(width: width, height: (width * 2 / 3).rounded())
    }
    static let margin: CGFloat = 16
    static let spacing: CGFloat = 10

    private let settings: GlintSettings
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
    private let uploadFile: @MainActor (URL) async throws -> UploadedCapture
    private let onUploaded: @MainActor (UploadedCapture) -> Void
    private var observers: [NSObjectProtocol] = []
    private var lastLayoutSettings: LayoutSettings?
    private var liveWidth: CGFloat?
    private var resizeStartWidth: CGFloat?
    private var width: CGFloat { liveWidth ?? CGFloat(settings.thumbnailWidth) }

    // ponytail: fixed 6 s when auto-hide is on; make the delay a setting if someone asks.
    init(
        settings: GlintSettings,
        upload: @escaping @MainActor (URL) async throws -> UploadedCapture,
        onUploaded: @escaping @MainActor (UploadedCapture) -> Void,
        autoDismissDelay: Duration = .seconds(6),
        pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation }
    ) {
        self.settings = settings
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
            // Corner / size / auto-hide changes in Settings apply to thumbnails already on screen.
            // Deferred: AppKit posts this from inside its own launch-time dispatch_once (registerDefaults),
            // and re-entering AppKit synchronously from there crashes.
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in self?.settingsChanged() }
            },
        ]
    }

    func show(_ url: URL) {
        let screen = NSScreen.screens.first { $0.frame.contains(pointerLocation()) } ?? NSScreen.main
        guard let screen, let item = ThumbnailItem(url: url, screen: screen) else { return }
        item.view.onAction = { [weak self, weak item] action in
            guard let self, let item else { return }
            self.handle(action, for: item)
        }
        item.view.onPointerChange = { [weak self] in self?.refreshHover() }
        item.view.onResize = { [weak self] change in self?.resize(change) }
        item.view.onDragOut = { [weak self] inProgress in self?.setDraggingOut(inProgress) }
        items.insert(item, at: 0)
        expansion.collapse(on: screen)
        cancelAutoDismiss() // still stacking: restart the countdown (layout() schedules it again)
        layout()
        if settings.uploadAfterCapture {
            upload(item)
        }
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

    private func layout() {
        lastLayoutSettings = LayoutSettings(settings)
        dropOverflow()
        guard !items.isEmpty else { return }
        let corner = settings.overlayCorner
        var groups: [NSScreen: [ThumbnailItem]] = [:]
        for item in items { groups[item.screen, default: []].append(item) }

        for (screen, group) in groups {
            let collapsed = !expansion.isExpanded(on: screen) && group.count > 1
            for (index, item) in group.enumerated() {
                item.view.stackCount = collapsed && index == 0 ? group.count : nil
                item.view.isStacked = collapsed
                item.view.corner = corner
                item.targetFrame = Self.frame(at: index, in: screen.visibleFrame, corner: corner, collapsed: collapsed, width: width)
                guard let frame = item.targetFrame else {
                    item.panel.orderOut(nil)
                    continue
                }
                if item.panel.isVisible, liveWidth == nil {
                    item.panel.animator().setFrame(frame, display: true)
                } else {
                    item.panel.setFrame(frame, display: item.panel.isVisible) // follow resize gestures without lag
                }
            }
            // Newest on top: order back to front.
            for item in group.reversed() where item.targetFrame != nil {
                item.panel.orderFrontRegardless()
            }
        }
        refreshHover()
    }

    // ponytail: drops the oldest once the expanded column would overflow the screen, on every layout, so a
    // new capture, a resize, a Settings change and a smaller display all follow the same rule.
    private func dropOverflow() {
        for (screen, group) in Dictionary(grouping: items, by: { $0.screen }) {
            group.dropFirst(Self.columnCapacity(in: screen.visibleFrame, width: width)).forEach(remove)
        }
    }

    /// Hover is derived from the pointer position, not cached from enter/exit events: panels that move,
    /// resize or hide under a still pointer never get an exit event.
    private func refreshHover() {
        let pointer = pointerLocation()
        // Newest first and ordered on top, so the first hit is the card the pointer is actually over.
        let hovered = items.first { $0.targetFrame?.contains(pointer) == true }
        for item in items { item.view.isHovered = item === hovered }
        scheduleFolding(pointerOver: hovered?.screen)

        // Hovering any thumbnail, dragging one out, a modal panel (Save As), an open editor or a running upload pauses auto-hide for the whole overlay.
        if hovered != nil || isDraggingOut || isRunningModal || !editors.isEmpty || items.contains(where: \.isUploading) {
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
                self.items.forEach(self.remove)
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
        liveWidth = CGFloat(GlintSettings.clampWidth(Double(proposed)))
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

    func settingsChanged() {
        guard LayoutSettings(settings) != lastLayoutSettings else { return }
        layout()
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
    var urls: [URL] { items.map(\.url) }

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
        switch action {
        case .copy:
            do {
                try NSPasteboard.general.copyPNGFile(at: item.url)
                remove(item)
            } catch {
                showError("Glint couldn't copy the screenshot", error)
            }
        case .upload:
            upload(item)
        case .saveAs:
            saveAs(item)
        case .annotate:
            annotate(item)
        case .pin:
            remove(item)
            pin(item.url, on: item.screen)
        case .close:
            remove(item)
        case .expand:
            expansion.expand(on: item.screen)
        }
        layout()
    }

    private func remove(_ item: ThumbnailItem) {
        item.panel.orderOut(nil)
        items.removeAll { $0 === item }
        // Actions arrive from inside the panel's own event handling; free it on the next turn.
        DispatchQueue.main.async { withExtendedLifetime(item) {} }
    }

    private func upload(_ item: ThumbnailItem) {
        guard !item.isUploading else { return }
        item.isUploading = true
        refreshHover()
        Task {
            do {
                let uploaded = try await uploadFile(item.url)
                item.isUploading = false
                remove(item)
                layout()
                onUploaded(uploaded)
            } catch {
                item.isUploading = false
                showError("Glint couldn't upload the screenshot", error)
            }
            refreshHover()
        }
    }

    private func saveAs(_ item: ThumbnailItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.url.lastPathComponent
        panel.allowedContentTypes = [.png]
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
            showError("Glint couldn't save the screenshot", error)
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
                onSaved: { [weak self] in self?.items.first { $0.url == url }?.reloadThumbnail() },
                onClose: { [weak self] in
                    self?.editors[url] = nil
                    self?.refreshHover()
                }
            )
        } catch {
            showError("Glint couldn't open the screenshot for annotation", error)
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
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        runActivated { _ = alert.runModal() }
    }

    private func runActivated<T>(_ body: () -> T) -> T {
        isRunningModal = true
        refreshHover()
        defer {
            isRunningModal = false
            refreshHover()
        }
        return runWithGlintActive(body)
    }
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
    var isUploading = false {
        didSet { view.isUploading = isUploading }
    }

    init?(url: URL, screen: NSScreen) {
        guard let thumbnail = Self.thumbnail(of: url, on: screen) else { return nil }
        self.url = url
        self.screen = screen
        view = ThumbnailView(url: url, thumbnail: thumbnail)
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: ThumbnailPresenter.size(width: GlintSettings.defaultThumbnailWidth)), // layout() sets the real frame
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        // NSPanel hides when its app deactivates by default; Save As / Settings activate Glint.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = view
    }

    func reloadThumbnail() {
        guard let thumbnail = Self.thumbnail(of: url, on: screen) else { return }
        view.show(thumbnail)
    }

    // A downsampled copy: the full capture can be tens of MB and thumbnails stay until dismissed.
    // Sized for the widest card the user can pick, so it stays sharp after resizing.
    private static func thumbnail(of url: URL, on screen: NSScreen) -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: GlintSettings.thumbnailWidthRange.upperBound * screen.backingScaleFactor,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

private final class ThumbnailView: NSView, NSDraggingSource {
    enum Action: Int { case copy, upload, saveAs, annotate, pin, close, expand }
    enum Resize {
        case drag(translation: CGSize, ended: Bool)
        case magnify(CGFloat, ended: Bool)
    }

    var onAction: ((Action) -> Void)?
    var onPointerChange: (() -> Void)?
    var onResize: ((Resize) -> Void)?
    var onDragOut: ((_ inProgress: Bool) -> Void)?

    private let url: URL
    private var thumbnail: NSImage
    private let imageView = NSView()
    private let controls = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private lazy var badge = Glass.capsule(holding: badgeLabel, tint: .controlAccentColor)
    private var uploadButton: NSButton?
    private let uploadSpinner = NSProgressIndicator()
    private lazy var uploadIndicator = Glass.capsule(holding: uploadSpinner, tint: .controlAccentColor)
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
        didSet { updateControls() }
    }

    /// Part of a collapsed pile: no hover actions, a click expands the pile.
    var isStacked = false {
        didSet {
            updateControls()
            toolTip = isStacked ? "Click to expand" : nil
        }
    }

    var isUploading = false {
        didSet {
            uploadButton?.isEnabled = !isUploading
            uploadIndicator.isHidden = !isUploading
            if isUploading {
                uploadSpinner.startAnimation(nil)
            } else {
                uploadSpinner.stopAnimation(nil)
            }
        }
    }

    var stackCount: Int? {
        didSet {
            badgeLabel.stringValue = stackCount.map(String.init) ?? ""
            badge.isHidden = stackCount == nil
            setAccessibilityHelp(stackCount.map { "\($0) screenshots, click to expand" })
        }
    }

    init(url: URL, thumbnail: CGImage) {
        self.url = url
        self.thumbnail = NSImage(cgImage: thumbnail, size: .zero)
        super.init(frame: CGRect(origin: .zero, size: ThumbnailPresenter.size(width: GlintSettings.defaultThumbnailWidth)))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Screenshot \(url.lastPathComponent)")

        let frame = Glass.background(cornerRadius: Self.cornerRadius)
        frame.translatesAutoresizingMaskIntoConstraints = false
        addSubview(frame)

        imageView.wantsLayer = true
        imageView.layer?.contents = thumbnail
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
        let actionBar = Glass.toolbar([
            button("doc.on.doc", "Copy", .copy),
            upload,
            button("square.and.arrow.down", "Save As…", .saveAs),
            button("pencil.tip.crop.circle", "Annotate", .annotate),
            button("pin", "Pin to Screen", .pin),
        ])
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(actionBar)

        let close = Glass.toolbar([button("xmark", "Close", .close)])
        close.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(close)

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
            badge.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 8),
            badge.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -8),
            badge.heightAnchor.constraint(equalToConstant: 22),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            badge.widthAnchor.constraint(greaterThanOrEqualTo: badgeLabel.widthAnchor, constant: 14),
            uploadIndicator.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            uploadIndicator.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            uploadIndicator.widthAnchor.constraint(equalTo: badge.heightAnchor),
            uploadIndicator.heightAnchor.constraint(equalTo: badge.heightAnchor),
        ])

        // .inVisibleRect follows resizes, so one area for the view's lifetime is enough.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ thumbnail: CGImage) {
        self.thumbnail = NSImage(cgImage: thumbnail, size: .zero)
        imageView.layer?.contents = thumbnail
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

    private func button(_ symbol: String, _ label: String, _ action: Action) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))!
        let button = FirstMouseButton(image: image, target: self, action: #selector(runAction(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .labelColor
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        button.tag = action.rawValue
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
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
    /// cursor (I-beam, etc.) everywhere else. Needs `BackgroundCursor.enable()`: Glint is never the active app.
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
        guard let start = mouseDownPoint, !isStacked else { return }
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
        onAction?(isStacked ? .expand : .annotate)
    }

    override func scrollWheel(with event: NSEvent) {
        // Momentum events after a swipe would otherwise dismiss the next card that slides under the pointer.
        guard event.hasPreciseScrollingDeltas, event.momentumPhase == [], !isStacked else { return }
        if event.phase == .began { swipeProgress = 0 }
        swipeProgress += event.scrollingDeltaX
        if abs(swipeProgress) > Self.swipeDistance {
            swipeProgress = 0
            onAction?(.close)
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
        if operation != [] { onAction?(.close) }
    }
}

/// Liquid Glass on macOS 26, with the closest pre-26 material as a fallback (the app still targets macOS 15).
@MainActor
private enum Glass {
    static func background(cornerRadius: CGFloat, tint: NSColor? = nil) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint
            return glass
        }
        if let tint {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = tint.cgColor
            view.layer?.cornerRadius = cornerRadius
            return view
        }
        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        return material
    }

    static func capsule(holding label: NSView, tint: NSColor) -> NSView {
        let content = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        let capsule = background(cornerRadius: 11, tint: tint)
        setContent(content, of: capsule)
        return capsule
    }

    static func toolbar(_ buttons: [NSButton]) -> NSView {
        let stack = NSStackView(views: buttons)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: buttons.count > 1 ? 6 : 2, bottom: 2, right: buttons.count > 1 ? 6 : 2)
        let radius: CGFloat = 16 // half of the 28pt buttons plus the 2pt insets: a capsule
        let background = background(cornerRadius: radius)
        setContent(stack, of: background)
        return background
    }

    /// Only a glass view's `contentView` is guaranteed to render inside the glass.
    private static func setContent(_ content: NSView, of background: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26, *), let glass = background as? NSGlassEffectView {
            glass.contentView = content
        } else {
            background.addSubview(content)
        }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }
}

/// Lets Glint set the cursor while another app is active. Glint is a menu bar app whose panels never
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

/// Corner, width and auto-hide: the settings the overlay lays out from.
private struct LayoutSettings: Equatable {
    let corner: OverlayCorner
    let width: Double
    let autoDismiss: Bool

    @MainActor init(_ settings: GlintSettings) {
        corner = settings.overlayCorner
        width = settings.thumbnailWidth
        autoDismiss = settings.overlayAutoDismiss
    }
}

/// Non-activating panels never become key; without this the first click on a button is eaten.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class PinnedPanel: NSPanel {
    var onClose: (() -> Void)?

    override func close() {
        super.close()
        onClose?()
    }
}
