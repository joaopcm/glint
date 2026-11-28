import CoreGraphics
import Foundation
import LunettaCore
import ScreenCaptureKit

public struct ScreenCapturer: Sendable {
    /// Lunetta's windows that frame a capture rather than belong in it, like the selection overlay or the recording controls.
    /// Every other Lunetta window, Settings and the cards included, is captured like any app's.
    let chromeWindowIDs: @Sendable () async -> [UInt32]

    public init(chromeWindowIDs: @escaping @Sendable () async -> [UInt32] = { [] }) {
        self.chromeWindowIDs = chromeWindowIDs
    }

    public func captureArea(_ selection: CGRect, displays: [DisplayInfo]) async throws -> CGImage {
        try Self.requirePermission()
        let (display, area) = try Self.area(of: selection, displays: displays)
        let filter = try await Self.contentFilter(displayID: display.id, hiding: await chromeWindowIDs())
        let configuration = Self.configuration(width: area.width, height: area.height)
        configuration.sourceRect = area.sourceRect
        return try await Self.image(filter: filter, configuration: configuration)
    }

    static func area(of selection: CGRect, displays: [DisplayInfo]) throws -> (DisplayInfo, (sourceRect: CGRect, width: Int, height: Int)) {
        guard let display = DisplayGeometry.display(forSelection: selection, in: displays),
              let area = streamConfiguration(for: selection, on: display)
        else { throw CaptureError.emptySelection }
        return (display, area)
    }

    static func streamConfiguration(for selection: CGRect, on display: DisplayInfo) -> (sourceRect: CGRect, width: Int, height: Int)? {
        guard let sourceRect = DisplayGeometry.sourceRect(for: selection, on: display) else { return nil }
        let size = DisplayGeometry.pixelSize(of: sourceRect, scale: display.scale)
        return (sourceRect, size.width, size.height)
    }

    public func captureDisplay(_ display: DisplayInfo) async throws -> CGImage {
        try Self.requirePermission()
        let filter = try await Self.contentFilter(displayID: display.id, hiding: await chromeWindowIDs())
        let size = DisplayGeometry.pixelSize(of: display.frame, scale: display.scale)
        return try await Self.image(filter: filter, configuration: Self.configuration(width: size.width, height: size.height))
    }

    /// `wallpaperPadding` (points per side) puts the window on the wallpaper that was behind it; `nil` keeps it on transparency.
    public func captureWindow(id: UInt32, wallpaperPadding: Double?) async throws -> CGImage {
        try Self.requirePermission()
        let content = try await Self.shareableContent(includingDesktopWindows: wallpaperPadding != nil)
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw CaptureError.windowNotFound(id)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let size = DisplayGeometry.pixelSize(of: filter.contentRect, scale: scale)
        let configuration = Self.configuration(width: size.width, height: size.height)
        configuration.ignoreShadowsSingleWindow = false
        configuration.shouldBeOpaque = false
        configuration.backgroundColor = CGColor.clear
        let image = try await Self.image(filter: filter, configuration: configuration)
        guard let wallpaperPadding else { return image }
        return try await Self.placeOnWallpaper(image, scale: scale, window: window, content: content, padding: wallpaperPadding)
    }

    private static func placeOnWallpaper(
        _ windowImage: CGImage,
        scale: CGFloat,
        window: SCWindow,
        content: SCShareableContent,
        padding: Double
    ) async throws -> CGImage {
        guard let display = content.displays.max(by: { overlap($0.frame, window.frame) < overlap($1.frame, window.frame) }) else {
            throw CaptureError.wallpaperUnavailable("no display is connected")
        }
        let wallpaperWindows = content.windows.filter { isWallpaperLayer($0.windowLayer) }
        guard !wallpaperWindows.isEmpty else {
            throw CaptureError.wallpaperUnavailable("macOS listed no desktop wallpaper window")
        }
        let filter = SCContentFilter(display: display, including: wallpaperWindows)
        let wallpaperScale = CGFloat(filter.pointPixelScale)
        let size = DisplayGeometry.pixelSize(of: display.frame, scale: wallpaperScale)
        let wallpaper = try await image(filter: filter, configuration: configuration(width: size.width, height: size.height))
        let backdrop = WallpaperBackdrop.layout(
            windowImageSize: CGSize(width: windowImage.width, height: windowImage.height),
            scale: scale,
            windowFrame: window.frame,
            displayFrame: display.frame,
            padding: CGFloat(padding)
        )
        guard let composed = WallpaperComposer.compose(window: windowImage, on: wallpaper, wallpaperScale: wallpaperScale, backdrop: backdrop) else {
            throw CaptureError.wallpaperUnavailable("drawing the window onto it failed")
        }
        return composed
    }

    /// The wallpaper sits below the desktop icon level; Finder's icons and every app window sit at or above it.
    static func isWallpaperLayer(_ layer: Int) -> Bool {
        layer < Int(CGWindowLevelForKey(.desktopIconWindow))
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        return shared.isNull ? 0 : shared.width * shared.height
    }

    public func shareableWindows() async throws -> [CapturableWindow] {
        try Self.requirePermission()
        async let zOrder = Self.onScreenWindowIDsFrontToBack()
        let content = try await Self.shareableContent()
        let windows = content.windows.compactMap { window -> CapturableWindow? in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  !window.frame.isEmpty
            else { return nil }
            return CapturableWindow(id: window.windowID, frame: window.frame)
        }
        return Self.sortedFrontToBack(windows, zOrder: await zOrder)
    }

    static func sortedFrontToBack(_ windows: [CapturableWindow], zOrder: [UInt32]) -> [CapturableWindow] {
        guard windows.count > 1 else { return windows }
        var rank = [UInt32: Int](minimumCapacity: zOrder.count)
        for (index, id) in zOrder.enumerated() where rank[id] == nil {
            rank[id] = index
        }
        return windows.sorted { rank[$0.id, default: .max] < rank[$1.id, default: .max] }
    }

    // SCShareableContent does not document the order of `windows`; CGWindowList with
    // `.optionOnScreenOnly` is documented to return windows front to back.
    private static func onScreenWindowIDsFrontToBack() -> [UInt32] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { $0[kCGWindowNumber as String] as? UInt32 }
    }

    static func requirePermission() throws {
        guard CapturePermission.isGranted() else { throw CaptureError.permissionDenied }
    }

    static func contentFilter(displayID: UInt32, hiding hiddenWindowIDs: [UInt32]) async throws -> sending SCContentFilter {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }
        let hidden = content.windows.filter { hiddenWindowIDs.contains($0.windowID) }
        return SCContentFilter(display: display, excludingWindows: hidden)
    }

    static func configuration(width: Int, height: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return configuration
    }

    static func shareableContent(includingDesktopWindows: Bool = false) async throws -> sending SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(!includingDesktopWindows, onScreenWindowsOnly: true)
        } catch SCStreamError.userDeclined {
            throw CaptureError.permissionDenied
        }
    }

    private static func image(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch SCStreamError.userDeclined {
            throw CaptureError.permissionDenied
        }
    }
}
