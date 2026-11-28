import AppKit
import AVFoundation
import LunettaCore

/// The camera in a circle over the recorded area. It isn't capture chrome, so the screen recording films it like any
/// other window. Its middle moves it and its edge resizes it, both only inside the area; the size carries over to the
/// next recording, and a start over brings it back where it was left.
@MainActor
final class CameraBubble: CameraShowing {
    private let settings: LunettaSettings
    private var panel: NSPanel?
    private var session: CameraSession?
    private var placement: (region: CGRect, frame: CGRect)?

    init(settings: LunettaSettings) {
        self.settings = settings
    }

    var access: DeviceAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    var cameras: [CameraInput] {
        var seen = Set<String>()
        return Self.discovery().devices.compactMap { device in
            guard seen.insert(device.uniqueID).inserted else { return nil }
            return CameraInput(id: device.uniqueID, name: device.localizedName)
        }
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    func show(over region: CGRect, camera: CameraInput?) throws {
        hide()
        guard let device = Self.device(for: camera) else {
            throw camera.map(RecordingProblem.cameraMissing) ?? RecordingProblem.noCamera
        }
        let session = try CameraSession(device: device)
        let frame = placement.flatMap { $0.region == region ? $0.frame : nil }
            ?? CameraBubbleGeometry.initialFrame(in: region, diameter: settings.cameraBubbleDiameter)
        let view = CameraBubbleView(frame: CGRect(origin: .zero, size: frame.size), session: session.capture, region: region)
        view.onChange = { [weak self] frame, resized in
            self?.placement = (region, frame)
            if resized { self?.settings.cameraBubbleDiameter = frame.width }
        }
        let panel = Self.makePanel(frame: frame, view: view)
        session.start()
        panel.orderFrontRegardless()
        view.enter(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        self.session = session
        self.panel = panel
        placement = (region, frame)
    }

    func hide() {
        session?.stop()
        session = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Desk View is left out: it films the desk in front of the Mac, not the person at it.
    private static func discovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
    }

    private static func device(for camera: CameraInput?) -> AVCaptureDevice? {
        guard let camera else { return AVCaptureDevice.systemPreferredCamera ?? discovery().devices.first }
        return AVCaptureDevice(uniqueID: camera.id)
    }

    private static func makePanel(frame: CGRect, view: NSView) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = view
        return panel
    }
}

enum CameraBubbleError: LocalizedError {
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .refused(let name): "macOS wouldn't hand Lunetta the camera \"\(name)\". Quit any app using it, or pick another camera in the recording toolbar."
        }
    }
}

/// `startRunning` blocks until the camera is up, so it runs off the main thread, in order with `stopRunning`.
private final class CameraSession: @unchecked Sendable {
    /// The largest bubble is 720 px across on a 2x display (`CameraBubbleGeometry.maxDiameter`), this preset's height,
    /// so a larger preset would only spend more of the camera's bandwidth and the CPU's scaling.
    private static let preset = AVCaptureSession.Preset.hd1280x720

    let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.joaopcm.lunetta.camera")

    init(device: AVCaptureDevice) throws {
        let input = try AVCaptureDeviceInput(device: device)
        capture.beginConfiguration()
        defer { capture.commitConfiguration() }
        if capture.canSetSessionPreset(Self.preset) { capture.sessionPreset = Self.preset }
        guard capture.canAddInput(input) else { throw CameraBubbleError.refused(device.localizedName) }
        capture.addInput(input)
    }

    func start() {
        queue.async { self.capture.startRunning() }
    }

    func stop() {
        queue.async { self.capture.stopRunning() }
    }
}

private final class CameraBubbleView: NSView {
    private enum Gesture {
        case move, resize
    }

    /// A light press, inside the 0.95 to 0.98 that reads as a press without looking like a jump.
    private static let pressedScale: CGFloat = 0.96
    private static let pressDuration: CFTimeInterval = 0.15

    /// The bubble's new frame in screen coordinates, and whether its size changed.
    var onChange: ((CGRect, _ resized: Bool) -> Void)?

    private let region: CGRect
    private let disc = CALayer()
    private let preview: AVCaptureVideoPreviewLayer
    private var grab: (gesture: Gesture, pointer: CGPoint, frame: CGRect)?

    init(frame: CGRect, session: AVCaptureSession, region: CGRect) {
        self.region = region
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Camera")
        setAccessibilityIdentifier(AccessibilityID.cameraBubble)

        disc.masksToBounds = true
        disc.backgroundColor = NSColor.black.cgColor
        // Keeps the circle's edge from melting into a dark recording.
        disc.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        disc.borderWidth = 1
        preview.videoGravity = .resizeAspectFill
        // Mirrored like FaceTime's own view, so pointing left on camera points left on screen.
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        disc.addSublayer(preview)
        layer?.addSublayer(disc)
        layoutDisc()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutDisc()
    }

    /// Without animation: the circle has to keep up with the pointer while the edge is dragged.
    private func layoutDisc() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.bounds = bounds
        disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        disc.cornerRadius = bounds.width / 2
        preview.frame = disc.bounds
        CATransaction.commit()
    }

    /// Fades up from just under full size, the way the recording controls come in; Reduce Motion keeps the fade alone.
    func enter(reduceMotion: Bool) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.9
        grow.toValue = 1
        let group = CAAnimationGroup()
        group.animations = reduceMotion ? [fade] : [fade, grow]
        group.duration = ThumbnailPresenter.enterDuration
        group.timingFunction = ThumbnailPresenter.easeOut
        disc.add(group, forKey: "enter")
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor()
    }

    private func gesture(at pointer: CGPoint) -> Gesture {
        guard let window, CameraBubbleGeometry.isOnEdge(pointer, of: window.frame) else { return .move }
        return .resize
    }

    private func updateCursor() {
        let pointer = NSEvent.mouseLocation
        switch grab?.gesture ?? gesture(at: pointer) {
        case .move:
            (grab == nil ? NSCursor.openHand : NSCursor.closedHand).set()
        case .resize:
            guard let window else { return }
            NSCursor.frameResize(position: Self.resizePosition(of: pointer, around: window.frame), directions: .all).set()
        }
    }

    /// The grip of a square that sits nearest the pointer, so the arrows point away from the center like the circle grows.
    private static func resizePosition(of pointer: CGPoint, around frame: CGRect) -> NSCursor.FrameResizePosition {
        let degrees = atan2(pointer.y - frame.midY, pointer.x - frame.midX) * 180 / .pi
        let positions: [NSCursor.FrameResizePosition] = [.right, .topRight, .top, .topLeft, .left, .bottomLeft, .bottom, .bottomRight]
        let sector = Int(((degrees + 360 + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        return positions[sector % positions.count]
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        let started = gesture(at: pointer)
        grab = (started, pointer, window.frame)
        updateCursor()
        if started == .move { press(true) }
    }

    /// The bubble follows the pointer one to one: anything looser makes a drag feel like it's pulling on a spring.
    override func mouseDragged(with event: NSEvent) {
        guard let window, let grab else { return }
        let pointer = NSEvent.mouseLocation
        switch grab.gesture {
        case .move:
            let offset = CGPoint(x: pointer.x - grab.pointer.x, y: pointer.y - grab.pointer.y)
            window.setFrameOrigin(CameraBubbleGeometry.dragged(grab.frame, by: offset, within: region).origin)
        case .resize:
            window.setFrame(CameraBubbleGeometry.resized(grab.frame, grabbedAt: grab.pointer, pointer: pointer, within: region), display: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let grab else { return }
        self.grab = nil
        if grab.gesture == .move { press(false) }
        updateCursor()
        if let window, window.frame != grab.frame { onChange?(window.frame, window.frame.size != grab.frame.size) }
    }

    /// Implicit, so a quick click that lets go mid-press turns back from wherever the scale got to.
    private func press(_ pressed: Bool) {
        let scale = pressed ? Self.pressedScale : 1
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.pressDuration)
        CATransaction.setAnimationTimingFunction(ThumbnailPresenter.easeOut)
        disc.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }
}
