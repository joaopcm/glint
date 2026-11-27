import AppKit
import ImageIO
import LunettaCapture
import LunettaCore
import Observation
import UniformTypeIdentifiers

/// What another app put on the clipboard that compressing can shrink: lossless images and recordings. Photos in JPEG or
/// HEIC are already compressed, and 256 colors would only band them.
enum CopiedMedia: Equatable, Sendable {
    case png(Data)
    case tiff(Data)
    case file(URL)

    /// The private and short-lived markers from https://nspasteboard.org: password managers set them, and those copies
    /// are none of Lunetta's business.
    @MainActor static let leftAloneTypes: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
    ]
    /// A document copied from Pages, Keynote or Excel carries a picture of itself next to the document; swapping it
    /// for that picture would lose the document.
    @MainActor static let documentTypes: [NSPasteboard.PasteboardType] = [.rtf, .rtfd, .pdf]

    @MainActor
    static func on(_ pasteboard: NSPasteboard) -> CopiedMedia? {
        let types = pasteboard.types ?? []
        guard !types.contains(where: { leftAloneTypes.contains($0) }) else { return nil }
        // Finder copies a file with its name as text and its icon as an image, so the file decides on its own.
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            guard files.count == 1, let file = files.first, isCompressible(file) else { return nil }
            return .file(file)
        }
        guard !types.contains(where: { documentTypes.contains($0) }) else { return nil }
        if let png = pasteboard.data(forType: .png) { return .png(png) }
        if let tiff = pasteboard.data(forType: .tiff) { return .tiff(tiff) }
        return nil
    }

    static func isCompressible(_ file: URL) -> Bool {
        guard let type = UTType(filenameExtension: file.pathExtension) else { return false }
        return type.conforms(to: .movie) || [UTType.png, .tiff, .bmp].contains { type.conforms(to: $0) }
    }
}

/// A copy of what was on the clipboard, in a folder of its own, ready to compress in place. The copied file itself is
/// never touched.
struct StagedCopy: Sendable, Equatable {
    let url: URL
    let originalBytes: Int

    static func make(of media: CopiedMedia, in scratch: URL, baseName: String) throws -> StagedCopy {
        let folder = scratch.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch media {
        case .png(let data):
            let url = folder.appending(path: "\(baseName).png")
            try PNGWriter.write(data, to: url)
            return StagedCopy(url: url, originalBytes: data.count)
        case .tiff(let data):
            let url = folder.appending(path: "\(baseName).png")
            try PNGWriter.write(try image(in: CGImageSourceCreateWithData(data as CFData, nil), path: url.path), to: url)
            return StagedCopy(url: url, originalBytes: data.count)
        case .file(let file):
            let originalBytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let type = UTType(filenameExtension: file.pathExtension)
            // TIFF and BMP become PNG, the format compression writes; PNGs and recordings keep theirs.
            guard type?.conforms(to: .png) == true || type?.conforms(to: .movie) == true else {
                let url = folder.appending(path: file.deletingPathExtension().lastPathComponent + ".png")
                try PNGWriter.write(try image(in: CGImageSourceCreateWithURL(file as CFURL, nil), path: file.path), to: url)
                return StagedCopy(url: url, originalBytes: originalBytes)
            }
            let url = folder.appending(path: file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: url)
            return StagedCopy(url: url, originalBytes: originalBytes)
        }
    }

    private static func image(in source: CGImageSource?, path: String) throws -> CGImage {
        guard let source, let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptureError.compressionFailed(path: path, reason: "ImageIO couldn't read the copied image")
        }
        return image
    }

    /// Compresses the copy and measures it against what was copied, not against the PNG a TIFF became on the way.
    /// nil when it came out no smaller, so the clipboard keeps what was copied.
    func compress(with compressor: @Sendable (URL) async throws -> CompressionResult?) async throws -> CompressionResult? {
        _ = try await compressor(url)
        let compressedBytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard compressedBytes < originalBytes else { return nil }
        return CompressionResult(originalBytes: originalBytes, compressedBytes: compressedBytes)
    }
}

/// While "Compress copied images and recordings" is on, an image or recording copied in another app gets a card that
/// compresses a copy of it, and the smaller copy replaces it on the clipboard.
@MainActor
final class ClipboardCompressor {
    /// macOS has no clipboard notification, so this polls the change count. 0.5 s is Maccy's default check interval
    /// (https://github.com/p0deje/Maccy), short enough that the card shows before the user pastes.
    static let checkInterval: TimeInterval = 0.5
    /// Checking stops this long after the last keyboard or mouse input, and the next input starts it again, so an idle
    /// Mac doesn't wake Lunetta twice a second (2.2 wakeups/s measured with checking on, 0.07 off). A copy lands while
    /// its app handles the key or click that made it, and an app that takes over 250 ms to handle one is hanging
    /// (https://developer.apple.com/documentation/xcode/understanding-hangs-in-your-app). 5 s is 20× that.
    static let stopsCheckingAfter: TimeInterval = 5

    private let settings: LunettaSettings
    private let pasteboard: NSPasteboard
    private let scratch: URL
    private let compress: @Sendable (URL) async throws -> CompressionResult?
    private let secondsSinceInput: @MainActor () -> TimeInterval
    private let waitForInput: @MainActor (@escaping @MainActor () -> Void) -> () -> Void
    private let show: @MainActor (URL, PendingCompression) -> Void
    private let onProblem: @MainActor (String) -> Void
    private var timer: Timer?
    private var stopWaiting: (() -> Void)?
    private var lastChangeCount = 0

    var isWatching: Bool { isChecking || stopWaiting != nil }
    var isChecking: Bool { timer != nil }

    /// The scratch folder sits in the temporary folder, which macOS empties of files left unopened for 3 days.
    init(
        settings: LunettaSettings,
        pasteboard: NSPasteboard = .general,
        scratch: URL = FileManager.default.temporaryDirectory.appending(path: "com.joaopcm.lunetta/Copied"),
        compress: @escaping @Sendable (URL) async throws -> CompressionResult? = CaptureCompressor.compress,
        secondsSinceInput: @escaping @MainActor () -> TimeInterval = ClipboardCompressor.secondsSinceUserInput,
        waitForInput: @escaping @MainActor (@escaping @MainActor () -> Void) -> () -> Void = ClipboardCompressor.nextInput,
        show: @escaping @MainActor (URL, PendingCompression) -> Void,
        onProblem: @escaping @MainActor (String) -> Void
    ) {
        self.settings = settings
        self.pasteboard = pasteboard
        self.scratch = scratch
        self.compress = compress
        self.secondsSinceInput = secondsSinceInput
        self.waitForInput = waitForInput
        self.show = show
        self.onProblem = onProblem
        followSetting()
    }

    /// `onChange` fires before the new value is stored: hop to the main actor to read it, then watch again.
    private func followSetting() {
        withObservationTracking {
            watch(settings.compressCopiedMedia)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followSetting() }
        }
    }

    private func watch(_ on: Bool) {
        guard on != isWatching else { return }
        guard on else {
            stopChecking()
            stopWaiting?()
            stopWaiting = nil
            return
        }
        lastChangeCount = pasteboard.changeCount // what was copied before turning it on stays as it is
        startChecking()
    }

    private func startChecking() {
        let timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Apple's Energy Efficiency Guide for Mac Apps: a tolerance of at least 10% of the interval lets the system batch wakeups.
        timer.tolerance = Self.checkInterval / 10
        self.timer = timer
    }

    private func stopChecking() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        checkForCopy()
        guard secondsSinceInput() >= Self.stopsCheckingAfter else { return }
        stopChecking()
        stopWaiting = waitForInput { [weak self] in _ = self?.inputResumed() }
    }

    /// Returns the work started for a copy made while checking was stopped, so tests can wait for it.
    @discardableResult
    func inputResumed() -> Task<Void, Never>? {
        guard let stopWaiting else { return nil }
        stopWaiting()
        self.stopWaiting = nil
        startChecking()
        return checkForCopy()
    }

    static func secondsSinceUserInput() -> TimeInterval {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }

    /// Mouse events reach a global monitor without any permission, key events only with Accessibility, so switching
    /// apps from the keyboard (⌘Tab) counts as input too.
    static func nextInput(_ resume: @escaping @MainActor () -> Void) -> () -> Void {
        let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        ) { _ in
            MainActor.assumeIsolated { resume() }
        }
        let notifications = NSWorkspace.shared.notificationCenter
        let observer = notifications.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { resume() }
        }
        return {
            if let monitor { NSEvent.removeMonitor(monitor) }
            notifications.removeObserver(observer)
        }
    }

    /// Returns the work started for a new copy, so tests can wait for it.
    @discardableResult
    func checkForCopy() -> Task<Void, Never>? {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return nil }
        lastChangeCount = changeCount
        guard !pasteboard.holdsLunettaCopy, let media = CopiedMedia.on(pasteboard) else { return nil }
        return compressCopy(of: media, copiedAt: changeCount)
    }

    private func compressCopy(of media: CopiedMedia, copiedAt changeCount: Int) -> Task<Void, Never> {
        let scratch = scratch
        let baseName = CaptureNaming.baseName(for: Date(), timeZone: .current)
        let compress = compress
        return Task {
            let staged: StagedCopy
            do {
                staged = try await Task.detached(priority: .userInitiated) {
                    try StagedCopy.make(of: media, in: scratch, baseName: baseName)
                }.value
            } catch {
                onProblem("Lunetta couldn't compress what you copied: \(error.localizedDescription)")
                return
            }
            let compression: PendingCompression = Task.detached(priority: .userInitiated) {
                try await staged.compress(with: compress)
            }
            show(staged.url, compression)
            guard case .success(.some) = await compression.result else { return }
            // Something copied while this compressed is newer, and the user expects to paste that.
            guard pasteboard.changeCount == changeCount else { return }
            do {
                if UTType(filenameExtension: staged.url.pathExtension)?.conforms(to: .movie) == true {
                    try pasteboard.copyFileReference(staged.url)
                } else {
                    try pasteboard.copyPNGFile(at: staged.url)
                }
            } catch {
                onProblem("Lunetta compressed what you copied, but the clipboard refused it: \(error.localizedDescription)")
            }
        }
    }
}
