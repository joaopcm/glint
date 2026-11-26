import AppKit
import KeyboardShortcuts
import LunettaCore
import LunettaUI
import os

/// Everything on screen around a recording: the dim outside the recorded area, the countdown, the floating controls
/// and the timer in the menu bar. All of them are Lunetta windows, which ScreenCapturer leaves out of every recording.
@MainActor
final class RecordingHUD {
    static let countdownSeconds = 3
    /// Above the Dock (20) so the outside reads as one dimmed surface, below the menu bar (24) so the timer stays bright.
    private static let dimLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
    private static let chromeLevel = NSWindow.Level.statusBar
    private static let gap: CGFloat = 12

    var onStop: (@MainActor () -> Void)?
    var onTogglePause: (@MainActor () -> Void)?
    var onDiscard: (@MainActor () -> Void)?

    private let sounds: RecordingSounds
    private var dims: [NSPanel] = []
    private var countdownPanel: NSPanel?
    private var countdownView: CountdownView?
    private var countdownDecision: CheckedContinuation<Bool, Never>?
    private var countdownSteps: Task<Void, Never>?
    private var controlsPanel: NSPanel?
    private var controls: RecordingControlsView?
    private var timer: RecordingTimerItem?
    private var status: RecordingStatus?
    private var ticking: Task<Void, Never>?

    init(settings: LunettaSettings) {
        sounds = RecordingSounds(settings: settings)
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Countdown

    /// Leaves the dim up when it returns true, so the recording starts under the same frame the countdown showed.
    func countDown(_ status: RecordingStatus) async -> Bool {
        showDim(for: status)
        presentCountdown(over: status.region)
        KeyboardShortcuts.onKeyDown(for: .cancelRecordingCountdown) { [weak self] in self?.decideCountdown(false) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                countdownDecision = continuation
                countdownSteps = Task { [weak self] in
                    for number in stride(from: Self.countdownSeconds, to: 0, by: -1) {
                        self?.countdownView?.show(number)
                        self?.sounds.play(.tick)
                        try? await Task.sleep(for: .seconds(1))
                        if Task.isCancelled { return }
                    }
                    self?.decideCountdown(true)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.decideCountdown(false) }
        }
    }

    private func decideCountdown(_ proceed: Bool) {
        guard let decision = countdownDecision else { return }
        countdownDecision = nil
        countdownSteps?.cancel()
        countdownSteps = nil
        KeyboardShortcuts.removeHandler(for: .cancelRecordingCountdown)
        if let panel = countdownPanel { fadeOut(panel, duration: 0.15) }
        countdownPanel = nil
        countdownView = nil
        if !proceed { hideDim() }
        decision.resume(returning: proceed)
    }

    private func presentCountdown(over region: CGRect) {
        let view = CountdownView()
        view.onSkip = { [weak self] in self?.decideCountdown(true) }
        let visible = Self.screen(for: region).visibleFrame
        let center = RecordingGeometry.countdownCenter(size: view.frame.size, region: region, visible: visible)
        let frame = CGRect(x: center.x - view.frame.width / 2, y: center.y - view.frame.height / 2, width: view.frame.width, height: view.frame.height)
        let panel = Self.panel(frame: frame, level: Self.chromeLevel)
        panel.contentView = view
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ThumbnailPresenter.enterDuration
            context.timingFunction = ThumbnailPresenter.easeOut
            panel.animator().alphaValue = 1
        }
        view.startRing(seconds: Double(Self.countdownSeconds), reduceMotion: reduceMotion)
        countdownPanel = panel
        countdownView = view
    }

    // MARK: Recording

    func handle(_ event: RecordingEvent) {
        switch event {
        case .started(let status):
            show(status)
            sounds.play(.start)
        case .paused(let status):
            update(status)
            sounds.play(.pause)
        case .resumed(let status):
            update(status)
            sounds.play(.resume)
        case .ended(let end):
            hideAll()
            switch end {
            case .saved: sounds.play(.stop)
            case .discarded: sounds.play(.discard)
            case .failed: break
            }
        }
    }

    private func show(_ status: RecordingStatus) {
        showDim(for: status)
        let controls = RecordingControlsView()
        controls.onTogglePause = { [weak self] in self?.onTogglePause?() }
        controls.onStop = { [weak self] in self?.onStop?() }
        controls.onDiscard = { [weak self] in self?.onDiscard?() }
        self.controls = controls
        let visible = Self.screen(for: status.region).visibleFrame
        let frame = RecordingGeometry.controlBarFrame(size: controls.panelSize, region: status.region, visible: visible, gap: Self.gap)
        let panel = Self.panel(frame: frame, level: Self.chromeLevel)
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView = controls
        controlsPanel = panel
        timer = RecordingTimerItem(onClick: { [weak self] in self?.onStop?() })
        update(status)
        // Comes up from just below where it rests and leaves the same way.
        let start = reduceMotion ? frame : frame.offsetBy(dx: 0, dy: -8)
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ThumbnailPresenter.enterDuration
            context.timingFunction = ThumbnailPresenter.easeOut
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func update(_ status: RecordingStatus) {
        self.status = status
        refreshTime()
        ticking?.cancel()
        ticking = nil
        guard status.clock.isRunning else { return }
        ticking = Task { [weak self] in
            while !Task.isCancelled, let clock = self?.status?.clock {
                // 10 ms past the boundary, so a wake-up a hair early still reads the new second.
                try? await Task.sleep(for: .seconds(clock.untilNextSecond(at: Date()) + 0.01))
                self?.refreshTime()
            }
        }
    }

    private func refreshTime() {
        guard let status else { return }
        let label = RecordingClock.label(status.clock.elapsed(at: Date()))
        controls?.show(time: label, paused: !status.clock.isRunning)
        timer?.show(time: label, paused: !status.clock.isRunning)
        if let controlsPanel, let controls, controlsPanel.frame.width != controls.panelSize.width {
            let size = controls.panelSize
            let frame = controlsPanel.frame
            controlsPanel.setFrame(CGRect(x: (frame.midX - size.width / 2).rounded(), y: frame.minY, width: size.width, height: size.height), display: true)
        }
    }

    private func hideAll() {
        ticking?.cancel()
        ticking = nil
        status = nil
        if let controlsPanel {
            let resting = controlsPanel.frame
            controlsPanel.ignoresMouseEvents = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = ThumbnailPresenter.exitDuration
                context.timingFunction = ThumbnailPresenter.easeOut
                if !reduceMotion { controlsPanel.animator().setFrame(resting.offsetBy(dx: 0, dy: -8), display: true) }
                controlsPanel.animator().alphaValue = 0
            } completionHandler: {
                controlsPanel.orderOut(nil)
            }
        }
        controlsPanel = nil
        controls = nil
        timer?.remove()
        timer = nil
        hideDim()
    }

    // MARK: Dim

    private func showDim(for status: RecordingStatus) {
        guard status.dimsOutside, dims.isEmpty else { return }
        dims = NSScreen.screens.map { screen in
            let panel = Self.panel(frame: screen.frame, level: Self.dimLevel)
            panel.ignoresMouseEvents = true
            panel.contentView = DimView(
                size: screen.frame.size,
                hole: status.region.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY),
                scale: screen.backingScaleFactor
            )
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            return panel
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = ThumbnailPresenter.easeOut
            for panel in dims { panel.animator().alphaValue = 1 }
        }
    }

    private func hideDim() {
        for panel in dims { fadeOut(panel, duration: ThumbnailPresenter.exitDuration) }
        dims = []
    }

    // MARK: Windows

    private func fadeOut(_ panel: NSPanel, duration: TimeInterval) {
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = ThumbnailPresenter.easeOut
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private static func panel(frame: CGRect, level: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    private static func screen(for region: CGRect) -> NSScreen {
        let area = { (screen: NSScreen) -> CGFloat in
            let overlap = screen.frame.intersection(region)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        return NSScreen.screens.max { area($0) < area($1) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

/// Darkens everything but the hole, with a hairline on the hole's edge so the boundary reads over any content.
private final class DimView: NSView {
    init(size: CGSize, hole: CGRect, scale: CGFloat) {
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        let shade = CAShapeLayer()
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(hole)
        shade.path = path
        shade.fillRule = .evenOdd
        shade.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        shade.contentsScale = scale
        let edge = CAShapeLayer()
        edge.path = CGPath(rect: hole.insetBy(dx: -0.5, dy: -0.5), transform: nil)
        edge.fillColor = nil
        edge.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
        edge.lineWidth = 1
        edge.contentsScale = scale
        layer?.addSublayer(shade)
        layer?.addSublayer(edge)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A glass disc with the seconds left and a red ring running out toward the first frame. Clicking it starts right away.
private final class CountdownView: NSView {
    private static let disc: CGFloat = 112
    private static let ringWidth: CGFloat = 3
    private static let hintHeight = Glass.capsuleHeight
    private static let hintGap: CGFloat = 10
    private static let width: CGFloat = 230

    var onSkip: (() -> Void)?
    private let face = NSView()
    private let digit = CATextLayer()
    private let ring = CAShapeLayer()
    private let track = CAShapeLayer()
    private let font: NSFont = {
        let base = NSFont.systemFont(ofSize: 52, weight: .semibold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 52) } ?? base
    }()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.disc + Self.hintGap + Self.hintHeight))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(AccessibilityID.recordingCountdown)

        let discFrame = CGRect(x: (Self.width - Self.disc) / 2, y: bounds.height - Self.disc, width: Self.disc, height: Self.disc)
        let glass = Glass.background(cornerRadius: Self.disc / 2)
        glass.frame = discFrame
        addSubview(glass)

        face.frame = discFrame
        face.wantsLayer = true
        addSubview(face)
        let center = CGPoint(x: Self.disc / 2, y: Self.disc / 2)
        let path = CGMutablePath()
        path.addArc(center: center, radius: Self.disc / 2 - 6, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for (layer, width) in [(track, Self.ringWidth), (ring, Self.ringWidth)] {
            layer.path = path
            layer.fillColor = nil
            layer.lineWidth = width
            layer.lineCap = .round
            face.layer?.addSublayer(layer)
        }
        digit.alignmentMode = .center
        digit.font = font
        digit.fontSize = font.pointSize
        // CATextLayer hangs the line from its top; place it so the digits' cap height sits on the disc's center.
        let lineHeight = ceil(font.ascender - font.descender)
        let baseline = (Self.disc - font.capHeight) / 2
        digit.frame = CGRect(x: 0, y: baseline + font.ascender - lineHeight, width: Self.disc, height: lineHeight)
        face.layer?.addSublayer(digit)

        let hint = NSTextField(labelWithString: "Click to start now · Esc to cancel")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        hint.textColor = .labelColor
        let capsule = Glass.capsule(holding: hint)
        capsule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(capsule)
        NSLayoutConstraint.activate([
            capsule.centerXAnchor.constraint(equalTo: centerXAnchor),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor),
            capsule.heightAnchor.constraint(equalToConstant: Self.hintHeight),
            capsule.widthAnchor.constraint(equalTo: hint.widthAnchor, constant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [digit, ring, track] { layer.contentsScale = scale }
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            digit.foregroundColor = NSColor.labelColor.cgColor
            track.strokeColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            ring.strokeColor = NSColor.systemRed.cgColor
        }
    }

    func show(_ number: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        digit.string = "\(number)"
        CATransaction.commit()
        setAccessibilityLabel("Recording starts in \(number)")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        digit.add(fade, forKey: "fade")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // Apple's critically damped default: response 0.35 s → stiffness (2π / 0.35)² ≈ 322, damping 2√322 ≈ 35.9.
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.75
        pop.toValue = 1
        pop.mass = 1
        pop.stiffness = 322
        pop.damping = 35.9
        pop.duration = pop.settlingDuration
        digit.add(pop, forKey: "pop")
    }

    func startRing(seconds: Double, reduceMotion: Bool) {
        guard !reduceMotion else { return }
        let drain = CABasicAnimation(keyPath: "strokeEnd")
        drain.fromValue = 1
        drain.toValue = 0
        drain.duration = seconds
        drain.timingFunction = CAMediaTimingFunction(name: .linear)
        drain.fillMode = .forwards
        drain.isRemovedOnCompletion = false
        ring.add(drain, forKey: "drain")
    }

    /// Only the disc takes clicks; the hint and the corners around the disc let them through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let dx = local.x - face.frame.midX
        let dy = local.y - face.frame.midY
        return dx * dx + dy * dy <= pow(Self.disc / 2, 2) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onSkip?()
    }

    override func accessibilityPerformPress() -> Bool {
        onSkip?()
        return true
    }
}

/// Elapsed time, pause or resume, stop and discard in one glass capsule, styled like the quick-access card's toolbar.
/// Discard asks for a second click, so a slip next to Stop never throws a recording away.
private final class RecordingControlsView: NSView {
    /// "Click again to discard" is 4 words, about 1 s at the 238 wpm adult silent reading rate (Brysbaert 2019,
    /// doi:10.1016/j.jml.2019.104047); 3 s leaves time to read it and click again.
    private static let discardConfirmation: Duration = .seconds(3)
    private static let labelHeight = Glass.capsuleHeight
    private static let labelGap: CGFloat = 6

    var onTogglePause: (() -> Void)?
    var onStop: (() -> Void)?
    var onDiscard: (() -> Void)?

    private let dot = NSView()
    private let time = NSTextField(labelWithString: "0:00")
    private lazy var pauseButton = button("pause.fill", "Pause", AccessibilityID.pauseRecording, #selector(togglePause))
    private lazy var stopButton = button("stop.fill", "Stop and Save", AccessibilityID.stopRecordingControl, #selector(stop))
    private lazy var discardButton = button("trash", "Discard", AccessibilityID.discardRecording, #selector(discard))
    private let actionLabel = NSTextField(labelWithString: "")
    private lazy var actionLabelCapsule = Glass.capsule(holding: actionLabel)
    private var actionLabelCenter: NSLayoutConstraint?
    private var hoveredButton: GlassButton?
    private var discardDisarm: Task<Void, Never>?
    private var isPaused = false

    init() {
        super.init(frame: .zero)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        time.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        time.textColor = .labelColor
        time.setAccessibilityIdentifier(AccessibilityID.recordingTime)
        let clock = NSStackView(views: [dot, time])
        clock.spacing = 6
        clock.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        stopButton.tint = .systemRed

        let bar = Glass.toolbar([clock, pauseButton, stopButton, Glass.divider(), discardButton])
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        actionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        actionLabel.textColor = .labelColor
        actionLabel.setAccessibilityIdentifier(AccessibilityID.cardActionLabel)
        actionLabelCapsule.isHidden = true
        actionLabelCapsule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actionLabelCapsule)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            // Wide enough for "00:00", so the bar keeps its width for the first hour.
            time.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.textWidth("00:00", font: time.font!)),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: Self.labelHeight + Self.labelGap),
            actionLabelCapsule.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -Self.labelGap),
            actionLabelCapsule.heightAnchor.constraint(equalToConstant: Self.labelHeight),
            actionLabelCapsule.widthAnchor.constraint(equalTo: actionLabel.widthAnchor, constant: 16),
            actionLabelCapsule.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            actionLabelCapsule.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        for button in [pauseButton, stopButton, discardButton] {
            button.onHoverChange = { [weak self] button, hovered in self?.hover(button, hovered) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whole points, so the panel's frame matches it exactly and a re-fit only happens when the time gets wider.
    var panelSize: CGSize {
        let size = fittingSize
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    func show(time label: String, paused: Bool) {
        time.stringValue = label
        guard paused != isPaused else { return }
        isPaused = paused
        time.textColor = paused ? .secondaryLabelColor : .labelColor
        dot.layer?.backgroundColor = (paused ? NSColor.tertiaryLabelColor : NSColor.systemRed).cgColor
        let title = paused ? "Resume" : "Pause"
        pauseButton.image = Self.symbol(paused ? "play.fill" : "pause.fill", title)
        pauseButton.setAccessibilityLabel(title)
        if hoveredButton === pauseButton { showLabel(title, over: pauseButton) }
    }

    private static func symbol(_ name: String, _ label: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: label)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))!
    }

    private func button(_ symbol: String, _ label: String, _ id: String, _ action: Selector) -> GlassButton {
        let button = GlassButton(image: Self.symbol(symbol, label), target: self, action: action)
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(id)
        return button
    }

    private func hover(_ button: GlassButton, _ hovered: Bool) {
        guard hovered else {
            if hoveredButton === button { hoveredButton = nil }
            if hoveredButton == nil { actionLabelCapsule.isHidden = true }
            return
        }
        hoveredButton = button
        let label = button === discardButton && discardDisarm != nil ? "Click again to discard" : button.accessibilityLabel() ?? ""
        showLabel(label, over: button)
    }

    private func showLabel(_ label: String, over button: NSButton) {
        actionLabel.stringValue = label
        actionLabelCenter?.isActive = false
        let center = actionLabelCapsule.centerXAnchor.constraint(equalTo: button.centerXAnchor)
        center.priority = .defaultHigh // the edge constraints win, so a label never spills off the panel
        center.isActive = true
        actionLabelCenter = center
        actionLabelCapsule.isHidden = false
        window?.invalidateShadow()
    }

    @objc private func togglePause() {
        onTogglePause?()
    }

    @objc private func stop() {
        onStop?()
    }

    @objc private func discard() {
        guard discardDisarm == nil else {
            discardDisarm?.cancel()
            discardDisarm = nil
            onDiscard?()
            return
        }
        discardButton.image = Self.symbol("trash.fill", "Discard")
        discardButton.tint = .systemRed
        showLabel("Click again to discard", over: discardButton)
        discardDisarm = Task { [weak self] in
            try? await Task.sleep(for: Self.discardConfirmation)
            guard !Task.isCancelled else { return }
            self?.disarmDiscard()
        }
    }

    private func disarmDiscard() {
        discardDisarm = nil
        discardButton.image = Self.symbol("trash", "Discard")
        discardButton.tint = .labelColor
        if hoveredButton === discardButton {
            showLabel("Discard", over: discardButton)
        } else if hoveredButton == nil {
            actionLabelCapsule.isHidden = true
        }
    }
}

/// The menu bar timer: a red dot and the recorded time while recording, a pause glyph while paused. Clicking it stops.
@MainActor
private final class RecordingTimerItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let onClick: () -> Void
    private var isPaused: Bool?

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init()
        guard let button = item.button else { return }
        button.imagePosition = .imageLeading
        button.toolTip = "Stop Recording"
        button.target = self
        button.action = #selector(click)
        button.setAccessibilityLabel("Stop Recording")
        button.setAccessibilityIdentifier(AccessibilityID.stopRecording)
    }

    func show(time label: String, paused: Bool) {
        guard let button = item.button else { return }
        button.attributedTitle = NSAttributedString(
            string: " \(label)",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)]
        )
        guard paused != isPaused else { return }
        isPaused = paused
        let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Recording")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .regular).applying(.init(paletteColors: [.systemRed])))
        let pause = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Paused")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        button.image = paused ? pause : dot
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func click() {
        onClick()
    }
}

/// Short struck-bar cues made by scripts/make-recording-sounds.py. They follow Lunetta's setting and the system's
/// "Play user interface sound effects" switch.
@MainActor
final class RecordingSounds {
    enum Cue: String, CaseIterable {
        case tick = "RecordingTick"
        case start = "RecordingStart"
        case stop = "RecordingStop"
        case pause = "RecordingPause"
        case resume = "RecordingResume"
        case discard = "RecordingDiscard"
    }

    private static let log = Logger(subsystem: "com.joaopcm.lunetta", category: "sound")
    private let settings: LunettaSettings
    private var loaded: [Cue: NSSound] = [:]

    init(settings: LunettaSettings) {
        self.settings = settings
    }

    private var systemPlaysInterfaceSounds: Bool {
        UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true
    }

    func play(_ cue: Cue) {
        guard settings.recordingSounds, systemPlaysInterfaceSounds, let sound = sound(for: cue) else { return }
        sound.stop()
        sound.play()
    }

    private func sound(for cue: Cue) -> NSSound? {
        if let sound = loaded[cue] { return sound }
        guard let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "wav"),
              let sound = NSSound(contentsOf: url, byReference: true)
        else {
            Self.log.fault("\(cue.rawValue, privacy: .public).wav is missing from the app bundle")
            return nil
        }
        loaded[cue] = sound
        return sound
    }
}
