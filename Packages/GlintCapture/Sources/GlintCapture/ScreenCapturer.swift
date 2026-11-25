import CoreGraphics
import Foundation
import GlintCore
import ScreenCaptureKit

public struct ScreenCapturer: Sendable {
    public init() {}

    public func captureArea(_ selection: CGRect, displays: [DisplayInfo]) async throws -> CGImage {
        try Self.requirePermission()
        guard let info = DisplayGeometry.display(forSelection: selection, in: displays),
              let sourceRect = DisplayGeometry.sourceRect(for: selection, on: info)
        else { throw CaptureError.emptySelection }
        let filter = try await Self.filterExcludingGlint(displayID: info.id)
        let size = DisplayGeometry.pixelSize(of: sourceRect, scale: info.scale)
        let configuration = Self.configuration(width: size.width, height: size.height)
        configuration.sourceRect = sourceRect
        return try await Self.image(filter: filter, configuration: configuration)
    }

    public func captureDisplay(_ display: DisplayInfo) async throws -> CGImage {
        try Self.requirePermission()
        let filter = try await Self.filterExcludingGlint(displayID: display.id)
        let size = DisplayGeometry.pixelSize(of: display.frame, scale: display.scale)
        return try await Self.image(filter: filter, configuration: Self.configuration(width: size.width, height: size.height))
    }

    public func captureWindow(id: UInt32) async throws -> CGImage {
        try Self.requirePermission()
        guard let window = try await Self.shareableContent().windows.first(where: { $0.windowID == id }) else {
            throw CaptureError.windowNotFound(id)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let size = DisplayGeometry.pixelSize(of: filter.contentRect, scale: CGFloat(filter.pointPixelScale))
        let configuration = Self.configuration(width: size.width, height: size.height)
        configuration.ignoreShadowsSingleWindow = false
        configuration.shouldBeOpaque = false
        configuration.backgroundColor = CGColor.clear
        return try await Self.image(filter: filter, configuration: configuration)
    }

    public func shareableWindows() async throws -> [CapturableWindow] {
        try Self.requirePermission()
        let ownBundleID = Bundle.main.bundleIdentifier
        async let zOrder = Self.onScreenWindowIDsFrontToBack()
        let content = try await Self.shareableContent()
        let windows = content.windows.compactMap { window -> CapturableWindow? in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  window.owningApplication?.bundleIdentifier != ownBundleID,
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

    static func filterExcludingGlint(displayID: UInt32) async throws -> sending SCContentFilter {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }
        let ownBundleID = Bundle.main.bundleIdentifier
        guard let glint = content.applications.first(where: { $0.bundleIdentifier == ownBundleID }) else {
            return SCContentFilter(display: display, excludingWindows: [])
        }
        return SCContentFilter(display: display, excludingApplications: [glint], exceptingWindows: [])
    }

    private static func configuration(width: Int, height: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return configuration
    }

    static func shareableContent() async throws -> sending SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
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
